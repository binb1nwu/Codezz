import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../core/v4/conversation_store.dart';
import '../../state/app_state.dart';
import '../../state/device_session.dart';
import '../../state/task_list_store.dart';
import '../conversation/status_capsule.dart';
import '../l10n.dart';

/// A task a notification leads to: `deviceId|workspaceKey|taskId`.
@immutable
class TaskTarget {
  const TaskTarget(this.deviceId, this.workspaceKey, this.taskId);
  final String deviceId;
  final String workspaceKey;
  final String taskId;

  String get selectionKey => '$deviceId|$workspaceKey';
  String encode() => '$selectionKey|$taskId';

  static TaskTarget? decode(String? payload) {
    final parts = payload?.split('|');
    if (parts == null || parts.length < 3) return null;
    // Workspace keys may hold '|': the device id is first, the task id last.
    return TaskTarget(parts.first, parts.sublist(1, parts.length - 1).join('|'), parts.last);
  }

  @override
  bool operator ==(Object other) => other is TaskTarget && other.encode() == encode();
  @override
  int get hashCode => encode().hashCode;
}

/// What the running notification shows for one task: the status capsule's
/// line and, with a todo list, how many items are done.
@immutable
class TaskProgress {
  const TaskProgress(this.title, this.text, {this.done, this.total});
  final String title;
  final String text;
  final int? done;
  final int? total;

  static TaskProgress of(String title, ConversationStore? store, S s) {
    final model = store == null || !store.hasState ? null : StatusModel.from(store, null);
    final segment = model?.capsule();
    final text = switch (segment?.kind) {
      CapsuleKind.todo || CapsuleKind.goal || CapsuleKind.done => segment!.text,
      CapsuleKind.running => segment!.agents > 0
          ? s.runningAgents(segment.bash + segment.agents)
          : s.runningBackgroundShort(segment.bash),
      _ => s.working,
    };
    final todos = model?.todos ?? const [];
    return TaskProgress(title, text, done: todos.isEmpty ? null : model!.todosDone, total: todos.isEmpty ? null : todos.length);
  }

  @override
  bool operator ==(Object other) =>
      other is TaskProgress && other.title == title && other.text == text && other.done == done && other.total == total;
  @override
  int get hashCode => Object.hash(title, text, done, total);
}

