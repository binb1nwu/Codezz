import 'dart:async';

import 'package:flutter/foundation.dart';

import '../relay/relay_socket.dart';
import '../relay/rpc_frame_transport.dart';
import '../rpc/channel_client.dart';
import '../v4/ids.dart';
import '../zcode/server_info.dart';
import 'device_connection.dart';

/// Channel RPC to a ZCode desktop through its remote-control relay
/// (`https://zcode.z.ai/remote/v4?sid=…` links), mirroring the remote web
/// client's `otn()` flow:
///
/// relay socket → `bootstrap-request` (workspaces) → `workspace-bridge-open`
/// → Channel RPC carried in `rpc-frame`s ([RpcFrameTransport]).
///
/// The relay socket survives bridge reopens; only a lost socket re-runs the
/// authentication. The desktop keeps a single mobile bridge alive, so the
/// bridge follows the focused workspace; local workspaces share one bridge
/// (the desktop routes by the `workspacePath` in every call).
class RelayDeviceConnection extends DeviceConnection {
  RelayDeviceConnection(super.link, {super.log, this.preferredWorkspacePath})
      : super.base();

  /// Last workspace the user had open, used when nothing is focused yet.
  String? preferredWorkspacePath;

  static const clientName = 'codezz';

  /// The desktop faults idle mobile bridges after ~45 s without traffic.
  static const _keepaliveEvery = Duration(seconds: 20);

  RelaySocket? _relay;
  StreamSubscription? _relaySub;
  RpcFrameTransport? _transport;
  ChannelClient? _pending;
  WorkspaceRef? _bridged;
  WorkspaceRef? _focus;
  Timer? _keepalive;
  int _bridgeGeneration = 0;

  @override
  WorkspaceRef? get primaryWorkspace => _bridged;

  @override
  void focusWorkspace(WorkspaceRef workspace) {
    _focus = workspace;
    preferredWorkspacePath = workspace.path;
    final bridged = _bridged;
    if (bridged == null || _serves(bridged, workspace)) return;
    if (status.value.isOnline) {
      logLine('bridge follows workspace ${workspace.label}');
      forceReconnect();
    }
  }

  static bool _serves(WorkspaceRef bridged, WorkspaceRef ws) =>
      bridged.key == ws.key || (!bridged.isRemote && !ws.isRemote);

  @override
  void forceReconnect() {
    // A user-requested reconnect also re-authenticates the relay socket,
    // unless we are only moving the bridge to another workspace.
    if (_focus == null || _bridged == null || _serves(_bridged!, _focus!)) {
      _closeRelay('manual reconnect');
    }
    super.forceReconnect();
  }

  @override
  Future<ChannelClient> openClient(int generation) async {
    final relay = await _ensureRelay();
    final bootstrapId = 'bootstrap-${uuidv4()}';
    final boot = await relay.request(
      {'zcode_type': 'bootstrap-request', 'requestId': bootstrapId},
      (p) => p['zcode_type'] == 'bootstrap-response' && p['requestId'] == bootstrapId,
      timeout: const Duration(seconds: 20),
    );
    final result = boot['result'];
    serverInfo = ServerInfo.fromBootstrap(
      result is Map ? Map<String, dynamic>.from(result) : const {},
      serverId: link.machineId ?? link.sid!,
      name: link.desktopName,
    );
    final list = serverInfo!.workspaces;
    var target = _pickWorkspace(list);
    if (target == null) throw StateError('the desktop has no open workspace');
    ChannelClient client;
    try {
      client = await _openBridge(relay, target, generation);
    } catch (e) {
      // A remote workspace that cannot be reached must not take the whole
      // desktop offline: fall back to a local workspace and report why.
      final fallback = relay.isClosed ? null : _fallbackFor(list, target);
      if (fallback == null) rethrow;
      logLine('bridge for ${target.label} failed ($e), using ${fallback.label}');
      workspaceError = (workspace: target, error: '$e');
      _focus = null;
      target = fallback;
      client = await _openBridge(relay, target, generation);
    }
    _bridged = target;
    _startKeepalive(client);
    return client;
  }

