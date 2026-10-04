import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/rpc/channel_client.dart';
import '../core/v4/sessions_index_store.dart';
import '../core/v4/synced_topic.dart';

enum TaskListKind { active, pinned, archived }

/// Display status of a task row, mirroring ZCode's sidebar states.
enum TaskStatus { running, waiting, completed, interrupted, error, draft, idle }

@immutable
class TaskItem {
  const TaskItem({
    required this.taskId,
    required this.title,
    required this.status,
    required this.updatedAt,
    required this.createdAt,
    this.pinned = false,
    this.archived = false,
    this.unread = false,
    this.preview,
    this.hasBackgroundWork = false,
  });

  final String taskId;
  final String title;
  final TaskStatus status;
  final int updatedAt;
  final int createdAt;
  final bool pinned;
  final bool archived;
  final bool unread;
  final String? preview;
  final bool hasBackgroundWork;
}

/// The workspace task list: tasks-index rows (persistent membership: pinned,
/// archived, deleted, unread) joined with live sessions-index summaries, as in
/// ZCode's `buildTaskListResultFromSessions.ts`.
class TaskListStore extends ChangeNotifier {
  TaskListStore(this.context, this.sessionsIndex) {
    sessionsIndex.addListener(_onSessions);
  }

  final WorkspaceContext context;
  final SessionsIndexStore sessionsIndex;

  final Map<String, Map<String, dynamic>> _indexRows = {};
  final Set<String> _pinned = {};
  final Set<String> _archived = {};
  final Set<String> _deleted = {};
  bool loadedIndex = false;
  bool refreshing = false;
  String? error;
  Timer? _debounce;
  List<TaskItem>? _cache;

  bool get isLive => sessionsIndex.status == TopicStatus.live;

  void _onSessions() {
    _cache = null;
    // A session the persistent index has not seen yet: refresh membership.
    if (loadedIndex &&
        sessionsIndex.sessions.keys.any((id) => !_indexRows.containsKey(id) && !_deleted.contains(id))) {
      scheduleRefresh();
    }
    notifyListeners();
  }

  void scheduleRefresh([Duration delay = const Duration(milliseconds: 400)]) {
    _debounce?.cancel();
    _debounce = Timer(delay, refresh);
  }

  Future<void> refresh() async {
    final api = context.api;
    if (api == null) return;
    refreshing = true;
    notifyListeners();
    final ws = context.workspace;
    try {
      final results = await Future.wait([
        api.listTasks(ws),
        api.listPinnedTasks(ws),
        api.listArchivedTasks(ws),
        api.listDeletedTaskIds(ws),
      ]);
      _indexRows.clear();
      _pinned.clear();
      _archived.clear();
      _deleted
        ..clear()
        ..addAll(results[3] as List<String>);
      for (final row in results[0] as List<Map<String, dynamic>>) {
        _indexRows['${row['taskId']}'] = row;
      }
      for (final row in results[1] as List<Map<String, dynamic>>) {
        _indexRows['${row['taskId']}'] = row;
        _pinned.add('${row['taskId']}');
      }
      for (final row in results[2] as List<Map<String, dynamic>>) {
        _indexRows['${row['taskId']}'] = row;
        _archived.add('${row['taskId']}');
      }
      loadedIndex = true;
      error = null;
    } catch (e) {
      if (e is! ConnectionClosedError) error = e is RpcError ? e.message : '$e';
    } finally {
      refreshing = false;
      _cache = null;
      notifyListeners();
    }
  }

  static TaskStatus _statusFromSession(Map<String, dynamic> s) {
    if (s['pendingInteraction'] != null) return TaskStatus.waiting;
    switch (s['phase']) {
      case 'running':
      case 'prewarming':
        return TaskStatus.running;
      case 'completedSuccess':
        return TaskStatus.completed;
      case 'completedInterrupted':
        return TaskStatus.interrupted;
      case 'error':
        return TaskStatus.error;
      case 'draft':
        return TaskStatus.draft;
    }
    return TaskStatus.idle;
  }

  static TaskStatus _statusFromIndex(Map<String, dynamic> t) {
    switch (t['status']) {
      case 'running':
        return TaskStatus.running;
      case 'completed':
        return TaskStatus.completed;
      case 'error':
        return TaskStatus.error;
    }
    return TaskStatus.idle;
  }

