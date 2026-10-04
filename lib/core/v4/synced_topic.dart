import 'dart:async';

import 'package:flutter/foundation.dart';

import '../rpc/channel_client.dart';
import '../zcode/server_info.dart';
import '../zcode/zcode_api.dart';
import 'topic_router.dart';

/// Access to the live connection of one workspace.
abstract class WorkspaceContext {
  WorkspaceRef get workspace;
  TopicRouter get router;

  /// The API of the current connection, or null while offline.
  ZCodeApi? get api;

  /// Emits the API of every new connection.
  Stream<ZCodeApi> get onApi;

  void log(String line);
}

enum TopicStatus { connecting, live, recovering, offline, error }

/// Generic V4 topic synchroniser (sessions-index and conversation share the
/// same frame algebra):
///
/// * snapshot frame → replace state, watermark = `toSeq`;
/// * delta frame → apply only if `fromSeq == watermark` (else it is a gap);
/// * gap / assembly fault → same-subscription `resync` with the watermark;
/// * reconnect → re-subscribe with `base = {logEpoch, seq}` so the host can
///   resume instead of resending the snapshot.
abstract class SyncedTopic extends ChangeNotifier implements TopicConsumer {
  SyncedTopic(this.context);

  final WorkspaceContext context;

  TopicStatus _status = TopicStatus.connecting;
  TopicStatus get status => _status;
  String? error;

  String? logEpoch;
  int seq = 0;
  bool hasState = false;
  String? subscriptionId;

  bool _disposed = false;
  bool get disposed => _disposed;
  int _generation = 0;
  bool _resyncInFlight = false;
  Timer? _retryTimer;
  int _retryAttempt = 0;
  StreamSubscription<ZCodeApi>? _apiSub;
  bool _notifyScheduled = false;

  // ── subclass hooks ──
  Future<Map<String, dynamic>> subscribeRpc(ZCodeApi api, Map<String, Object?>? base);
  Future<Map<String, dynamic>> resyncRpc(
      ZCodeApi api, String subscriptionId, Map<String, Object?>? base, bool forceSnapshot);
  Future<void> unsubscribeRpc(ZCodeApi api, String subscriptionId);
  void applySnapshot(Map<String, dynamic> snapshot);

  /// Returns false when a delta cannot be applied (forces a snapshot resync).
  bool applyDeltas(List<dynamic> deltas);

  /// Hook for errors that should not be retried (e.g. runtime unavailable).
  bool handleSubscribeError(Object error) => false;

  void start() {
    context.router.register(this);
    _apiSub = context.onApi.listen((_) => _subscribe());
    if (context.api != null) {
      _subscribe();
    } else {
      _setStatus(TopicStatus.offline);
    }
  }

  Map<String, Object?>? get _base =>
      hasState && logEpoch != null ? {'logEpoch': logEpoch, 'seq': seq} : null;

