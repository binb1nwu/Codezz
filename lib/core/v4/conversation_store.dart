import 'dart:async';

import '../rpc/channel_client.dart';
import '../zcode/zcode_api.dart';
import 'ids.dart';
import 'synced_topic.dart';

/// Commands that must carry `baseRevision` (compare-and-set), from
/// `COMMANDS_REQUIRING_BASE_REVISION` in ZCode.
const _casCommands = {
  'applyFileRewind',
  'forkAssistant',
  'editUserQuery',
  'retryTurn',
  'setAssistantFeedback',
  'sendQueuedNow',
  'editQueueItem',
  'reorderQueueItem',
  'deleteQueueItem',
  'setAutoDrain',
  'switchModelConfig',
  'switchCollaborationMode',
  'setFollowupMode',
  'pauseGoal',
  'resumeGoal',
};

/// Commands that target a row and must carry `baseLogEpoch`.
const _rowTargetCommands = {
  'applyFileRewind',
  'forkAssistant',
  'editUserQuery',
  'retryTurn',
  'setAssistantFeedback',
};

/// The objective of a `/goal …` (or `/target …`) message; null when [text]
/// is not a goal command or uses an action ZCode's composer does not send
/// (`pause`, `resume`, `clear`, `show`). An empty objective is ignored by
/// ZCode, so it is returned as ''.
String? goalObjective(String text) {
  final m = RegExp(r'^\s*/(?:goal|target)(?=\s|$)([\s\S]*)$', caseSensitive: false).firstMatch(text);
  if (m == null) return null;
  final rest = m[1]!.trim();
  final action = rest.split(RegExp(r'\s+')).first.toLowerCase();
  if (const {'pause', 'resume', 'clear', 'show'}.contains(action)) return null;
  return action == 'replace' ? rest.replaceFirst(RegExp(r'^replace\s*', caseSensitive: false), '').trim() : rest;
}

class CommandRejected implements Exception {
  CommandRejected(this.status, this.reasonCode, this.message);
  final String status;
  final String? reasonCode;
  final String? message;
  @override
  String toString() => message ?? reasonCode ?? status;
}

/// Projection of one conversation (`conversation/<sessionId>`): session
/// state ("A zone") plus the row window ("B zone"), kept in sync with the
/// exact delta algebra of `apply.ts`.
class ConversationStore extends SyncedTopic {
  ConversationStore(super.context, this.sessionId);

  final String sessionId;

  @override
  String get topic => 'conversation/$sessionId';

  /// Snapshot minus `rows`; `state.updated` patches replace whole keys.
  Map<String, dynamic> state = const {};

  /// Loaded rows in ascending `rowId` order. Row maps are replaced, never
  /// mutated, so widgets can skip rebuilding unchanged rows by identity.
  List<Map<String, dynamic>> rows = const [];
  final Map<int, int> _rowIndex = {};
  int totalCount = 0;
  int? firstRowId;
  bool loadingOlder = false;

  // ── derived state ──
  Map<String, dynamic> get control => _map(state['control']);
  Map<String, dynamic> get config => _map(state['config']);
  Map<String, dynamic> get meta => _map(state['meta']);
  Map<String, dynamic> get inputRouting => _map(state['inputRouting']);
  Map<String, dynamic> get queue => _map(state['queue']);
  Map<String, dynamic> get usage => _map(state['usage']);
  Map<String, dynamic>? get plan => state['plan'] as Map<String, dynamic>?;
  Map<String, dynamic>? get goal => state['goal'] as Map<String, dynamic>?;
  String get phase => control['phase'] as String? ?? 'draft';
  bool get running => phase == 'running' || phase == 'prewarming';
  bool get canStop => control['canStop'] == true;
  bool get stopping => control['stopState'] == 'stopping';
  String get title => meta['title'] as String? ?? '';
  int get revision => (state['revision'] as num?)?.toInt() ?? 0;
  List<Map<String, dynamic>> get pendingInteractions => _list(state['pendingInteractions']);
  List<Map<String, dynamic>> get queueItems => _list(queue['items']);
  List<Map<String, dynamic>> get backgroundWorks => _list(state['backgroundWorks']);
  Map<String, dynamic> get subagents => _map(state['subagents']);
  Map<String, dynamic> get availability => _map(state['availability']);
  Map<String, dynamic>? get lastError => control['lastError'] as Map<String, dynamic>?;
  Map<String, dynamic>? get apiRetry => control['apiRetry'] as Map<String, dynamic>?;
  bool get hasOlder =>
      rows.isNotEmpty && firstRowId != null && (rows.first['rowId'] as num) > firstRowId!;

  static Map<String, dynamic> _map(Object? v) =>
      v is Map<String, dynamic> ? v : const <String, dynamic>{};
  static List<Map<String, dynamic>> _list(Object? v) =>
      v is List ? v.whereType<Map<String, dynamic>>().toList() : const [];

  @override
  Future<Map<String, dynamic>> subscribeRpc(ZCodeApi api, Map<String, Object?>? base) =>
      api.subscribeConversation(context.workspace, sessionId, base: base);

