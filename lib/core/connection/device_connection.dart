import 'dart:async';

import 'package:flutter/foundation.dart';

import '../link/device_link.dart';
import '../rpc/channel_client.dart';
import '../zcode/server_info.dart';
import 'relay_connection.dart';
import 'web_connection.dart';

enum ConnectionPhase {
  /// Not started or explicitly closed.
  idle,
  connecting,
  online,

  /// Lost or failed; a retry is scheduled unless [ConnectionStatus.nextRetryAt]
  /// is null.
  offline,

  /// The link was rejected (expired remote link, or a `zcode --web` token
  /// that changed on restart). No automatic retry.
  unauthorized,
}

@immutable
class ConnectionStatus {
  const ConnectionStatus(this.phase,
      {this.error, this.attempt = 0, this.nextRetryAt, this.latencyMs});

  final ConnectionPhase phase;
  final String? error;
  final int attempt;
  final DateTime? nextRetryAt;
  final int? latencyMs;

  bool get isOnline => phase == ConnectionPhase.online;
}

/// One live Channel RPC connection to a ZCode desktop, with automatic
/// reconnect. [WebDeviceConnection] talks to a `zcode --web` server directly,
/// [RelayDeviceConnection] goes through ZCode's remote-control relay.
///
/// Every successful (re)connect creates a fresh [ChannelClient] and bumps
/// [generation]; stores listen to [onOnline] and re-subscribe on the new
/// client (ZCode subscriptions are per connection).
abstract class DeviceConnection {
  DeviceConnection.base(this.link, {this.log});

  factory DeviceConnection(DeviceLink link,
          {void Function(String line)? log, String? preferredWorkspacePath}) =>
      link.isRelay
          ? RelayDeviceConnection(link, log: log, preferredWorkspacePath: preferredWorkspacePath)
          : WebDeviceConnection(link, log: log);

  final DeviceLink link;
  final void Function(String line)? log;

  static const _retryDelays = [1, 2, 4, 8, 15];

  final ValueNotifier<ConnectionStatus> status =
      ValueNotifier(const ConnectionStatus(ConnectionPhase.idle));
  final StreamController<ChannelClient> _online =
      StreamController<ChannelClient>.broadcast();

  /// Fires with the new client every time the connection becomes usable.
  Stream<ChannelClient> get onOnline => _online.stream;

  ServerInfo? serverInfo;
  ChannelClient? _client;
  Timer? _retryTimer;
  int _attempt = 0;
  int generation = 0;
  bool _started = false;
  Future<void>? _connecting;

  ChannelClient? get client => status.value.isOnline ? _client : null;

  /// The workspace the transport is bound to, if any (relay bridges are
  /// opened for one workspace). Used as the initial selection.
  WorkspaceRef? get primaryWorkspace => null;

  /// Tells the connection which workspace the user is looking at.
  void focusWorkspace(WorkspaceRef workspace) {}

  /// Set when the focused workspace could not be opened and the connection
  /// fell back to another one; the session reports and clears it.
  ({WorkspaceRef workspace, String error})? workspaceError;

  /// Whether calls for [workspace] can go through the current transport.
  bool serves(WorkspaceRef workspace) => true;

  /// Asks the desktop to reconnect a remote (SSH / WSL) workspace whose
  /// host link is down, then refreshes [serverInfo]. Throws with the
  /// desktop's reason when it fails.
  Future<void> reconnectWorkspace(WorkspaceRef workspace) async {}

  /// Establishes the transport and returns a client whose `Initialize`
  /// has arrived. Throw [UnauthorizedError] for a rejected link and
  /// [NoRetryError] for failures that must not be retried automatically.
  /// When an established transport drops later, call [lost].
  @protected
  Future<ChannelClient> openClient(int generation);

  /// Tears down whatever [openClient] set up for the current generation.
  @protected
  void closeTransport(String reason);

  /// Returns the connected client, waiting for the next connect if needed.
  Future<ChannelClient> requireClient(
      {Duration timeout = const Duration(seconds: 20)}) async {
    final current = client;
    if (current != null) return current;
    if (status.value.phase == ConnectionPhase.unauthorized) {
      throw const ConnectionClosedError('unauthorized');
    }
    start();
    return onOnline.first.timeout(timeout);
  }

  void start() {
    _started = true;
    if (status.value.phase == ConnectionPhase.online && _client != null) return;
    _connecting ??= _connect().whenComplete(() => _connecting = null);
  }

