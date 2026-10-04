import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/v4/conversation_store.dart';
import '../l10n.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import '../widgets/expand_anchor.dart';
import '../widgets/markdown_view.dart';
import 'tool_details.dart';
import 'turn_model.dart';

/// Right-aligned user message (`bg-card`, `rounded-xl`).
class UserBubble extends StatelessWidget {
  const UserBubble({super.key, required this.row, required this.store});
  final Map<String, dynamic> row;
  final ConversationStore store;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    final origin = row['origin'] as String? ?? 'realUser';
    var text = row['text'] as String? ?? '';
    final epilogue = (row['epilogueStart'] as num?)?.toInt();
    if (epilogue != null && epilogue <= text.length) text = text.substring(0, epilogue).trimRight();
    final attachments = (row['attachments'] as List?) ?? const [];
    if (origin != 'realUser' && origin != 'workflowLaunch') {
      // Background results, goal continuations… are system inputs: render
      // them as a quiet line instead of a user bubble.
      final label = switch (origin) {
        'backgroundResult' => s.background,
        'goalContinuation' => 'Goal',
        _ => origin,
      };
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text('↳ $label',
            style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtlest)),
      );
    }
    final actions = row['actions'] as Map? ?? const {};
    return Align(
      alignment: Alignment.centerRight,
      child: FractionallySizedBox(
        widthFactor: 0.86,
        alignment: Alignment.centerRight,
        child: Align(
          alignment: Alignment.centerRight,
          child: GestureDetector(
            onLongPress: () => _menu(context, text, actions['canEdit'] == true),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: z.card,
                borderRadius: BorderRadius.circular(ZRadius.xl),
                border: Border.all(color: z.border),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(text,
                    style: TextStyle(fontSize: ZText.base, height: 1.55, color: z.foreground)),
                if (attachments.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Wrap(spacing: 6, runSpacing: 6, children: [
                      for (final a in attachments.whereType<Map>())
                        _Chip(icon: Icons.attach_file, label: '${a['fileName'] ?? ''}'),
                    ]),
                  ),
                if (row['guided'] == true)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('guide',
                        style: TextStyle(fontSize: ZText.xs, color: z.foregroundSubtlest)),
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  void _menu(BuildContext context, String text, bool canEdit) {
    final s = S.of(context);
    showZSheet<void>(context, builder: (ctx) {
      return Column(mainAxisSize: MainAxisSize.min, children: [
        ZMenuItem(
          icon: Icons.copy_rounded,
          title: s.copy,
          onTap: () {
            Navigator.pop(ctx);
            Clipboard.setData(ClipboardData(text: text));
            showToast(context, s.copied);
          },
        ),
        if (canEdit)
          ZMenuItem(
            icon: Icons.edit_outlined,
            title: s.edit,
            onTap: () async {
              Navigator.pop(ctx);
              final edited = await _editDialog(context, text);
              if (edited == null || edited.trim().isEmpty) return;
              try {
                await store.editUserQuery(row, edited.trim());
              } catch (e) {
                if (context.mounted) showToast(context, '$e');
              }
            },
          ),
      ]);
    });
  }

  Future<String?> _editDialog(BuildContext context, String text) {
    final controller = TextEditingController(text: text);
    final s = S.of(context);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.edit),
        content: TextField(controller: controller, maxLines: 8, minLines: 2, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: Text(s.send)),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label});
  final IconData icon;
  final String label;
  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: z.surface,
        borderRadius: BorderRadius.circular(ZRadius.md),
        border: Border.all(color: z.border),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 12, color: z.foregroundSubtle),
        const SizedBox(width: 4),
        Flexible(
          child: Text(label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtle)),
        ),
      ]),
    );
  }
}

