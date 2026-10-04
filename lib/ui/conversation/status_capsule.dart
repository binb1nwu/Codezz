import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/v4/conversation_store.dart';
import '../../state/device_session.dart';
import '../l10n.dart';
import '../theme/tokens.dart';
import '../widgets/glass.dart';
import '../widgets/common.dart';

/// Line counts of the workspace's uncommitted changes (`git.refresh`).
class GitStatus {
  const GitStatus({this.branch, this.added = 0, this.removed = 0});

  /// Null when the workspace is not a usable repository.
  static GitStatus? fromRefresh(Map<String, dynamic> res) {
    final summary = res['summary'];
    if (summary is! Map || summary['isGitAvailable'] == false || summary['isRepository'] == false) return null;
    var added = 0, removed = 0;
    for (final key in const ['unstagedChanges', 'stagedChanges']) {
      for (final c in res[key] is List ? res[key] as List : const []) {
        if (c is! Map) continue;
        added += (c['added'] as num?)?.toInt() ?? 0;
        removed += (c['removed'] as num?)?.toInt() ?? 0;
      }
    }
    return GitStatus(branch: summary['branchName'] as String?, added: added, removed: removed);
  }

  final String? branch;
  final int added;
  final int removed;
  bool get dirty => added + removed > 0;
}

class TodoItem {
  const TodoItem(this.content, this.status);
  final String content;

  /// `pending` / `inProgress` / `completed`.
  final String status;
}

class RunningItem {
  const RunningItem({required this.title, this.startedAt, this.workId, this.cancellable = false});
  final String title;
  final int? startedAt;

  /// The background work to cancel, when it can be stopped.
  final String? workId;
  final bool cancellable;
}

/// What ZCode's status panel shows, derived from a V4 conversation state
/// (`plan`, `goal`, `backgroundWorks`, `subagents`) and the workspace's git
/// changes.
class StatusModel {
  StatusModel({
    this.todos = const [],
    this.goal,
    this.git,
    this.bash = const [],
    this.agents = const [],
  });

  factory StatusModel.from(ConversationStore store, GitStatus? git) {
    final todos = [
      for (final i in _list(store.plan?['items']))
        TodoItem('${i['content'] ?? ''}', '${i['status'] ?? 'pending'}'),
    ];
    final works = [for (final w in store.backgroundWorks) if (w['status'] == 'running') w];
    final bash = [
      for (final w in works)
        if (w['kind'] == 'bash')
          RunningItem(
            title: '${w['title'] ?? ''}',
            startedAt: (w['startedAt'] as num?)?.toInt(),
            workId: '${w['workId']}',
            cancellable: w['cancellable'] != false,
          ),
    ]..sort((a, b) => (a.startedAt ?? 0).compareTo(b.startedAt ?? 0));
    // Running subagents, stoppable through their one background work.
    final agentWorks = [for (final w in works) if (w['kind'] == 'subagent') w];
    final agents = <RunningItem>[];
    final seen = <String>{};
    for (final a in _list(store.subagents['running'])) {
      final child = '${a['childSessionId']}';
      seen.add(child);
      final matches = agentWorks.where((w) => '${w['childSessionId']}' == child).toList();
      final work = matches.length == 1 ? matches.single : null;
      agents.add(RunningItem(
        title: '${a['title'] ?? a['subagentType'] ?? ''}',
        startedAt: (a['startedAt'] as num?)?.toInt() ?? (work?['startedAt'] as num?)?.toInt(),
        workId: work == null ? null : '${work['workId']}',
        cancellable: work != null && work['cancellable'] != false,
      ));
    }
    for (final w in agentWorks) {
      if (seen.contains('${w['childSessionId']}')) continue;
      agents.add(RunningItem(
        title: '${w['title'] ?? ''}',
        startedAt: (w['startedAt'] as num?)?.toInt(),
        workId: '${w['workId']}',
        cancellable: w['cancellable'] != false,
      ));
    }
    return StatusModel(todos: todos, goal: store.goal, git: git, bash: bash, agents: agents);
  }