  @override
  Future<Map<String, dynamic>> resyncRpc(ZCodeApi api, String subscriptionId,
          Map<String, Object?>? base, bool forceSnapshot) =>
      api.resyncConversation(context.workspace, subscriptionId,
          base: base, forceSnapshot: forceSnapshot);

  @override
  Future<void> unsubscribeRpc(ZCodeApi api, String subscriptionId) =>
      api.unsubscribeConversation(context.workspace, subscriptionId);

  @override
  void applySnapshot(Map<String, dynamic> snapshot) {
    final rowsWindow = _map(snapshot['rows']);
    final window = _list(rowsWindow['window']);
    final nextFirst = (rowsWindow['firstRowId'] as num?)?.toInt();
    final sameEpoch = snapshot['logEpoch'] == logEpoch;
    final older = <Map<String, dynamic>>[];
    if (sameEpoch && window.isNotEmpty && nextFirst != null) {
      final windowStart = (window.first['rowId'] as num).toInt();
      for (final r in rows) {
        final id = (r['rowId'] as num).toInt();
        if (id < windowStart && id >= nextFirst) older.add(r);
      }
    }
    state = Map<String, dynamic>.of(snapshot)..remove('rows');
    totalCount = (rowsWindow['totalCount'] as num?)?.toInt() ?? window.length;
    firstRowId = nextFirst;
    _setRows([...older, ...window]);
  }

  void _setRows(List<Map<String, dynamic>> next) {
    rows = next;
    _rowIndex
      ..clear()
      ..addEntries([
        for (var i = 0; i < next.length; i++) MapEntry((next[i]['rowId'] as num).toInt(), i)
      ]);
  }

  @override
  bool applyDeltas(List<dynamic> deltas) {
    var working = rows;
    var copied = false;
    List<Map<String, dynamic>> mutable() {
      if (!copied) {
        working = List.of(working);
        copied = true;
      }
      return working;
    }

    for (final d in deltas) {
      if (d is! Map) continue;
      switch (d['op']) {
        case 'row.appended':
          final row = d['row'];
          if (row is! Map<String, dynamic>) return false;
          final id = (row['rowId'] as num).toInt();
          final existing = _rowIndex[id];
          if (existing != null) {
            mutable()[existing] = row;
          } else {
            mutable().add(row);
            _rowIndex[id] = working.length - 1;
            totalCount++;
            firstRowId ??= id;
          }
        case 'row.upserted':
          final row = d['row'];
          if (row is! Map<String, dynamic>) return false;
          final index = _rowIndex[(row['rowId'] as num).toInt()];
          if (index != null) mutable()[index] = row;
        case 'row.removed':
          final from = (d['fromRowId'] as num).toInt();
          final kept = working.where((r) => (r['rowId'] as num) < from).toList();
          final removed = working.length - kept.length;
          final wipesBranch = firstRowId != null && from <= firstRowId!;
          totalCount = wipesBranch ? 0 : (totalCount - removed).clamp(0, 1 << 31);
          if (wipesBranch) firstRowId = null;
          working = kept;
          copied = true;
          _rowIndex
            ..clear()
            ..addEntries([
              for (var i = 0; i < kept.length; i++) MapEntry((kept[i]['rowId'] as num).toInt(), i)
            ]);
        case 'row.delta':
          final index = _rowIndex[(d['rowId'] as num).toInt()];
          if (index == null) continue;
          final list = mutable();
          list[index] = _appendToRow(list[index], d['path'] as String?, '${d['append'] ?? ''}');
        case 'state.updated':
          final patch = d['patch'];
          if (patch is Map<String, dynamic>) {
            state = {...state, ...patch};
          }
        default:
          // workflowRun.* keyed deltas are only sent to clients that declare
          // `workflowRunDeltas`; this client does not.
          break;
      }
    }
    rows = working;
    return true;
  }

  static Map<String, dynamic> _appendToRow(
      Map<String, dynamic> row, String? path, String append) {
    final kind = row['kind'];
    switch (path) {
      case 'text':
        if (kind == 'assistantText' || kind == 'reasoning') {
          return {...row, 'text': '${row['text'] ?? ''}$append'};
        }
      case 'inputText':
        if (kind == 'toolCall') {
          return {...row, 'inputText': '${row['inputText'] ?? ''}$append'};
        }
      case 'output.text':
        final output = row['output'];
        if (kind == 'toolCall' && output is Map) {
          return {
            ...row,
            'output': {...output, 'text': '${output['text'] ?? ''}$append'},
          };
        }
      case 'summaryText':
        if (kind == 'subagent') {
          return {...row, 'summaryText': '${row['summaryText'] ?? ''}$append'};
        }
    }
    return row;
  }