  WorkspaceRef? _fallbackFor(List<WorkspaceRef> list, WorkspaceRef failed) {
    for (final w in list) {
      if (w.key != failed.key && w.connected && !w.isRemote) return w;
    }
    return null;
  }

  @override
  bool serves(WorkspaceRef workspace) {
    final bridged = _bridged;
    return bridged == null || _serves(bridged, workspace);
  }

  @override
  Future<void> reconnectWorkspace(WorkspaceRef workspace) async {
    final relay = _relay;
    if (relay == null || !relay.isMatched) throw const ConnectionClosedError('offline');
    await _requestReconnect(relay, workspace);
    await _refreshWorkspaces(relay);
  }

  /// `workspace-reconnect-request`, as the remote web client's
  /// `reconnectWorkspace` (SSH connects can take a while).
  Future<void> _requestReconnect(RelaySocket relay, WorkspaceRef ws) async {
    final requestId = 'workspace-reconnect-${uuidv4()}';
    logLine('reconnect ${ws.label}');
    final res = await relay.request(
      {
        'zcode_type': 'workspace-reconnect-request',
        'requestId': requestId,
        'workspaceKey': ws.key,
      },
      (p) =>
          p['zcode_type'] == 'workspace-reconnect-response' &&
          p['requestId'] == requestId,
      timeout: const Duration(seconds: 90),
    );
    if (res['success'] != true) {
      throw StateError('${res['error'] ?? 'the desktop could not reconnect ${ws.label}'}');
    }
  }

  Future<void> _refreshWorkspaces(RelaySocket relay) async {
    final requestId = 'workspace-list-${uuidv4()}';
    final res = await relay.request(
      {'zcode_type': 'workspace-list-request', 'requestId': requestId},
      (p) => p['zcode_type'] == 'workspace-list-response' && p['requestId'] == requestId,
      timeout: const Duration(seconds: 20),
    );
    _applyWorkspaceList(res['result']);
  }

  void _applyWorkspaceList(Object? result) {
    final raw = result is Map ? result['workspaces'] : result;
    final info = serverInfo;
    if (raw is! List || info == null) return;
    serverInfo = info.withWorkspaces(WorkspaceRef.listFrom(raw));
    notifyChanged();
  }

  Future<RelaySocket> _ensureRelay() async {
    final existing = _relay;
    if (existing != null && existing.isMatched) return existing;
    _closeRelay('reconnect');
    final relay = _relay = RelaySocket(link,
        log: logLine, clientName: clientName, platform: _platformName());
    _relaySub = relay.payloads.listen(_onPayload);
    unawaited(relay.closed.then((reason) {
      if (_relay != relay) return;
      _relay = null;
      lost(generation, _mapRelayError(reason));
    }));
    logLine('connect ${link.displayHost}');
    try {
      await relay.open();
    } catch (e) {
      throw _mapRelayError(e);
    }
    return relay;
  }

  WorkspaceRef? _pickWorkspace(List<WorkspaceRef> list) {
    if (list.isEmpty) return null;
    WorkspaceRef? find(bool Function(WorkspaceRef w) test) {
      for (final w in list) {
        if (test(w)) return w;
      }
      return null;
    }

    final focus = _focus;
    return (focus == null ? null : find((w) => w.key == focus.key)) ??
        find((w) => w.path == preferredWorkspacePath && w.connected) ??
        find((w) => w.connected && !w.isRemote) ??
        find((w) => w.connected) ??
        list.first;
  }

