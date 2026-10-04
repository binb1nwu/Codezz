import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:codezz/core/connection/device_connection.dart';
import 'package:codezz/core/link/device_link.dart';
import 'package:codezz/core/relay/relay_socket.dart';
import 'package:codezz/core/relay/rpc_frame_transport.dart';
import 'package:codezz/core/rpc/serialization.dart';
import 'package:codezz/core/v4/wire_assembler.dart' show crc32Hex;
import 'package:codezz/core/zcode/server_info.dart';

Uint8List encodeMessage(Object? header, Object? body) =>
    (RpcWriter()..write(header)..write(body)).takeBytes();

List<Object?> decodeMessage(Uint8List bytes) {
  final r = RpcReader(bytes);
  return [r.read(), r.read()];
}

/// A local stand-in for the remote-control relay plus the desktop behind it.
class FakeRelay {
  FakeRelay._(this.server);

  static Future<FakeRelay> start() async =>
      FakeRelay._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0))
        .._listen();

  final HttpServer server;
  final List<Map<String, dynamic>> received = [];
  String? expectedProof;
  bool rejectAuth = false;
  WebSocket? socket;
  String? bridgeId;
  int _seq = 0;

  static const remoteKey = 'remote:ssh:host:root:/mnt/data';
  bool remoteConnected = false;
  bool reconnectSucceeds = false;
  final List<String> bridgeOpens = [];

  List<Map<String, Object?>> workspaces() => [
        {
          'kind': 'remote',
          'label': 'data',
          'workspaceIdentity': remoteKey,
          'workspacePath': '/mnt/data',
          if (remoteConnected) ...{'connectionState': 'connected', 'remoteSessionId': 'rs-1'}
          else 'connectionState': 'disconnected',
        },
        {'kind': 'local', 'label': 'code', 'workspacePath': '/home/me/code'},
      ];

  String link({String sid = 'd_test', String hash = 'h4sh'}) =>
      'http://127.0.0.1:${server.port}/remote/v4?sid=$sid&hash=$hash&t=1&mid=m-1&name=Desk';

  void _listen() {
    server.listen((req) async {
      final ws = socket = await WebSocketTransformer.upgrade(req);
      ws.listen((raw) => _onFrame(ws, jsonDecode(raw as String) as Map<String, dynamic>));
    });
  }

  void _send(WebSocket ws, Map<String, Object?> frame) => ws.add(jsonEncode(frame));
  void _data(WebSocket ws, Map<String, Object?> payload) => _send(ws, {'type': 'data', 'payload': payload});

  void pushRpc(WebSocket ws, Uint8List body, int messageSeq) {
    final payload = {
      'zcode_type': 'rpc-frame',
      'bridgeSessionId': bridgeId,
      'messageSeq': messageSeq,
      'fragmentIndex': 0,
      'fragmentCount': 1,
      'messageBytes': body.length,
      'checksum': {'algorithm': 'crc32', 'value': crc32Hex(body)},
      'dataBase64': base64.encode(body),
    };
    _data(ws, payload);
    // Replayable delivery: the desktop may send the same message twice.
    _data(ws, payload);
  }

  void _onFrame(WebSocket ws, Map<String, dynamic> f) {
    received.add(f);
    switch (f['type']) {
      case 'auth_init':
        _send(ws, {'type': 'auth_challenge', 'nonce': 'n0nce'});
      case 'auth_response':
        if (rejectAuth || (expectedProof != null && f['proof'] != expectedProof)) {
          _send(ws, {'type': 'error', 'code': 'AUTH_FAILED', 'message': 'bad proof'});
          return;
        }
        _send(ws, {'type': 'auth_ack', 'pair_status': 'matched'});
      case 'pair_status_query':
        _send(ws, {'type': 'pair_status_ack', 'pair_status': 'matched'});
      case 'data':
        final p = (f['payload'] as Map).cast<String, dynamic>();
        switch (p['zcode_type']) {
          case 'bootstrap-request':
            _data(ws, {
              'zcode_type': 'bootstrap-response',
              'requestId': p['requestId'],
              'result': {'desktopAppVersion': '3.14.3', 'workspaces': workspaces(), 'tasks': []},
            });
          case 'workspace-list-request':
            _data(ws, {
              'zcode_type': 'workspace-list-response',
              'requestId': p['requestId'],
              'result': {'workspaces': workspaces(), 'tasks': []},
            });
          case 'workspace-reconnect-request':
            if (reconnectSucceeds) remoteConnected = true;
            _data(ws, {
              'zcode_type': 'workspace-reconnect-response',
              'requestId': p['requestId'],
              'workspaceKey': p['workspaceKey'],
              'success': reconnectSucceeds,
              if (!reconnectSucceeds) 'error': 'ssh: connection refused',
            });
          case 'workspace-bridge-open':
            if (p['workspaceKey'] == remoteKey && !remoteConnected) {
              _data(ws, {
                'zcode_type': 'workspace-bridge-error',
                'requestId': p['requestId'],
                'bridgeSessionId': p['bridgeSessionId'],
                'error': '目标远程工作区尚未连接，无法创建 bridge，请先重连。',
              });
              return;
            }
            bridgeOpens.add(p['workspaceKey'] as String);
            bridgeId = p['bridgeSessionId'] as String;
            // Initialize arrives before the ready response.
            pushRpc(ws, encodeMessage([200], null), ++_seq);
            _data(ws, {
              'zcode_type': 'workspace-bridge-ready',
              'requestId': p['requestId'],
              'bridgeSessionId': bridgeId,
              'bridge': {
                'bridgeSessionId': bridgeId,
                'workspaceKey': p['workspaceKey'],
                'kind': 'local',
              },
            });
          case 'rpc-frame':
            if (p['checksum'] == null) return; // the desktop ignores these
            final body = base64.decode(p['dataBase64'] as String);
            final message = decodeMessage(body);
            final header = message[0] as List;
            if (header[0] == 100) {
              pushRpc(ws, encodeMessage([201, header[1]], {'echo': header[3], 'args': message[1]}), ++_seq);
            }
        }
    }
  }

  Future<void> close() async {
    await socket?.close();
    await server.close(force: true);
  }
}