  final List<TodoItem> todos;
  final Map<String, dynamic>? goal;
  final GitStatus? git;
  final List<RunningItem> bash;
  final List<RunningItem> agents;

  static List<Map<String, dynamic>> _list(Object? v) =>
      v is List ? v.whereType<Map<String, dynamic>>().toList() : const [];

  bool get hasGit => git?.dirty ?? false;
  int get running => bash.length + agents.length;
  bool get isEmpty => !hasGit && goal == null && todos.isEmpty && running == 0;

  String get goalStatus => '${goal?['status'] ?? ''}';
  String get goalTitle {
    final g = goal;
    if (g == null) return '';
    final summary = (g['summaryTitle'] as String?)?.trim() ?? '';
    return summary.isNotEmpty ? summary : '${g['objective'] ?? ''}'.trim();
  }

  int get todosDone => todos.where((t) => t.status == 'completed').length;

  /// Seconds the goal has run, ticking while a run is active.
  int goalElapsed(DateTime now) {
    final g = goal;
    if (g == null) return 0;
    var s = (g['timeUsedSeconds'] as num?)?.toDouble() ?? 0;
    final start = (g['activeRunStartedAtMs'] as num?)?.toInt();
    if (start != null && const {'active', 'verifying', 'notSatisfied'}.contains(goalStatus)) {
      s += math.max(0, now.millisecondsSinceEpoch - start) / 1000;
    }
    return s.floor();
  }

  /// The single segment the collapsed capsule shows, in ZCode's order.
  CapsuleSegment? capsule() {
    final current = todos.where((t) => t.status == 'inProgress').firstOrNull ??
        todos.where((t) => t.status == 'pending').firstOrNull;
    if (current != null) return CapsuleSegment.todo(current.content);
    if (goal != null && const {'active', 'notSatisfied', 'paused', 'verifying'}.contains(goalStatus)) {
      return CapsuleSegment.goal(goalTitle);
    }
    if (hasGit) return CapsuleSegment.git(git!.added, git!.removed);
    if (goal != null && goalStatus == 'verified') return CapsuleSegment.goal(goalTitle);
    final done = todos.where((t) => t.status == 'completed').lastOrNull;
    if (done != null) return CapsuleSegment.done(done.content);
    if (running > 0) return CapsuleSegment.running(bash.length, agents.length);
    return null;
  }
}

enum CapsuleKind { todo, goal, git, done, running }

class CapsuleSegment {
  const CapsuleSegment._(this.kind, {this.text = '', this.added = 0, this.removed = 0, this.bash = 0, this.agents = 0});
  const CapsuleSegment.todo(String text) : this._(CapsuleKind.todo, text: text);
  const CapsuleSegment.goal(String text) : this._(CapsuleKind.goal, text: text);
  const CapsuleSegment.git(int added, int removed) : this._(CapsuleKind.git, added: added, removed: removed);
  const CapsuleSegment.done(String text) : this._(CapsuleKind.done, text: text);
  const CapsuleSegment.running(int bash, int agents) : this._(CapsuleKind.running, bash: bash, agents: agents);

  final CapsuleKind kind;
  final String text;
  final int added;
  final int removed;
  final int bash;
  final int agents;
}

/// ZCode's status capsule: floats at the conversation's top right (16 px
/// from the top and right edges, over the messages). Collapsed it shows one
/// segment; tapping expands the same card in place into the status panel.
class StatusCapsule extends StatefulWidget {
  const StatusCapsule({super.key, required this.store, required this.workspace, required this.expanded});
  final ConversationStore store;
  final WorkspaceSession workspace;

  /// Shared with the composer's background-work button, which also opens
  /// the panel.
  final ValueNotifier<bool> expanded;

  @override
  State<StatusCapsule> createState() => _StatusCapsuleState();
}

class _StatusCapsuleState extends State<StatusCapsule> {
  GitStatus? _git;
  bool _wasRunning = false;
  Timer? _ticker;
  int _gitGeneration = 0;