  /// Retry right away (app resumed, network changed, user tapped retry).
  void reconnectNow() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _attempt = 0;
    _started = true;
    start();
  }

  /// Drops the current connection and connects again right away.
  void forceReconnect() {
    _drop('manual reconnect');
    _connecting = null;
    reconnectNow();
  }

  /// Cheap liveness probe used when the app returns to the foreground: a
  /// socket that sat through a network change can look open but be dead.
  Future<void> verifyAlive() async {
    final c = client;
    if (c == null) {
      if (status.value.phase == ConnectionPhase.offline) reconnectNow();
      return;
    }
    final sw = Stopwatch()..start();
    try {
      await c.call<Object?>('zcode-agent', 'helloConversationV4', const [],
          const Duration(seconds: 8));
      status.value = ConnectionStatus(ConnectionPhase.online,
          latencyMs: sw.elapsedMilliseconds);
    } catch (e) {
      logLine('liveness check failed: $e');
      forceReconnect();
    }
  }

  Future<void> _connect() async {
    _retryTimer?.cancel();
    status.value =
        ConnectionStatus(ConnectionPhase.connecting, attempt: _attempt);
    final myGeneration = ++generation;
    final sw = Stopwatch()..start();
    try {
      final client = await openClient(myGeneration);
      if (myGeneration != generation) {
        client.dispose();
        return;
      }
      _client = client;
      _attempt = 0;
      status.value = ConnectionStatus(ConnectionPhase.online,
          latencyMs: sw.elapsedMilliseconds);
      logLine('online (${sw.elapsedMilliseconds}ms)');
      _online.add(client);
    } catch (e) {
      if (myGeneration != generation) return; // superseded, already handled
      _fail(e);
    }
  }

  /// The transport of [socketGeneration] is gone.
  @protected
  void lost(int socketGeneration, Object reason) {
    if (socketGeneration != generation) return;
    final phase = status.value.phase;
    if (phase != ConnectionPhase.online && phase != ConnectionPhase.connecting) {
      return;
    }
    logLine('connection lost: $reason');
    if (!_started) {
      _drop('$reason');
      status.value = const ConnectionStatus(ConnectionPhase.idle);
      return;
    }
    _fail(reason);
  }

  void _fail(Object e) {
    _drop('$e');
    if (e is UnauthorizedError) {
      status.value =
          ConnectionStatus(ConnectionPhase.unauthorized, error: e.message);
    } else if (e is NoRetryError) {
      _retryTimer?.cancel();
      status.value = ConnectionStatus(ConnectionPhase.offline, error: e.message);
    } else {
      _scheduleRetry(_describe(e));
    }
  }

  void _drop(String reason) {
    generation++;
    _client?.dispose(ConnectionClosedError(reason));
    _client = null;
    closeTransport(reason);
  }

  void _scheduleRetry(String error) {
    if (!_started) return;
    final seconds = _retryDelays[_attempt.clamp(0, _retryDelays.length - 1)];
    _attempt++;
    final at = DateTime.now().add(Duration(seconds: seconds));
    status.value = ConnectionStatus(ConnectionPhase.offline,
        error: error, attempt: _attempt, nextRetryAt: at);
    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(seconds: seconds), start);
  }

  String _describe(Object e) {
    if (e is TimeoutException) return e.message ?? 'timeout';
    final text = '$e';
    return text.length > 160 ? '${text.substring(0, 160)}…' : text;
  }

  /// Re-publishes the current status, e.g. after [serverInfo] changed.
  @protected
  void notifyChanged() {
    final s = status.value;
    status.value = ConnectionStatus(s.phase,
        error: s.error, attempt: s.attempt, nextRetryAt: s.nextRetryAt, latencyMs: s.latencyMs);
  }

  @protected
  void logLine(String line) => log?.call('[conn ${link.displayHost}] $line');

  void close() {
    _started = false;
    _retryTimer?.cancel();
    _drop('closed');
    status.value = const ConnectionStatus(ConnectionPhase.idle);
  }

  void dispose() {
    close();
    _online.close();
    status.dispose();
  }
}

class UnauthorizedError implements Exception {
  const UnauthorizedError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A failure the user has to act on (e.g. another client took over the
/// remote link); shown as offline without an automatic retry.
class NoRetryError implements Exception {
  const NoRetryError(this.message);
  final String message;
  @override
  String toString() => message;
}

class HttpStatusError implements Exception {
  const HttpStatusError(this.status);
  final int status;
  @override
  String toString() => 'HTTP $status';
}