  Future<ChannelClient> _openBridge(
      RelaySocket relay, WorkspaceRef ws, int generation) async {
    _pending?.dispose(const ConnectionClosedError('bridge reopened'));
    _transport?.dispose();
    final bridgeSessionId = 'bridge-${uuidv4()}';
    final bridgeGeneration = ++_bridgeGeneration;
    // The desktop sends `Initialize` before `workspace-bridge-ready`, so the
    // transport has to exist before the bridge is requested.
    final transport = _transport = RpcFrameTransport(
      bridgeSessionId: bridgeSessionId,
      bridgeGeneration: bridgeGeneration,
      send: relay.send,
      log: logLine,
    );
    final client = _pending = ChannelClient(transport.sendMessage);
    transport.messages.listen(client.acceptMessage);

    Future<Map<String, dynamic>> open() => relay.request(
          {
            'zcode_type': 'workspace-bridge-open',
            'requestId': 'workspace-bridge-${uuidv4()}',
            'bridgeSessionId': bridgeSessionId,
            'bridgeGeneration': bridgeGeneration,
            'workspaceKey': ws.key,
          },
          (p) =>
              (p['zcode_type'] == 'workspace-bridge-ready' ||
                  p['zcode_type'] == 'workspace-bridge-error') &&
              p['bridgeSessionId'] == bridgeSessionId,
        );

    logLine('open bridge for ${ws.label}');
    var res = await open();
    if (res['zcode_type'] == 'workspace-bridge-error' && ws.isRemote) {
      // A remote (SSH / WSL) workspace whose host link is down: ask the
      // desktop to reconnect it, then try once more.
      logLine('bridge refused (${res['error']})');
      await _requestReconnect(relay, ws);
      res = await open();
    }
    if (res['zcode_type'] == 'workspace-bridge-error') {
      throw StateError('${res['error'] ?? res['reason'] ?? 'workspace bridge refused'}');
    }
    relay.send({
      'zcode_type': 'mobile-view-state-update',
      'viewState': {
        'activeWorkspaceKey': ws.key,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      },
      'deviceInfo': {
        'platform': _platformName(),
        'version': link.desktopVersion ?? 'web',
        'name': clientName,
      },
    });
    await client.initialized.timeout(const Duration(seconds: 15));
    _pending = null;
    return client;
  }

  void _onPayload(Map<String, dynamic> payload) {
    switch (payload['zcode_type']) {
      case 'rpc-frame':
        _transport?.accept(payload);
      case 'bridge-degraded':
        final transport = _transport;
        if (transport != null && payload['bridgeSessionId'] == transport.bridgeSessionId) {
          lost(generation, 'bridge degraded: ${payload['reason'] ?? 'unknown'}');
        }
      case 'workspace-list-updated':
        final result = payload['result'];
        if (result is Map && result['workspaces'] is List) _applyWorkspaceList(result);
    }
  }

  void _startKeepalive(ChannelClient client) {
    _keepalive?.cancel();
    _keepalive = Timer.periodic(_keepaliveEvery, (_) {
      final transport = _transport;
      if (transport == null || client.isDisposed) return;
      if (DateTime.now().difference(transport.lastActivity) < _keepaliveEvery) return;
      client
          .call<Object?>('zcode-agent', 'helloConversationV4', const [], const Duration(seconds: 15))
          .catchError((Object _) => null);
    });
  }

  Object _mapRelayError(Object e) {
    if (e is RelayRejected) return UnauthorizedError(e.message);
    if (e is RelayKicked) return NoRetryError(e.message);
    return e;
  }

  @override
  void closeTransport(String reason) {
    _keepalive?.cancel();
    _keepalive = null;
    _pending?.dispose(ConnectionClosedError(reason));
    _pending = null;
    _transport?.dispose();
    _transport = null;
    _bridged = null;
  }

  @override
  void close() {
    super.close();
    _closeRelay('closed');
  }

  void _closeRelay(String reason) {
    final relay = _relay;
    _relay = null;
    _relaySub?.cancel();
    _relaySub = null;
    relay?.close(reason);
  }
}

String _platformName() {
  if (kIsWeb) return 'web';
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => 'android',
    TargetPlatform.iOS => 'ios',
    TargetPlatform.windows => 'windows',
    TargetPlatform.macOS => 'macos',
    TargetPlatform.linux => 'linux',
    TargetPlatform.fuchsia => 'fuchsia',
  };
}