  @override
  void initState() {
    super.initState();
    _wasRunning = widget.store.running;
    widget.store.addListener(_onStore);
    widget.expanded.addListener(_onExpanded);
    _refreshGit();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant StatusCapsule old) {
    super.didUpdateWidget(old);
    if (old.store != widget.store) {
      old.store.removeListener(_onStore);
      widget.store.addListener(_onStore);
      _wasRunning = widget.store.running;
      _refreshGit();
    }
    if (old.expanded != widget.expanded) {
      old.expanded.removeListener(_onExpanded);
      widget.expanded.addListener(_onExpanded);
    }
  }

  @override
  void dispose() {
    widget.store.removeListener(_onStore);
    widget.expanded.removeListener(_onExpanded);
    _ticker?.cancel();
    super.dispose();
  }

  /// Git changes are re-read when a turn ends (the agent may have edited
  /// files) and when the panel opens.
  void _onStore() {
    final running = widget.store.running;
    if (_wasRunning && !running) _refreshGit();
    _wasRunning = running;
    _syncTicker();
  }

  void _onExpanded() {
    if (widget.expanded.value) _refreshGit();
    setState(() {});
  }

  Future<void> _refreshGit() async {
    final api = widget.workspace.api;
    if (api == null) return;
    final gen = ++_gitGeneration;
    try {
      final git = GitStatus.fromRefresh(await api.gitRefresh(widget.workspace.workspace));
      if (mounted && gen == _gitGeneration) setState(() => _git = git);
    } catch (_) {
      // No git service (or no repository): the panel just omits it.
    }
  }

  /// A second timer runs only while something shows elapsed time.
  void _syncTicker() {
    final m = StatusModel.from(widget.store, _git);
    final ticking = m.running > 0 || const {'active', 'verifying', 'notSatisfied'}.contains(m.goalStatus);
    if (ticking && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted && widget.expanded.value) setState(() {});
      });
    } else if (!ticking) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  Future<void> _run(Future<void> Function() op) async {
    try {
      await op();
    } catch (e) {
      if (mounted) showToast(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) {
        final model = StatusModel.from(widget.store, _git);
        final expanded = widget.expanded.value;
        if (model.isEmpty) return const SizedBox.shrink();
        final segment = model.capsule();
        if (!expanded && segment == null) return const SizedBox.shrink();
        final z = context.z;
        return AnimatedSize(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          alignment: Alignment.topRight,
          child: Glass(
            borderRadius: BorderRadius.circular(ZRadius.x2l),
            child: Material(
            color: glassColor(context, z.popover),
            // A shadow would show through the frosted capsule.
            elevation: GlassScope.of(context) ? 0 : 4,
            shadowColor: Colors.black.withValues(alpha: 0.25),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(ZRadius.x2l),
              side: BorderSide(color: z.border),
            ),
            clipBehavior: Clip.antiAlias,
            child: expanded
                ? _Panel(
                    model: model,
                    store: widget.store,
                    onCollapse: () => widget.expanded.value = false,
                    onOpenReview: widget.workspace.sidePane.openReview,
                    run: _run,
                  )
                : _Capsule(segment: segment!, onTap: () => widget.expanded.value = true),
          ),
          ),
        );
      },
    );
  }
}

class _Capsule extends StatelessWidget {
  const _Capsule({required this.segment, required this.onTap});
  final CapsuleSegment segment;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    final text = TextStyle(fontSize: ZText.base, color: z.foreground);
    final (IconData icon, Color iconColor, Widget label) = switch (segment.kind) {
      CapsuleKind.todo => (Icons.arrow_forward_rounded, z.foreground, _one(segment.text, text)),
      CapsuleKind.goal => (Icons.flag_outlined, z.foreground, _one(segment.text, text)),
      CapsuleKind.done => (Icons.check_circle_outline_rounded, z.success, _one(segment.text, text)),
      CapsuleKind.git => (
          Icons.difference_outlined,
          z.foreground,
          Row(mainAxisSize: MainAxisSize.min, children: [
            Text(s.changesLabel, style: text),
            const SizedBox(width: 6),
            _DiffCounts(added: segment.added, removed: segment.removed),
          ]),
        ),
      CapsuleKind.running => (
          segment.agents == 0
              ? Icons.terminal_rounded
              : segment.bash == 0
                  ? Icons.smart_toy_outlined
                  : Icons.monitor_heart_outlined,
          z.foreground,
          Text(
            segment.agents > 0
                ? s.runningAgents(segment.bash + segment.agents)
                : s.runningBackgroundShort(segment.bash),
            style: text,
          ),
        ),
    };
    return Tooltip(
      message: s.showStatus,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320, minHeight: 32, maxHeight: 32),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 12, 0),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 16, color: iconColor),
              const SizedBox(width: 6),
              Flexible(child: label),
            ]),
          ),
        ),
      ),
    );
  }

  static Widget _one(String text, TextStyle style) =>
      Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
}