/// Assistant answer: full-width Markdown plus copy / retry / feedback.
class AssistantText extends StatelessWidget {
  const AssistantText({super.key, required this.row, required this.store, this.showActions = true});
  final Map<String, dynamic> row;
  final ConversationStore store;
  final bool showActions;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final text = row['text'] as String? ?? '';
    final streaming = row['state'] == 'streaming';
    final actions = row['actions'] as Map? ?? const {};
    final feedback = row['feedback'] as String?;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (text.isEmpty && streaming)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: ZSpinner(size: 12, color: z.foregroundSubtlest),
        )
      else
        MarkdownView(text),
      if (row['state'] == 'failed' || row['state'] == 'interrupted')
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(row['state'] == 'failed' ? S.of(context).toolFailed : S.of(context).statusInterrupted,
              style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtlest)),
        ),
      if (showActions && !streaming && text.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(children: [
            ZIconButton(
              icon: Icons.copy_rounded,
              iconSize: 15,
              size: 28,
              tooltip: S.of(context).copy,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: text));
                showToast(context, S.of(context).copied);
              },
            ),
            if (actions['canRetry'] == true)
              ZIconButton(
                icon: Icons.refresh_rounded,
                iconSize: 16,
                size: 28,
                tooltip: S.of(context).retryTurn,
                onPressed: () => _run(context, () => store.retryTurn(row)),
              ),
            ZIconButton(
              icon: feedback == 'like' ? Icons.thumb_up_alt : Icons.thumb_up_alt_outlined,
              iconSize: 15,
              size: 28,
              onPressed: () =>
                  _run(context, () => store.setFeedback(row, feedback == 'like' ? null : 'like')),
            ),
            ZIconButton(
              icon: feedback == 'dislike' ? Icons.thumb_down_alt : Icons.thumb_down_alt_outlined,
              iconSize: 15,
              size: 28,
              onPressed: () => _run(
                  context, () => store.setFeedback(row, feedback == 'dislike' ? null : 'dislike')),
            ),
          ]),
        ),
    ]);
  }
}

Future<void> _run(BuildContext context, Future<void> Function() op) async {
  try {
    await op();
  } catch (e) {
    if (context.mounted) showToast(context, '$e');
  }
}

/// Collapsible reasoning line ("Thinking" / "Thought · 3s").
class ReasoningRow extends StatefulWidget {
  const ReasoningRow({super.key, required this.row});
  final Map<String, dynamic> row;
  @override
  State<ReasoningRow> createState() => _ReasoningRowState();
}

class _ReasoningRowState extends State<ReasoningRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    final row = widget.row;
    final streaming = row['state'] == 'streaming';
    final ms = (row['durationMs'] as num?)?.toInt();
    final label = streaming ? s.thinking : (ms != null ? '${s.thought} · ${formatDuration(ms)}' : s.thought);
    final text = (row['text'] as String? ?? '').trim();
    return ExpandAnchor(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      InkWell(
        borderRadius: BorderRadius.circular(ZRadius.md),
        onTap: text.isEmpty ? null : () => toggleInPlace(context, () => setState(() => _open = !_open)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (streaming) ...[const ZSpinner(size: 11), const SizedBox(width: 6)],
            Text(label, style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtle)),
            if (text.isNotEmpty)
              Icon(_open ? Icons.expand_less : Icons.chevron_right, size: 14, color: z.foregroundSubtlest),
          ]),
        ),
      ),
      if (!_open && streaming && text.isNotEmpty)
        _ReasoningTicker(text: text)
      else if (_open)
        Container(
          margin: const EdgeInsets.only(top: 2, bottom: 4),
          padding: const EdgeInsets.only(left: 10),
          decoration: BoxDecoration(border: Border(left: BorderSide(color: z.border, width: 2))),
          child: Text(
            text,
            style: TextStyle(fontSize: ZText.sm, height: 1.55, color: z.foregroundSubtle),
          ),
        ),
    ]));
  }
}

/// Single line of the live reasoning, pinned to its newest end so older text
/// scrolls off to the left as more streams in.
class _ReasoningTicker extends StatelessWidget {
  const _ReasoningTicker({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final flat = text.replaceAll(RegExp(r'\s+'), ' ');
    final tail = flat.length > 240 ? flat.substring(flat.length - 240) : flat;
    return Container(
      margin: const EdgeInsets.only(top: 2, bottom: 4),
      padding: const EdgeInsets.only(left: 10),
      decoration: BoxDecoration(border: Border(left: BorderSide(color: z.border, width: 2))),
      child: LayoutBuilder(builder: (context, box) {
        final style = TextStyle(fontSize: ZText.sm, height: 1.55, color: z.foregroundSubtle);
        final line = Text(tail, maxLines: 1, softWrap: false, style: style);
        final painter = TextPainter(
          text: TextSpan(text: tail, style: style),
          maxLines: 1,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final overflows = painter.width > box.maxWidth;
        painter.dispose();
        if (!overflows) return line;
        return ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (r) => const LinearGradient(
            colors: [Color(0x00000000), Color(0xFF000000)],
            stops: [0, 0.12],
          ).createShader(r),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            physics: const NeverScrollableScrollPhysics(),
            child: line,
          ),
        );
      }),
    );
  }
}