  /// Loads older rows through `rows/range` (cursor pagination upwards).
  Future<void> loadOlder() async {
    final api = context.api;
    if (api == null || loadingOlder || !hasOlder) return;
    loadingOlder = true;
    markChanged();
    try {
      final epoch = logEpoch;
      final before = (rows.first['rowId'] as num).toInt();
      final res = await api.rowsRange(context.workspace, sessionId, beforeRowId: before);
      if (disposed || res['atLogEpoch'] != epoch || rows.isEmpty) return;
      final first = (rows.first['rowId'] as num).toInt();
      final older = _list(res['rows']).where((r) => (r['rowId'] as num) < first).toList();
      if (res['hasMore'] != true && older.isNotEmpty) {
        firstRowId = (older.first['rowId'] as num).toInt();
      }
      _setRows([...older, ...rows]);
    } catch (e) {
      context.log('loadOlder failed: $e');
    } finally {
      loadingOlder = false;
      if (!disposed) markChanged();
    }
  }

  // ── commands ──

  Future<Map<String, dynamic>> command(String type, Map<String, Object?> payload) async {
    final api = context.api;
    if (api == null) throw const ConnectionClosedError('offline');
    final envelope = <String, Object?>{
      'commandId': uuidv7(),
      'clientId': api.clientId,
      'sessionId': sessionId,
      if (_casCommands.contains(type)) 'baseRevision': revision,
      if (_rowTargetCommands.contains(type)) 'baseLogEpoch': logEpoch,
      'type': type,
      'payload': payload,
      'issuedAt': DateTime.now().millisecondsSinceEpoch,
    };
    final ack = await api.sendCommand(context.workspace, envelope);
    final status = ack['status'] as String? ?? 'failed';
    if (status != 'accepted' && status != 'duplicate' && status != 'noop') {
      throw CommandRejected(status, ack['reasonCode'] as String?, ack['message'] as String?);
    }
    return ack;
  }

  /// [attachments] are uploaded refs (`{ref, fileName, mime, bytes}`).
  /// [modelSelection] and [mode] are the composer's configuration, applied
  /// to the session with this message.
  Future<void> sendText(String text,
      {List<Map<String, Object?>> attachments = const [],
      Map<String, Object?>? modelSelection,
      String? mode,
      String? heldQueueDisposition,
      List<String>? expectedHeldQueueItemIds}) {
    return command('sendText', {
      'text': text,
      if (attachments.isNotEmpty) 'attachments': attachments,
      if (modelSelection != null) 'modelSelection': modelSelection,
      if (mode != null) ...{'mode': mode, 'planEnabled': mode == 'plan'},
      if (heldQueueDisposition != null) 'heldQueueDisposition': heldQueueDisposition,
      if (expectedHeldQueueItemIds != null) 'expectedHeldQueueItemIds': expectedHeldQueueItemIds,
    });
  }

  /// `/goal <objective>`: starts a goal run. ZCode requires the full model
  /// and mode configuration with it.
  Future<void> sendGoal(String objective,
      {required String displayText,
      required Map<String, Object?> modelSelection,
      required String mode,
      String? heldQueueDisposition,
      List<String>? expectedHeldQueueItemIds}) {
    return command('sendGoalCommand', {
      'text': objective,
      'displayText': displayText,
      'modelSelection': modelSelection,
      'mode': mode,
      'planEnabled': mode == 'plan',
      if (heldQueueDisposition != null) 'heldQueueDisposition': heldQueueDisposition,
      if (expectedHeldQueueItemIds != null) 'expectedHeldQueueItemIds': expectedHeldQueueItemIds,
    });
  }

  Future<void> stop() {
    final works = _list(control['activeWorks']);
    final execId = works.isEmpty ? null : works.first['foregroundExecutionId'] as String?;
    return command('stop', {if (execId != null) 'expectedForegroundExecutionId': execId});
  }

  Future<void> resolveInteraction(String interactionId, Map<String, Object?> answer) =>
      command('resolveInteraction', {'interactionId': interactionId, 'answer': answer});

  Future<void> snoozeAutoResolution(String interactionId) =>
      command('snoozeInteractionAutoResolution', {'interactionId': interactionId});

  Future<void> deleteQueueItem(String id) => command('deleteQueueItem', {'queueItemId': id});

  Future<void> sendQueuedNow(String id) => command('sendQueuedNow', {'queueItemId': id});

  Future<void> setAutoDrain(bool value) => command('setAutoDrain', {'autoDrain': value});

  Future<void> compact() => command('compact', const {});

  Future<void> rename(String title) => command('renameSession', {'title': title});

  Map<String, Object?> _target(Map<String, dynamic> row) =>
      {'rowId': row['rowId'], 'entityId': row['entityId'] ?? row['turnId']};

  Future<void> retryTurn(Map<String, dynamic> row) =>
      command('retryTurn', {'target': _target(row)});

  Future<void> editUserQuery(Map<String, dynamic> row, String newText) =>
      command('editUserQuery', {'target': _target(row), 'newText': newText});

  Future<void> setFeedback(Map<String, dynamic> row, String? feedback) =>
      command('setAssistantFeedback', {'target': _target(row), 'feedback': feedback});

  Future<void> pauseGoal() => command('pauseGoal', const {});

  Future<void> resumeGoal() => command('resumeGoal', const {});

  Future<void> cancelBackgroundWork(String workId) =>
      command('cancelBackgroundWork', {'workId': workId});
}