class _DiffCounts extends StatelessWidget {
  const _DiffCounts({required this.added, required this.removed});
  final int added;
  final int removed;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final mono = TextStyle(fontFamily: zMonoFamily, fontFamilyFallback: zMonoFallback, fontSize: ZText.sm);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text('+$added', style: mono.copyWith(color: z.success)),
      const SizedBox(width: 4),
      Text('-$removed', style: mono.copyWith(color: z.destructive)),
    ]);
  }
}

/// The expanded status panel: Git tools, goal, progress, terminals, agents.
class _Panel extends StatefulWidget {
  const _Panel({
    required this.model,
    required this.store,
    required this.onCollapse,
    required this.onOpenReview,
    required this.run,
  });

  final StatusModel model;
  final ConversationStore store;
  final VoidCallback onCollapse;
  final VoidCallback onOpenReview;
  final Future<void> Function(Future<void> Function()) run;

  @override
  State<_Panel> createState() => _PanelState();
}

class _PanelState extends State<_Panel> {
  /// Sections closed by the user; terminals and agents start closed.
  final Set<String> _closed = {'terminal', 'agent'};

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    final m = widget.model;
    final now = DateTime.now();
    final media = MediaQuery.sizeOf(context);
    final sections = <Widget>[
      if (m.hasGit) _gitSection(s),
      if (m.goal != null) _goalSection(s, now),
      if (m.todos.isNotEmpty) _todoSection(s),
      if (m.bash.isNotEmpty) _runningSection(s, 'terminal', s.terminals, m.bash, Icons.terminal_rounded, now),
      if (m.agents.isNotEmpty) _runningSection(s, 'agent', s.agents, m.agents, Icons.smart_toy_outlined, now),
    ];
    return SizedBox(
      width: math.min(320, media.width - 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: math.min(media.height * 0.64, 512)),
        child: Stack(children: [
          SingleChildScrollView(
            padding: const EdgeInsets.all(8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (var i = 0; i < sections.length; i++)
                Container(
                  margin: EdgeInsets.only(top: i == 0 ? 0 : 8),
                  padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
                  decoration:
                      i == 0 ? null : BoxDecoration(border: Border(top: BorderSide(color: z.border))),
                  child: sections[i],
                ),
            ]),
          ),
          Positioned(
            right: 8,
            top: 8,
            child: ZIconButton(
              icon: Icons.close_fullscreen_rounded,
              size: 28,
              iconSize: 15,
              tooltip: s.collapseStatus,
              onPressed: widget.onCollapse,
            ),
          ),
        ]),
      ),
    );
  }

  Widget _section(String id, String title, List<Widget> rows, {Widget? trailing, Widget? collapsedTrailing}) {
    final z = context.z;
    final open = !_closed.contains(id);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InkWell(
        borderRadius: BorderRadius.circular(ZRadius.lg),
        onTap: () => setState(() => open ? _closed.add(id) : _closed.remove(id)),
        child: SizedBox(
          height: 32,
          child: Padding(
            // Room for the collapse button on the first row.
            padding: const EdgeInsets.fromLTRB(8, 0, 36, 0),
            child: Row(children: [
              Text(title, style: TextStyle(fontSize: ZText.base, color: z.foregroundSubtle)),
              Icon(open ? Icons.expand_more_rounded : Icons.chevron_right_rounded,
                  size: 14, color: z.foregroundSubtlest),
              const Spacer(),
              if (!open && collapsedTrailing != null) collapsedTrailing else if (trailing != null) trailing,
            ]),
          ),
        ),
      ),
      if (open) ...rows,
    ]);
  }

  Widget _trailing(String text, {Color? color}) => Text(text,
      style: TextStyle(fontSize: ZText.sm, color: color ?? context.z.foregroundSubtlest));

  Widget _row({required Widget leading, required Widget child, Widget? trailing, VoidCallback? onTap}) {
    return InkWell(
      borderRadius: BorderRadius.circular(ZRadius.lg),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 32),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 2), child: leading),
            const SizedBox(width: 8),
            Expanded(child: child),
            if (trailing != null) ...[const SizedBox(width: 8), trailing],
          ]),
        ),
      ),
    );
  }

  Widget _text(String text, {Color? color, TextDecoration? decoration, int maxLines = 2}) => Text(text,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
          fontSize: ZText.base, height: 1.43, color: color ?? context.z.foreground, decoration: decoration));

  Widget _gitSection(S s) {
    final z = context.z;
    final git = widget.model.git!;
    return _section('environment', s.gitTools, collapsedTrailing: _DiffCounts(added: git.added, removed: git.removed), [
      _row(
        leading: Icon(Icons.difference_outlined, size: 16, color: z.foregroundSubtle),
        child: Row(children: [
          Text(s.changesLabel, style: TextStyle(fontSize: ZText.base, color: z.foreground)),
          const SizedBox(width: 8),
          _DiffCounts(added: git.added, removed: git.removed),
        ]),
        onTap: widget.onOpenReview,
      ),
      if (git.branch != null)
        _row(
          leading: Icon(Icons.call_split_rounded, size: 16, color: z.foregroundSubtle),
          child: _text(git.branch!, maxLines: 1),
        ),
    ]);
  }

  Widget _goalSection(S s, DateTime now) {
    final z = context.z;
    final m = widget.model;
    final goal = m.goal!;
    final availability = widget.store.availability;
    bool allowed(String key) => (availability[key] as Map?)?['allowed'] == true;
    final status = m.goalStatus;
    Widget? control;
    if (status == 'verified') {
      control = Icon(Icons.task_alt_rounded, size: 14, color: z.success);
    } else if (allowed('pauseGoal')) {
      control = _mini(Icons.pause_rounded, s.pauseGoal, () => widget.run(widget.store.pauseGoal));
    } else if (allowed('resumeGoal')) {
      control = _mini(Icons.play_arrow_rounded, s.resumeGoal, () => widget.run(widget.store.resumeGoal));
    }
    final iterations = StatusModel._list(goal['iterations']);
    final verifications = StatusModel._list(goal['verifications']);
    final current = (goal['iteration'] as num?)?.toInt() ?? iterations.length;
    final rows = <Widget>[];
    for (var n = 1; n <= math.max(current, 1); n++) {
      String text;
      if (n == 1) {
        text = m.goalTitle;
      } else {
        final next = verifications.length >= n - 1 ? '${verifications[n - 2]['nextAction'] ?? ''}'.trim() : '';
        text = next.isEmpty || next == 'Continue verifying and completing the goal.' ? s.goalIteration(n) : next;
      }
      final items = iterations.where((i) => i['iteration'] == n).firstOrNull?['items'];
      final list = items is List ? items.whereType<Map>().toList() : const <Map>[];
      final done = n < current || status == 'verified';
      rows.add(_row(
        leading: Container(
          width: 16,
          height: 16,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: done ? z.success : z.foregroundSubtlest),
          ),
          child: Text('$n', style: TextStyle(fontSize: 9, color: done ? z.success : z.foregroundSubtle)),
        ),
        child: _text(text, maxLines: 3),
        trailing: list.isEmpty
            ? null
            : _trailing('${list.where((i) => i['status'] == 'completed').length}/${list.length}'),
      ));
    }
    return _section('goal', s.goal, rows,
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          _trailing(s.elapsed(m.goalElapsed(now))),
          if (control != null) ...[_trailing(' · '), control],
        ]));
  }

  Widget _mini(IconData icon, String tooltip, VoidCallback onTap) => ZIconButton(
        icon: icon,
        size: 24,
        iconSize: 14,
        tooltip: tooltip,
        onPressed: onTap,
      );

  Widget _todoSection(S s) {
    final z = context.z;
    final todos = widget.model.todos;
    final done = widget.model.todosDone;
    Widget todo(TodoItem t) {
      final (IconData icon, Color color) = switch (t.status) {
        'completed' => (Icons.check_circle_outline_rounded, z.success),
        'inProgress' => (Icons.arrow_forward_rounded, z.foreground),
        _ => (Icons.circle_outlined, z.foregroundSubtlest),
      };
      final completed = t.status == 'completed';
      return _row(
        leading: Icon(icon, size: 14, color: color),
        child: _text(t.content,
            color: completed ? z.foregroundSubtlest : null,
            decoration: completed ? TextDecoration.lineThrough : null),
      );
    }

    Widget fold(String label, List<TodoItem> items) => _row(
          leading: Icon(Icons.chevron_left_rounded, size: 14, color: z.foregroundSubtle),
          child: Text(label, style: TextStyle(fontSize: ZText.base, color: z.foregroundSubtle)),
          onTap: () => showZSheet<void>(context, title: label, builder: (ctx) {
            return ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
              for (final t in items) todo(t),
            ]);
          }),
        );

    final rows = <Widget>[];
    final window = todoWindow(todos);
    if (window == null) {
      rows.addAll(todos.map(todo));
    } else {
      final before = todos.sublist(0, window.$1);
      final shown = todos.sublist(window.$1, window.$2);
      final after = todos.sublist(window.$2);
      if (before.isNotEmpty) {
        rows.add(fold(
            before.every((t) => t.status == 'completed')
                ? s.todoCompletedFold(before.length)
                : s.todoEarlierFold(before.length),
            before));
      }
      rows.addAll(shown.map(todo));
      if (after.isNotEmpty) {
        rows.add(fold(
            after.every((t) => t.status == 'pending') ? s.todoWaitingFold(after.length) : s.todoLaterFold(after.length),
            after));
      }
    }
    return _section('plan', s.progress, rows,
        trailing: _trailing('$done/${todos.length}', color: done == todos.length ? z.success : null));
  }

  Widget _runningSection(S s, String id, String title, List<RunningItem> items, IconData icon, DateTime now) {
    final z = context.z;
    int seconds(RunningItem i) =>
        i.startedAt == null ? 0 : math.max(0, now.millisecondsSinceEpoch - i.startedAt!) ~/ 1000;
    final longest = items.map(seconds).fold(0, math.max);
    final count = id == 'agent' ? s.runningAgents(items.length) : s.runningBackground(items.length);
    final shortCount = id == 'agent' ? s.runningAgents(items.length) : s.runningBackgroundShort(items.length);
    return _section(id, title, trailing: _trailing(count), collapsedTrailing: _trailing('${s.elapsed(longest)} · $shortCount'), [
      for (final i in items)
        _row(
          leading: Icon(icon, size: 16, color: z.foregroundSubtle),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _text(i.title),
            Row(children: [
              Text(s.runningFor(seconds(i)), style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtle)),
              const Spacer(),
              if (i.cancellable && i.workId != null)
                TextButton.icon(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 24),
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: () => widget.run(() => widget.store.cancelBackgroundWork(i.workId!)),
                  icon: const Icon(Icons.stop_rounded, size: 12),
                  label: Text(s.stop2, style: const TextStyle(fontSize: ZText.sm)),
                ),
            ]),
          ]),
        ),
    ]);
  }
}

/// The items [start, end) shown unfolded when a todo list has more than six
/// items: three from the current (or first unfinished) one, else the last
/// three. Null when everything is shown.
(int, int)? todoWindow(List<TodoItem> todos) {
  if (todos.length <= 6) return null;
  var start = todos.indexWhere((t) => t.status == 'inProgress');
  if (start < 0) start = todos.indexWhere((t) => t.status != 'completed');
  if (start < 0) start = todos.length - 3;
  start = math.min(start, todos.length - 3);
  return (start, start + 3);
}