IconData toolIcon(String name) {
  final n = name.toLowerCase();
  if (n.contains('todo')) return Icons.checklist_rounded;
  if (n.contains('bash') || n.contains('shell') || n.contains('exec')) return Icons.terminal_rounded;
  if (n == 'read' || n.contains('read')) return Icons.description_outlined;
  if (n.contains('edit') || n.contains('write') || n.contains('patch')) return Icons.edit_note_rounded;
  if (n.contains('grep') || n.contains('glob') || n.contains('search') || n == 'ls') {
    return Icons.search_rounded;
  }
  if (n.contains('web') || n.contains('fetch')) return Icons.public_rounded;
  if (n.contains('todo')) return Icons.checklist_rounded;
  if (n.contains('agent') || n == 'task') return Icons.smart_toy_outlined;
  if (n.contains('question') || n.contains('plan')) return Icons.help_outline_rounded;
  if (n.startsWith('mcp')) return Icons.extension_outlined;
  return Icons.build_outlined;
}

/// Compact tool call line; tap to expand input / output / diff.
class ToolCallRow extends StatefulWidget {
  const ToolCallRow({super.key, required this.row});
  final Map<String, dynamic> row;
  @override
  State<ToolCallRow> createState() => _ToolCallRowState();
}

class _ToolCallRowState extends State<ToolCallRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    final row = widget.row;
    final name = row['toolName'] as String? ?? 'tool';
    final status = row['status'] as String? ?? 'running';
    final summary = toolSummary(row);
    final running = status == 'inputStreaming' || status == 'running';
    final Widget statusWidget = switch (status) {
      // A running call's spinner gets its own line below (see the end).
      'inputStreaming' || 'running' => const SizedBox.shrink(),
      'pendingApproval' => Text(s.toolPending,
          style: TextStyle(fontSize: ZText.xs, color: z.confirmForeground)),
      'error' => Icon(Icons.close_rounded, size: 14, color: z.destructive),
      'cancelled' => Icon(Icons.block_rounded, size: 13, color: z.foregroundSubtlest),
      _ => const SizedBox.shrink(),
    };
    final diff = _diffDisplay(row) ?? (toolFamily(name) == ToolFamily.write ? inputDiff(row) : null);
    final family = toolFamily(name, hasDiff: diff != null);
    // As in ZCode, Read / Grep / Glob calls are a summary line only.
    final expandable = family != ToolFamily.explore;
    final open = _open && expandable;
    final todos = family == ToolFamily.todo ? parseTodos(row) : const <TodoEntry>[];
    return ExpandAnchor(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InkWell(
        borderRadius: BorderRadius.circular(ZRadius.md),
        onTap: expandable ? () => toggleInPlace(context, () => setState(() => _open = !_open)) : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            Icon(toolIcon(name), size: 15, color: z.foregroundSubtle),
            const SizedBox(width: 8),
            Text(family == ToolFamily.todo ? s.todoKind : name,
                style: TextStyle(
                    fontSize: ZText.sm, fontWeight: FontWeight.w500, color: z.foreground)),
            const SizedBox(width: 6),
            Expanded(
              // An open shell call shows its command in the card instead.
              child: Text(open && family == ToolFamily.shell ? '' : currentTodo(todos) ?? summary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: ZText.sm,
                    color: z.foregroundSubtle,
                    fontFamily: todos.isEmpty ? zMonoFamily : null,
                    fontFamilyFallback: todos.isEmpty ? zMonoFallback : null,
                  )),
            ),
            if (todos.isNotEmpty) ...[
              Text('${todos.where((t) => t.status == 'completed').length}/${todos.length}',
                  style: TextStyle(
                      fontSize: ZText.sm,
                      color: z.foregroundSubtlest,
                      fontFamily: zMonoFamily,
                      fontFamilyFallback: zMonoFallback,
                      fontFeatures: const [FontFeature.tabularFigures()])),
              const SizedBox(width: 6),
            ],
            if (diff != null) ...[
              Text('+${diff['additions'] ?? 0}',
                  style: TextStyle(fontSize: ZText.xs, color: z.success)),
              const SizedBox(width: 4),
              Text('-${diff['deletions'] ?? 0}',
                  style: TextStyle(fontSize: ZText.xs, color: z.destructive)),
              const SizedBox(width: 6),
            ],
            statusWidget,
            if (open) ...[
              const SizedBox(width: 2),
              Icon(Icons.expand_more_rounded, size: 16, color: z.foregroundSubtlest),
            ],
          ]),
        ),
      ),
      if (running) const RunningLine(),
      if (open) ToolDetails(row: row, family: family, diff: diff),
    ]));
  }

  static Map<String, dynamic>? _diffDisplay(Map<String, dynamic> row) {
    final display = row['display'];
    if (display is Map<String, dynamic>) {
      if (display['kind'] == 'file_diff') return display;
      final result = display['result'];
      if (result is Map<String, dynamic> && result['kind'] == 'file_diff') return result;
    }
    return null;
  }
}

