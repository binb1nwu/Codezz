import '../zcode/zcode_api.dart';
import 'synced_topic.dart';

/// Live session summaries of a workspace (`sessions-index/<workspaceKey>`).
class SessionsIndexStore extends SyncedTopic {
  SessionsIndexStore(super.context);

  @override
  String get topic => 'sessions-index/${context.workspace.key}';

  final Map<String, Map<String, dynamic>> sessions = {};

  @override
  Future<Map<String, dynamic>> subscribeRpc(ZCodeApi api, Map<String, Object?>? base) =>
      api.subscribeSessionsIndex(context.workspace, base: base);

  @override
  Future<Map<String, dynamic>> resyncRpc(ZCodeApi api, String subscriptionId,
          Map<String, Object?>? base, bool forceSnapshot) =>
      api.resyncSessionsIndex(context.workspace, subscriptionId,
          base: base, forceSnapshot: forceSnapshot);

  @override
  Future<void> unsubscribeRpc(ZCodeApi api, String subscriptionId) =>
      api.unsubscribeSessionsIndex(context.workspace, subscriptionId);

  @override
  void applySnapshot(Map<String, dynamic> snapshot) {
    sessions.clear();
    for (final s in (snapshot['sessions'] as List? ?? const [])) {
      if (s is Map<String, dynamic> && s['sessionId'] is String) {
        sessions[s['sessionId'] as String] = s;
      }
    }
  }

  @override
  bool applyDeltas(List<dynamic> deltas) {
    for (final d in deltas) {
      if (d is! Map) continue;
      switch (d['op']) {
        case 'session.upserted':
          final s = d['session'];
          if (s is Map<String, dynamic> && s['sessionId'] is String) {
            sessions[s['sessionId'] as String] = s;
          }
        case 'session.removed':
          sessions.remove(d['sessionId']);
      }
    }
    return true;
  }
}
