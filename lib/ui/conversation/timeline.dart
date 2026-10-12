import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/v4/conversation_store.dart';
import '../l10n.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import '../widgets/expand_anchor.dart';
import 'rows.dart';
import 'turn_model.dart';

/// One product turn: user bubble(s), "Worked for …" (collapsed once the turn
/// finished, live while running) and the final answer.
class TurnView extends StatefulWidget {
  const TurnView({super.key, required this.turn, required this.store});
  final TurnGroup turn;
  final ConversationStore store;

  @override
  State<TurnView> createState() => _TurnViewState();
}

class _TurnViewState extends State<TurnView> {
  bool? _expanded;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    final turn = widget.turn;
    final running = turn.running;
    final expanded = _expanded ?? running;
    final duration = turn.durationMs;
    return ExpandAnchor(child: Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final m in turn.boundaries) MarkerRow(row: m),
        for (final input in turn.inputs)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: UserBubble(row: input, store: widget.store),
          ),
        // As in ZCode, a running turn always has its header, counting up.
        if (turn.work.isNotEmpty || running)
          InkWell(
            borderRadius: BorderRadius.circular(ZRadius.md),
            onTap: turn.work.isEmpty
                ? null
                : () => toggleInPlace(context, () => setState(() => _expanded = !expanded)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                // No spinner here: the running row at the bottom has it.
                TurnDurationLabel(running: running, durationMs: duration, startedAt: turn.startedAt),
                if (turn.work.isNotEmpty)
                  Icon(expanded ? Icons.expand_more : Icons.chevron_right,
                      size: 15, color: z.foregroundSubtlest),
              ]),
            ),
          ),
        if (turn.work.isNotEmpty) ...[
          if (expanded)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [for (final r in turn.work) workRowWidget(r, widget.store)],
              ),
            ),
          if (turn.answer != null) Divider(color: z.border, height: 12),
        ],
        if (turn.answer != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: AssistantText(row: turn.answer!, store: widget.store),
          )
        else if (running && turn.work.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              const ZSpinner(size: 11),
              const SizedBox(width: 6),
              Text(s.thinking, style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtle)),
            ]),
          ),
        if (turn.failed || turn.interrupted)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(turn.failed ? s.statusError : s.statusInterrupted,
                style: TextStyle(
                    fontSize: ZText.sm, color: turn.failed ? z.destructive : z.foregroundSubtlest)),
          ),
        for (final m in turn.tail) MarkerRow(row: m),
      ]),
    ));
  }
}

/// Reversed list of turns (newest at the bottom) with widget reuse for
/// unchanged turns, so a streaming delta only rebuilds the active turn.
class Timeline extends StatefulWidget {
  const Timeline({
    super.key,
    required this.store,
    required this.controller,
    this.topPadding = 0,
    this.bottomPadding = 0,
  });
  final ConversationStore store;
  final ScrollController controller;

  /// Room for the surfaces floating over the list (frosted header, dock).
  final double topPadding;
  final double bottomPadding;

  @override
  State<Timeline> createState() => _TimelineState();
}

class _TimelineState extends State<Timeline> {
  /// Keeps an expanding row in place (see [toggleInPlace]).
  final ScrollCorrection _correction = ScrollCorrection();
  final Map<String, (TurnGroup, Widget)> _cache = {};
  List<Map<String, dynamic>>? _lastRows;
  List<TurnGroup> _turns = const [];

  List<TurnGroup> _buildTurns() {
    final rows = widget.store.rows;
    if (!identical(rows, _lastRows)) {
      _lastRows = rows;
      _turns = buildTurns(rows);
    }
    return _turns;
  }

  Widget _turnWidget(TurnGroup turn) {
    final cached = _cache[turn.key];
    if (cached != null && cached.$1.sameRowsAs(turn)) return cached.$2;
    final w = Padding(
      key: ValueKey('turn-${turn.key}'),
      padding: EdgeInsets.zero,
      child: TurnView(key: ValueKey('tv-${turn.key}'), turn: turn, store: widget.store),
    );
    _cache[turn.key] = (turn, w);
    return w;
  }

  @override
  Widget build(BuildContext context) {
    final turns = _buildTurns();
    if (_cache.length > turns.length + 20) {
      final keys = turns.map((t) => t.key).toSet();
      _cache.removeWhere((k, _) => !keys.contains(k));
    }
    final store = widget.store;
    final showOlder = store.hasOlder;
    final count = turns.length + (showOlder ? 1 : 0);
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (showOlder &&
            n.metrics.pixels > n.metrics.maxScrollExtent - 400 &&
            !store.loadingOlder) {
          store.loadOlder();
        }
        return false;
      },
      child: ListView.builder(
        controller: widget.controller,
        reverse: true,
        physics: AnchoredScrollPhysics(correction: _correction),
        padding: EdgeInsets.fromLTRB(16, 16 + widget.topPadding, 16, 16 + widget.bottomPadding),
        itemCount: count,
        findChildIndexCallback: (key) {
          if (key is ValueKey<String> && key.value.startsWith('turn-')) {
            final k = key.value.substring(5);
            final i = turns.indexWhere((t) => t.key == k);
            return i < 0 ? null : turns.length - 1 - i;
          }
          return null;
        },
        itemBuilder: (context, index) {
          if (index >= turns.length) {
            return Padding(
              key: const ValueKey('older'),
              padding: const EdgeInsets.only(bottom: 16),
              child: Center(
                child: store.loadingOlder
                    ? const ZSpinner(size: 14)
                    : TextButton(onPressed: store.loadOlder, child: Text(S.of(context).loadOlder)),
              ),
            );
          }
          final turn = turns[turns.length - 1 - index];
          return Center(
            key: ValueKey('turn-${turn.key}'),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: _turnWidget(turn),
            ),
          );
        },
      ),
    );
  }
}


/// ZCode's turn header text: "Working for 12s" while running, "Worked for
/// 1m 5s" after. The duration is the desktop's `activeMs` (or end − start);
/// while a turn runs without one, it counts up from [startedAt] each second,
/// as ZCode does with its clock.
class TurnDurationLabel extends StatefulWidget {
  const TurnDurationLabel({super.key, required this.running, this.durationMs, this.startedAt, this.now});
  final bool running;
  final int? durationMs;
  final int? startedAt;

  /// Clock override for tests.
  final DateTime Function()? now;

  @override
  State<TurnDurationLabel> createState() => _TurnDurationLabelState();
}

class _TurnDurationLabelState extends State<TurnDurationLabel> {
  Timer? _ticker;

  bool get _counting => widget.running && widget.durationMs == null && widget.startedAt != null;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant TurnDurationLabel old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    if (_counting) {
      _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    var ms = widget.durationMs;
    if (ms == null && _counting) {
      // The desktop's clock may run a little ahead of the phone's.
      ms = math.max(0, (widget.now ?? DateTime.now)().millisecondsSinceEpoch - widget.startedAt!);
    }
    final d = ms == null ? null : (ms < 1000 ? '<1s' : formatDuration(ms));
    return Text(
      switch ((widget.running, d)) {
        (true, final d?) => s.workingFor(d),
        (true, null) => s.working,
        (false, final d?) => s.workedFor(d),
        _ => s.workedFor('<1s'),
      },
      style: TextStyle(fontSize: ZText.sm, color: context.z.foregroundSubtle),
    );
  }
}