Future<void> waitFor(bool Function() cond, {Duration timeout = const Duration(seconds: 10)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test('relay proof is base64url(HMAC-SHA256(hash, nonce|role|sid)) without padding', () {
    // printf 'n0nce|terminal|d_test' | openssl dgst -sha256 -hmac 'h4sh/Value=' -binary | base64url
    expect(
      relayProof(passHash: 'h4sh/Value=', nonce: 'n0nce', role: 'terminal', deviceSid: 'd_test'),
      'wxYIkFUOoWXUk6IhEuFmhEWRjR64kdBMtpUg8gzoF5U',
    );
  });

  group('RpcFrameTransport', () {
    test('fragments with checksum and reassembles, deduplicating replays', () {
      final sent = <Map<String, Object?>>[];
      final a = RpcFrameTransport(bridgeSessionId: 'b1', bridgeGeneration: 3, send: sent.add);
      final big = Uint8List.fromList(List.generate(RpcFrameTransport.fragmentBytes + 10, (i) => i % 251));
      a.sendMessage(big);
      expect(sent, hasLength(2));
      expect(sent.first['bridgeGeneration'], 3);
      expect((sent.first['checksum'] as Map)['value'], crc32Hex(big));

      final acks = <Map<String, Object?>>[];
      final b = RpcFrameTransport(bridgeSessionId: 'b1', bridgeGeneration: 3, recoveryId: 'r1', send: acks.add);
      final got = <Uint8List>[];
      b.messages.listen(got.add);
      for (final frame in [...sent, ...sent]) {
        b.accept(Map<String, dynamic>.from(frame));
      }
      expect(got, hasLength(1));
      expect(got.single, big);
      expect(acks.where((p) => p['zcode_type'] == 'rpc-frame-ack'), hasLength(2));
      // The desktop ignores acks whose bridge identity differs from its own.
      expect(acks.first, {
        'zcode_type': 'rpc-frame-ack',
        'bridgeSessionId': 'b1',
        'bridgeGeneration': 3,
        'recoveryId': 'r1',
        'ackMessageSeq': 1,
      });
    });

    test('drops corrupted messages and frames of other bridges', () {
      final sent = <Map<String, Object?>>[];
      RpcFrameTransport(bridgeSessionId: 'b1', send: sent.add).sendMessage(Uint8List.fromList([1, 2, 3]));
      final got = <Uint8List>[];
      final b = RpcFrameTransport(bridgeSessionId: 'b1', send: (_) {})..messages.listen(got.add);
      b.accept({...sent.single, 'checksum': {'algorithm': 'crc32', 'value': '00000000'}});
      b.accept({...sent.single, 'bridgeSessionId': 'other', 'messageSeq': 9});
      expect(got, isEmpty);
    });
  });

  test('ServerInfo.fromBootstrap keeps remote workspace state', () {
    final info = ServerInfo.fromBootstrap({
      'desktopAppVersion': '3.14.3',
      'workspaces': [
        {'kind': 'remote', 'label': 'data', 'workspaceIdentity': 'remote:x', 'workspacePath': '/mnt/data', 'connectionState': 'disconnected'},
        {'kind': 'local', 'label': 'code', 'workspacePath': r'C:\code'},
      ],
    }, serverId: 'm-1', name: 'Desk');
    expect(info.version, '3.14.3');
    expect(info.displayName, 'Desk');
    expect(info.workspaces.map((w) => w.key), ['remote:x', r'C:\code']);
    expect(info.workspaces.first.connected, isFalse);
    expect(info.workspaces.first.isRemote, isTrue);
    expect(info.workspaces.last.connected, isTrue);
    // Same rule as the remote web client: a remote workspace also needs a
    // live remoteSessionId.
    expect(WorkspaceRef.fromJson({'kind': 'remote', 'workspacePath': '/r', 'connectionState': 'connected'}).connected,
        isFalse);
    expect(
        WorkspaceRef.fromJson({'kind': 'remote', 'workspacePath': '/r', 'remoteSessionId': 'rs'}).connected, isTrue);
  });

  group('RelayDeviceConnection', () {
    late FakeRelay relay;
    setUp(() async => relay = await FakeRelay.start());
    tearDown(() => relay.close());

    test('authenticates, bootstraps, bridges the first connected workspace and calls RPC', () async {
      relay.expectedProof =
          relayProof(passHash: 'h4sh', nonce: 'n0nce', role: 'terminal', deviceSid: 'd_test');
      final conn = DeviceConnection(DeviceLink.tryParse(relay.link())!);
      addTearDown(conn.dispose);
      conn.start();
      final client = await conn.onOnline.first.timeout(const Duration(seconds: 10));

      expect(conn.serverInfo!.workspaces, hasLength(2));
      expect(conn.primaryWorkspace!.path, '/home/me/code');
      final open = relay.received
          .map((f) => f['payload'])
          .whereType<Map>()
          .firstWhere((p) => p['zcode_type'] == 'workspace-bridge-open');
      expect(open['workspaceKey'], '/home/me/code');

      final res = await client.call<Map>('zcode-task', 'listTasks', [
        {'workspacePath': '/home/me/code'}
      ], const Duration(seconds: 5));
      expect(res['echo'], 'listTasks');
      // The duplicated response did not confuse the client.
      final second = await client.call<Map>('zcode-agent', 'helloConversationV4', const [], const Duration(seconds: 5));
      expect(second['echo'], 'helloConversationV4');
    });

    test('an unreachable remote workspace falls back to a local one instead of going offline', () async {
      final conn = DeviceConnection(DeviceLink.tryParse(relay.link())!);
      addTearDown(conn.dispose);
      conn.start();
      await conn.onOnline.first.timeout(const Duration(seconds: 10));
      final remote = conn.serverInfo!.workspaces.first;
      expect(remote.connected, isFalse);
      expect(conn.serves(remote), isFalse);

      // Focusing it moves the bridge; the desktop refuses and cannot reconnect.
      final next = conn.onOnline.first.timeout(const Duration(seconds: 10));
      conn.focusWorkspace(remote);
      await next;
      expect(conn.status.value.isOnline, isTrue);
      expect(conn.primaryWorkspace!.path, '/home/me/code');
      expect(conn.workspaceError!.workspace.key, FakeRelay.remoteKey);
      expect(conn.workspaceError!.error, contains('ssh: connection refused'));
    });

    test('reconnectWorkspace reconnects the remote host, then the bridge follows it', () async {
      relay.reconnectSucceeds = true;
      final conn = DeviceConnection(DeviceLink.tryParse(relay.link())!);
      addTearDown(conn.dispose);
      conn.start();
      await conn.onOnline.first.timeout(const Duration(seconds: 10));
      await conn.reconnectWorkspace(conn.serverInfo!.workspaces.first);
      final remote = conn.serverInfo!.workspaces.first;
      expect(remote.connected, isTrue);

      final next = conn.onOnline.first.timeout(const Duration(seconds: 10));
      conn.focusWorkspace(remote);
      await next;
      expect(conn.primaryWorkspace!.key, FakeRelay.remoteKey);
      expect(relay.bridgeOpens.last, FakeRelay.remoteKey);
      expect(conn.workspaceError, isNull);
    });

    test('a rejected link ends in the unauthorized state without retrying', () async {
      relay.rejectAuth = true;
      final conn = DeviceConnection(DeviceLink.tryParse(relay.link())!);
      addTearDown(conn.dispose);
      conn.start();
      await waitFor(() => conn.status.value.phase == ConnectionPhase.unauthorized);
      expect(conn.status.value.error, 'bad proof');
    });

    test('reconnects after the relay socket drops', () async {
      final conn = DeviceConnection(DeviceLink.tryParse(relay.link())!);
      addTearDown(conn.dispose);
      conn.start();
      await conn.onOnline.first.timeout(const Duration(seconds: 10));
      final again = conn.onOnline.first.timeout(const Duration(seconds: 10));
      await relay.socket!.close();
      await again;
      expect(conn.status.value.isOnline, isTrue);
    });
  });
}