/// Mirrors the running tasks of every device's open workspace into system
/// notifications: one ongoing notification with the status capsule's
/// progress while any task runs, and one notification when a task finishes,
/// fails or needs an answer (unless it is the conversation on screen).
/// Tapping a notification calls [onOpen] with its task.
class TaskNotifier {
  TaskNotifier(this.app, {required this.onOpen, MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('codezz/notify');

  final AppState app;
  final ValueChanged<TaskTarget> onOpen;
  final MethodChannel _channel;

  S get _s => S.lang(zh: ui.PlatformDispatcher.instance.locale.languageCode == 'zh');

  /// Running tasks and the workspace they were retained from.
  final Map<TaskTarget, WorkspaceSession> _running = {};
  final Set<Listenable> _watching = {};
  bool _scheduled = false;
  bool _disposed = false;
  Object? _shown;

  Future<void> start() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'open') _open(call.arguments as String?);
    });
    _schedule();
    final s = _s;
    _open(await _invoke('init', {'runningChannel': s.runningTasksChannel, 'doneChannel': s.finishedTasksChannel})
        as String?);
  }

  void dispose() {
    _disposed = true;
    _channel.setMethodCallHandler(null);
    _watch(const {});
    for (final e in _running.entries) {
      e.value.release(e.key.taskId);
    }
    _running.clear();
  }

  void _open(String? payload) {
    final target = TaskTarget.decode(payload);
    if (target != null) onOpen(target);
  }

  Future<Object?> _invoke(String method, Map<String, Object?> args) async {
    try {
      return await _channel.invokeMethod<Object?>(method, args);
    } on MissingPluginException {
      return null; // tests, desktop
    } on PlatformException {
      return null;
    }
  }

  void _schedule() {
    if (_scheduled || _disposed) return;
    _scheduled = true;
    scheduleMicrotask(_update);
  }

  void _watch(Set<Listenable> next) {
    for (final l in _watching.difference(next)) {
      l.removeListener(_schedule);
    }
    for (final l in next.difference(_watching)) {
      l.addListener(_schedule);
    }
    _watching
      ..clear()
      ..addAll(next);
  }

  /// Whether the user is looking at [t] right now.
  bool _onScreen(TaskTarget t) =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
      app.registry.active?.id == t.deviceId &&
      app.selections[t.selectionKey] == t.taskId;

  void _update() {
    _scheduled = false;
    if (_disposed) return;
    final s = _s;
    final watch = <Listenable>{app};
    final running = <TaskTarget, (WorkspaceSession, TaskItem)>{};
    final finished = <(TaskTarget, TaskItem)>[];
    for (final d in app.sessions) {
      watch.add(d);
      final ws = d.workspace;
      if (ws == null) continue;
      watch.add(ws.tasks);
      // Offline lists are stale: their tasks neither run nor finish here.
      if (!ws.tasks.isLive) {
        for (final t in _running.keys) {
          if (t.deviceId == d.device.id && t.workspaceKey == ws.workspace.key) {
            final item = ws.tasks.find(t.taskId);
            if (item != null) running[t] = (ws, item);
          }
        }
        continue;
      }
      for (final item in ws.tasks.items(TaskListKind.active) + ws.tasks.items(TaskListKind.pinned)) {
        final target = TaskTarget(d.device.id, ws.workspace.key, item.taskId);
        if (item.status == TaskStatus.running) {
          running[target] = (ws, item);
        } else if (_running.containsKey(target)) {
          finished.add((target, item));
        }
      }
    }

    // Keep the conversations of running tasks live for their progress.
    for (final e in _running.entries.toList()) {
      if (!running.containsKey(e.key)) {
        e.value.release(e.key.taskId);
        _running.remove(e.key);
      }
    }
    final progress = <(TaskTarget, TaskProgress)>[];
    for (final e in running.entries) {
      final (ws, item) = e.value;
      _running.putIfAbsent(e.key, () => ws);
      final store = ws.retain(e.key.taskId);
      watch.add(store);
      progress.add((e.key, TaskProgress.of(item.title, store, s)));
    }
    _watch(watch);

    for (final (target, item) in finished) {
      if (_onScreen(target)) continue;
      final text = switch (item.status) {
        TaskStatus.waiting => s.questionTitle,
        TaskStatus.error => s.taskFailed,
        TaskStatus.interrupted => s.taskInterrupted,
        _ => s.taskFinished,
      };
      unawaited(_invoke('done', {
        // 1 is the running notification.
        'id': 2 + (target.encode().hashCode & 0x3fffffff),
        'title': item.title,
        'text': text,
        'payload': target.encode(),
      }));
    }
    _showProgress(progress, s);
  }

  void _showProgress(List<(TaskTarget, TaskProgress)> tasks, S s) {
    if (tasks.isEmpty) {
      if (_shown != null) unawaited(_invoke('stopProgress', const {}));
      _shown = null;
      return;
    }
    final (first, p) = tasks.first;
    final args = tasks.length == 1
        ? {'title': p.title, 'text': p.text, 'lines': const <String>[], 'progress': p.done, 'max': p.total}
        : {
            'title': s.tasksRunning(tasks.length),
            'text': '${p.title} · ${p.text}',
            'lines': [for (final (_, t) in tasks) '${t.title} · ${t.text}'],
            'progress': null,
            'max': null,
          };
    args['payload'] = first.encode();
    final key = Object.hashAll([for (final v in args.values) v is List ? Object.hashAll(v) : v]);
    if (key == _shown) return;
    _shown = key;
    unawaited(_invoke('progress', args));
  }
}