  List<TaskItem> get _all {
    final cached = _cache;
    if (cached != null) return cached;
    final out = <TaskItem>[];
    final seen = <String>{};
    for (final entry in _indexRows.entries) {
      final id = entry.key;
      if (_deleted.contains(id)) continue;
      seen.add(id);
      final row = entry.value;
      final s = sessionsIndex.sessions[id];
      final sessionTitle = (s?['title'] as String?)?.trim() ?? '';
      final titleOverridden = row['titleOverridden'] == true && s?['titleSource'] != 'custom';
      out.add(TaskItem(
        taskId: id,
        title: plainTitle(sessionTitle.isNotEmpty && !titleOverridden
            ? sessionTitle
            : '${row['title'] ?? ''}'),
        status: s != null ? _statusFromSession(s) : _statusFromIndex(row),
        updatedAt: (s?['lastActivityAt'] as num?)?.toInt() ??
            (row['updatedAt'] as num?)?.toInt() ??
            0,
        createdAt: (s?['createdAt'] as num?)?.toInt() ?? (row['createdAt'] as num?)?.toInt() ?? 0,
        pinned: _pinned.contains(id),
        archived: _archived.contains(id),
        unread: row['unreadAt'] != null,
        preview: s?['lastAssistantPreview'] as String?,
        hasBackgroundWork: s?['hasBackgroundWork'] == true,
      ));
    }
    // Live sessions the persistent index does not list yet (just created).
    for (final s in sessionsIndex.sessions.values) {
      final id = '${s['sessionId']}';
      if (seen.contains(id) || _deleted.contains(id) || s['parentSessionId'] != null) continue;
      if (s['phase'] == 'draft') continue;
      out.add(TaskItem(
        taskId: id,
        title: plainTitle('${s['title'] ?? ''}'),
        status: _statusFromSession(s),
        updatedAt: (s['lastActivityAt'] as num?)?.toInt() ?? 0,
        createdAt: (s['createdAt'] as num?)?.toInt() ?? 0,
        preview: s['lastAssistantPreview'] as String?,
        hasBackgroundWork: s['hasBackgroundWork'] == true,
      ));
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return _cache = out;
  }

  List<TaskItem> items(TaskListKind kind, {String query = ''}) {
    final q = query.trim().toLowerCase();
    return _all.where((t) {
      final match = switch (kind) {
        TaskListKind.active => !t.archived && !t.pinned,
        TaskListKind.pinned => t.pinned && !t.archived,
        TaskListKind.archived => t.archived,
      };
      return match && (q.isEmpty || t.title.toLowerCase().contains(q));
    }).toList();
  }

  int count(TaskListKind kind) => items(kind).length;

  TaskItem? find(String taskId) {
    for (final t in _all) {
      if (t.taskId == taskId) return t;
    }
    return null;
  }

  Future<void> _mutate(Future<void> Function() op, void Function() optimistic) async {
    optimistic();
    _cache = null;
    notifyListeners();
    try {
      await op();
    } finally {
      scheduleRefresh(const Duration(milliseconds: 150));
    }
  }

  Future<void> setPinned(String taskId, bool pinned) {
    final api = context.api;
    if (api == null) return Future.error(const ConnectionClosedError('offline'));
    return _mutate(() => api.setTaskPinned(context.workspace, taskId, pinned),
        () => pinned ? _pinned.add(taskId) : _pinned.remove(taskId));
  }

  Future<void> setArchived(String taskId, bool archived) {
    final api = context.api;
    if (api == null) return Future.error(const ConnectionClosedError('offline'));
    return _mutate(
      () => archived
          ? api.archiveTask(context.workspace, taskId)
          : api.unarchiveTask(context.workspace, taskId),
      () => archived ? _archived.add(taskId) : _archived.remove(taskId),
    );
  }

  Future<void> delete(String taskId) {
    final api = context.api;
    if (api == null) return Future.error(const ConnectionClosedError('offline'));
    return _mutate(() => api.deleteTask(context.workspace, taskId), () => _deleted.add(taskId));
  }

  Future<void> markRead(String taskId) async {
    final row = _indexRows[taskId];
    final api = context.api;
    if (row == null || row['unreadAt'] == null || api == null) return;
    _indexRows[taskId] = {...row}..remove('unreadAt');
    _cache = null;
    notifyListeners();
    try {
      await api.setTaskUnread(context.workspace, taskId, false);
    } catch (_) {}
  }

  @override
  void dispose() {
    _debounce?.cancel();
    sessionsIndex.removeListener(_onSessions);
    super.dispose();
  }
}

/// Task titles can carry Markdown links to other sessions (forks are titled
/// `[#Fork of X](#sess_…)`, and the desktop may cut the link target off);
/// show just their text, as ZCode's sidebar does.
String plainTitle(String raw) => raw
    .replaceAllMapped(RegExp(r'\[([^\]]*)\]\((?:[^)]*\)|[^)]*$)'), (m) => m[1]!)
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
