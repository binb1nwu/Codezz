import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../connection/ws_connect.dart';
import '../link/device_link.dart';

/// The relay refused this link (bad proof, unknown / expired session). Not
/// retried: the user has to paste a fresh link from the desktop.
class RelayRejected implements Exception {
  const RelayRejected(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Another mobile client took over this remote session.
class RelayKicked implements Exception {
  const RelayKicked(this.message);
  final String message;
  @override
  String toString() => message;
}

/// `proof = base64url_nopad(HMAC-SHA256(key: hash, msg: "nonce|role|sid"))`,
/// as `aen()` / `ien()` in ZCode's remote web client.
String relayProof({
  required String passHash,
  required String nonce,
  required String role,
  required String deviceSid,
}) {
  final digest =
      Hmac(sha256, utf8.encode(passHash)).convert(utf8.encode('$nonce|$role|$deviceSid'));
  return base64Url.encode(digest.bytes).replaceAll('=', '');
}

/// Relay close codes (`VC()` in the remote web client) that mean the link
/// itself is no longer valid.
const _fatalCloseCodes = {
  4004: 'session not found',
  4011: 'session expired',
  4013: 'invalid mobile connection',
};

/// One authenticated relay socket for a remote link, playing the `terminal`
/// (mobile) role. JSON text frames over `wss://<relay>/ws`:
///
/// 1. `auth_init` → `auth_challenge{nonce}` → `auth_response{proof}` →
///    `auth_ack{pair_status}`; `matched` means the desktop is attached.
/// 2. `data{payload}` carries the desktop protocol (`zcode_type` payloads).
/// 3. `pair_status_query` every 10 s doubles as heartbeat.
///
/// The socket never reconnects by itself; [closed] completes once and the
/// owner decides whether to retry.
class RelaySocket {
  RelaySocket(this.link, {this.log, required this.clientName, required this.platform})
      : assert(link.isRelay);

  final DeviceLink link;
  final void Function(String line)? log;
  final String clientName;
  final String platform;

  static const heartbeatInterval = Duration(seconds: 10);
  static const heartbeatTimeout = Duration(seconds: 30);

  WebSocketChannel? _socket;
  StreamSubscription? _sub;
  Timer? _heartbeat;
  DateTime _lastAck = DateTime.now();
  bool _matched = false;
  Completer<void>? _pairing;

  final Completer<Object> _closed = Completer<Object>();

  /// Completes with the reason once the socket is gone.
  Future<Object> get closed => _closed.future;
  bool get isClosed => _closed.isCompleted;
  bool get isMatched => _matched && !isClosed;

  final StreamController<Map<String, dynamic>> _payloads =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);

  /// Every `data` payload from the desktop.
  Stream<Map<String, dynamic>> get payloads => _payloads.stream;

  /// Connects, authenticates and waits until the desktop is attached.
  Future<void> open({Duration timeout = const Duration(seconds: 30)}) async {
    final pairing = _pairing = Completer<void>();
    final socket = _socket = connectWebSocket(link.webSocketUri);
    _sub = socket.stream.listen(
      _onFrame,
      onError: (Object e) => _close('$e'),
      onDone: () {
        final code = socket.closeCode;
        final fatal = _fatalCloseCodes[code];
        _close(fatal != null
            ? RelayRejected('relay: $fatal')
            : 'relay closed (${code ?? '-'}${socket.closeReason == null ? '' : ' ${socket.closeReason}'})');
      },
      cancelOnError: true,
    );
    try {
      await socket.ready.timeout(const Duration(seconds: 12));
      _send({
        'type': 'auth_init',
        'role': 'terminal',
        'device_sid': link.sid,
        'meta': {
          'platform': platform,
          'version': link.desktopVersion ?? 'web',
          'name': clientName,
        },
        'client_ts': DateTime.now().millisecondsSinceEpoch,
      });
      await Future.any([pairing.future, closed.then((reason) => throw reason)])
          .timeout(timeout, onTimeout: () {
        throw TimeoutException('desktop did not attach (is ZCode running with remote control on?)');
      });
    } catch (e) {
      _close(e);
      rethrow;
    }
  }

  void _send(Map<String, Object?> frame) {
    final socket = _socket;
    if (socket == null || isClosed) return;
    try {
      socket.sink.add(jsonEncode(frame));
    } catch (e) {
      _close('$e');
    }
  }

  /// Sends one desktop protocol payload.
  void send(Map<String, Object?> payload) => _send({
        'type': 'data',
        'payload': payload,
        'client_ts': DateTime.now().millisecondsSinceEpoch,
      });

  /// Sends [payload] and resolves with the first payload accepted by [match]
  /// (responses echo the `requestId`, see the web client's `k()` helper).
  Future<Map<String, dynamic>> request(
    Map<String, Object?> payload,
    bool Function(Map<String, dynamic> response) match, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    final completer = Completer<Map<String, dynamic>>();
    late final StreamSubscription sub;
    sub = payloads.listen((p) {
      if (!completer.isCompleted && match(p)) {
        sub.cancel();
        completer.complete(p);
      }
    });
    closed.then((reason) {
      sub.cancel();
      if (!completer.isCompleted) completer.completeError(reason);
    });
    send(payload);
    return completer.future.timeout(timeout, onTimeout: () {
      sub.cancel();
      throw TimeoutException('${payload['zcode_type']} timed out', timeout);
    });
  }

  void _onFrame(dynamic raw) {
    Map<String, dynamic> frame;
    try {
      final decoded = jsonDecode(raw is String ? raw : utf8.decode(raw as List<int>));
      if (decoded is! Map<String, dynamic>) return;
      frame = decoded;
    } catch (e) {
      _log('bad frame: $e');
      return;
    }
    switch (frame['type']) {
      case 'auth_challenge':
        _send({
          'type': 'auth_response',
          'device_sid': link.sid,
          'proof': relayProof(
            passHash: link.passHash!,
            nonce: '${frame['nonce'] ?? ''}',
            role: 'terminal',
            deviceSid: link.sid!,
          ),
          'client_ts': DateTime.now().millisecondsSinceEpoch,
        });
      case 'auth_ack':
      case 'pair_status_ack':
        _onPairStatus(frame['pair_status'] as String?);
      case 'data':
        final payload = frame['payload'];
        if (payload is Map<String, dynamic>) _payloads.add(payload);
      case 'error':
        _onError(frame['code'] as String?, frame['message'] as String?);
    }
  }

  void _onPairStatus(String? status) {
    _lastAck = DateTime.now();
    if (status == 'matched') {
      if (!_matched) _log('paired');
      _matched = true;
      _startHeartbeat();
      final pairing = _pairing;
      if (pairing != null && !pairing.isCompleted) pairing.complete();
    } else if (status == 'waiting') {
      if (_matched) {
        // The desktop dropped off the relay; start over from scratch.
        _close('desktop left the relay');
      } else {
        _log('waiting for the desktop');
        _startHeartbeat();
      }
    }
  }

  void _onError(String? code, String? message) {
    _log('error $code ${message ?? ''}');
    switch (code) {
      case 'AUTH_FAILED':
      case 'WRONG_PARAM':
        _close(RelayRejected(message ?? 'relay rejected the link ($code)'));
      case 'KICKED':
        _close(RelayKicked(message ?? 'another client took over this remote link'));
      case 'DEVICE_OFFLINE':
        _close('desktop offline');
      case 'INTERNAL':
        _close('relay internal error${message == null ? '' : ': $message'}');
    }
  }

  void _startHeartbeat() {
    if (_heartbeat != null) return;
    _lastAck = DateTime.now();
    _heartbeat = Timer.periodic(heartbeatInterval, (_) {
      if (DateTime.now().difference(_lastAck) > heartbeatTimeout) {
        _close('relay heartbeat timeout');
        return;
      }
      _send({
        'type': 'pair_status_query',
        'device_sid': link.sid,
        'client_ts': DateTime.now().millisecondsSinceEpoch,
      });
    });
  }

  void _close(Object reason) {
    if (_closed.isCompleted) return;
    _log('closed: $reason');
    _heartbeat?.cancel();
    _sub?.cancel();
    try {
      _socket?.sink.close();
    } catch (_) {}
    _socket = null;
    _closed.complete(reason);
    _closed.future.ignore();
    _payloads.close();
  }

  void close([String reason = 'closed']) => _close(reason);

  void _log(String line) => log?.call('[relay] $line');
}