class SubagentRow extends StatelessWidget {
  const SubagentRow({super.key, required this.row});
  final Map<String, dynamic> row;
  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final running = row['status'] == 'running';
    final summary = (row['summaryText'] as String? ?? '').trim();
    final line = Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.smart_toy_outlined, size: 15, color: z.foregroundSubtle),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${row['subagentType'] ?? 'agent'}',
                style: TextStyle(fontSize: ZText.sm, fontWeight: FontWeight.w500, color: z.foreground)),
            if (summary.isNotEmpty)
              Text(summary,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtle)),
          ]),
        ),
        if (row['status'] == 'failed') Icon(Icons.close_rounded, size: 14, color: z.destructive),
      ]),
    );
    return running
        ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [line, const RunningLine()])
        : line;
  }
}

/// The spinner of a running tool call or subagent, on a line of its own
/// below it, centred in the 15 px icon column the rows share.
class RunningLine extends StatelessWidget {
  const RunningLine({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.only(bottom: 5),
        child: Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(width: 15, child: Center(child: ZSpinner(size: 11))),
        ),
      );
}

/// Timeline markers (compact, model change, retries…).
class MarkerRow extends StatelessWidget {
  const MarkerRow({super.key, required this.row});
  final Map<String, dynamic> row;
  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    final m = row['marker'] as Map? ?? const {};
    final text = switch (m['type']) {
      'compact' => '${s.compact} · ${m['status']}',
      'modelChange' => m['fromModel'] != null
          ? '${m['fromModel']} → ${m['toModel']}'
          : '${m['toModel']}',
      'goalSet' => 'Goal: ${m['objective']}',
      'goalVerify' => 'Goal #${m['iteration']} · ${m['outcome']}',
      'retryNotice' => 'Retry #${m['attempt']} · ${m['reasonCode']}',
      'checkpointRestored' => 'Checkpoint restored',
      'forkNotice' || 'forkCreated' => 'Fork',
      _ => '${m['type']}',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(child: Divider(color: z.border, height: 1)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(text, style: TextStyle(fontSize: ZText.xs, color: z.foregroundSubtlest)),
        ),
        Expanded(child: Divider(color: z.border, height: 1)),
      ]),
    );
  }
}

Widget workRowWidget(Map<String, dynamic> row, ConversationStore store) {
  final key = ValueKey('r${row['rowId']}');
  return switch (row['kind']) {
    'reasoning' => ReasoningRow(key: key, row: row),
    'toolCall' => ToolCallRow(key: key, row: row),
    'subagent' => SubagentRow(key: key, row: row),
    'timelineMarker' => MarkerRow(key: key, row: row),
    'assistantText' => Padding(
        key: key,
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: AssistantText(row: row, store: store, showActions: false),
      ),
    'artifact' => Padding(
        key: key,
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: _Chip(icon: Icons.insert_drive_file_outlined, label: '${row['displayName']}'),
      ),
    'hookInvocation' => Builder(
        key: key,
        builder: (context) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Text('hook · ${row['hookEventName']} · ${row['state']}',
              style: TextStyle(fontSize: ZText.xs, color: context.z.foregroundSubtlest)),
        ),
      ),
    _ => SizedBox.shrink(key: key),
  };
}