  Future<void> _subscribe({bool forceSnapshot = false}) async {
    final api = context.api;
    if (api == null || _disposed) return;
    _retryTimer?.cancel();
    final generation = ++_generation;
    _resyncInFlight = false;
    subscriptionId = null;
    _setStatus(hasState ? TopicStatus.recovering : TopicStatus.connecting);
    context.router.beginSubscribe(this);
    try {
      final ack = await subscribeRpc(api, forceSnapshot ? null : _base);
      if (_disposed || generation != _generation) {
        context.router.cancelSubscribe(this);
        unawaited(_quietUnsubscribe(api, '${ack['subscriptionId']}'));
        return;
      }
      final id = '${ack['subscriptionId']}';
      subscriptionId = id;
      if (ack['mode'] != 'resume' || ack['logEpoch'] != logEpoch) {
        // A snapshot follows; stale local state must not accept deltas.
        hasState = false;
      }
      context.router.bind(this, id);
      _retryAttempt = 0;
      error = null;
      if (hasState) _setStatus(TopicStatus.live);
    } catch (e) {
      context.router.cancelSubscribe(this);
      if (_disposed || generation != _generation) return;
      if (e is ConnectionClosedError) {
        _setStatus(TopicStatus.offline);
        return;
      }
      context.log('subscribe $topic failed: $e');
      if (handleSubscribeError(e)) return;
      error = e is RpcError ? e.message : '$e';
      _setStatus(TopicStatus.error);
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    const delays = [1, 2, 5, 10, 20];
    final s = delays[_retryAttempt.clamp(0, delays.length - 1)];
    _retryAttempt++;
    _retryTimer?.cancel();
    _retryTimer = Timer(Duration(seconds: s), () {
      if (!_disposed) _subscribe(forceSnapshot: true);
    });
  }

  /// The connection dropped: the subscription died with it.
  void markOffline() {
    _generation++;
    _resyncInFlight = false;
    subscriptionId = null;
    _retryTimer?.cancel();
    _setStatus(TopicStatus.offline);
  }

  /// Re-subscribe from scratch (user pull-to-refresh or unrecoverable fault).
  void refresh() => _subscribe(forceSnapshot: true);

  @override
  void onFrame(Map<String, dynamic> frame, String deliveryKind) {
    if (_disposed) return;
    final payload = frame['payload'];
    if (payload is! Map) return;
    final fromSeq = (frame['fromSeq'] as num?)?.toInt() ?? 0;
    final toSeq = (frame['toSeq'] as num?)?.toInt() ?? 0;
    if (payload['kind'] == 'snapshot') {
      final snapshot = payload['snapshot'];
      if (snapshot is! Map<String, dynamic>) return;
      applySnapshot(snapshot);
      logEpoch = '${snapshot['logEpoch']}';
      seq = toSeq;
      hasState = true;
      _resyncInFlight = false;
      _setStatus(TopicStatus.live);
      _scheduleNotify();
      return;
    }
    if (!hasState || toSeq <= seq) return;
    if (fromSeq != seq) {
      _resync('gap $fromSeq≠$seq');
      return;
    }
    final deltas = payload['deltas'];
    if (deltas is! List) return;
    if (!applyDeltas(deltas)) {
      _resync('unapplicable delta', forceSnapshot: true);
      return;
    }
    seq = toSeq;
    _resyncInFlight = false;
    if (_status != TopicStatus.live) _setStatus(TopicStatus.live);
    _scheduleNotify();
  }

  @override
  void onFault(String reason) => _resync('fault $reason', forceSnapshot: true);

  Future<void> _resync(String why, {bool forceSnapshot = false}) async {
    final api = context.api;
    final id = subscriptionId;
    if (api == null || id == null || _resyncInFlight) return;
    _resyncInFlight = true;
    context.log('resync $topic: $why');
    _setStatus(TopicStatus.recovering);
    final generation = _generation;
    try {
      final ack = await resyncRpc(api, id, forceSnapshot ? null : _base, forceSnapshot);
      if (generation != _generation || _disposed) return;
      if (ack['mode'] != 'resume') hasState = false;
      // The recovery frame arrives as a notification; if it never does, fall
      // back to a fresh subscription.
      Timer(const Duration(seconds: 8), () {
        if (generation == _generation && _resyncInFlight && !_disposed) {
          _subscribe(forceSnapshot: true);
        }
      });
    } catch (e) {
      if (generation != _generation || _disposed) return;
      context.log('resync $topic failed: $e');
      _subscribe(forceSnapshot: true);
    }
  }

  Future<void> _quietUnsubscribe(ZCodeApi api, String id) async {
    try {
      await unsubscribeRpc(api, id);
    } catch (_) {}
  }

  void _setStatus(TopicStatus s) {
    if (_status == s) return;
    _status = s;
    _scheduleNotify();
  }

  /// Coalesces bursts of frames into one rebuild per microtask.
  void _scheduleNotify() {
    if (_notifyScheduled || _disposed) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      if (!_disposed) notifyListeners();
    });
  }

  @protected
  void markChanged() => _scheduleNotify();

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _retryTimer?.cancel();
    _apiSub?.cancel();
    context.router.unregister(this);
    final api = context.api;
    final id = subscriptionId;
    if (api != null && id != null) unawaited(_quietUnsubscribe(api, id));
    super.dispose();
  }
}
