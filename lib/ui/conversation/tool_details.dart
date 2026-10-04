import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import '../widgets/expand_anchor.dart';

/// How ZCode renders a tool call (`mit()` in its web client): by family.
enum ToolFamily {
  /// Bash and friends: `$ command` and its output in one panel card.
  shell,

  /// Read / Grep / Glob / LS: summary row only, never expanded.
  explore,

  /// Edit / Write: the file diff.
  write,

  /// TodoWrite: the current item and `done/total`, expanding to the list.
  todo,

  /// MCP and everything else: result, then the call's parameters.
  other,
}

ToolFamily toolFamily(String name, {bool hasDiff = false}) {
  final n = name.toLowerCase();
  if (n.contains('todo')) return ToolFamily.todo;
  if (n.contains('bash') || n.contains('shell') || n.contains('exec') || n == 'terminal') return ToolFamily.shell;
  if (hasDiff || n.contains('edit') || n.contains('write') || n.contains('patch')) {
    // TodoWrite is a plan update, not a file write.
    if (!n.contains('todo')) return ToolFamily.write;
  }
  if (n == 'read' || n == 'grep' || n == 'glob' || n == 'ls' || n == 'search' || n == 'find') {
    return ToolFamily.explore;
  }
  return ToolFamily.other;
}

/// A `file_diff`-shaped display built from an Edit / MultiEdit / Write
/// call's own input, for calls the desktop sent without one. Lines shared at
/// the start and end of each edit stay as context.
Map<String, dynamic>? inputDiff(Map<String, dynamic> row) {
  final input = row['input'];
  if (input is! Map) return null;
  final pairs = <(String, String)>[
    if (input['old_string'] is String && input['new_string'] is String)
      (input['old_string'] as String, input['new_string'] as String),
    for (final e in input['edits'] is List ? input['edits'] as List : const [])
      if (e is Map && e['old_string'] is String && e['new_string'] is String)
        (e['old_string'] as String, e['new_string'] as String),
    if (input['content'] is String && input['old_string'] == null) ('', input['content'] as String),
  ];
  if (pairs.isEmpty) return null;
  var additions = 0, deletions = 0;
  final hunks = <Map<String, dynamic>>[];
  for (final (before, after) in pairs) {
    final a = before.isEmpty ? <String>[] : before.split('\n');
    final b = after.isEmpty ? <String>[] : after.split('\n');
    var start = 0;
    while (start < a.length && start < b.length && a[start] == b[start]) {
      start++;
    }
    var end = 0;
    while (end < a.length - start && end < b.length - start && a[a.length - 1 - end] == b[b.length - 1 - end]) {
      end++;
    }
    final removed = a.sublist(start, a.length - end);
    final added = b.sublist(start, b.length - end);
    additions += added.length;
    deletions += removed.length;
    hunks.add({
      'lines': [
        for (final l in a.sublist(0, start)) ' $l',
        for (final l in removed) '-$l',
        for (final l in added) '+$l',
        for (final l in a.sublist(a.length - end)) ' $l',
      ],
    });
  }
  return {'kind': 'file_diff', 'structuredPatch': hunks, 'additions': additions, 'deletions': deletions};
}

/// One item of a todo call: its text and `pending` / `in_progress` /
/// `completed`.
typedef TodoEntry = ({String text, String status});

/// The todo list a TodoWrite call sets, read the way ZCode does: the text is
/// the first of content / step / title / text / activeForm, statuses are
/// normalised (`in-progress` → `in_progress`) and unknown ones dropped; a
/// bare string is in progress when first, pending otherwise.
List<TodoEntry> parseTodos(Map<String, dynamic> row) {
  final input = row['input'];
  final raw = input is Map ? (input['todos'] ?? input['items'] ?? input['plan']) : null;
  if (raw is! List) return const [];
  final out = <TodoEntry>[];
  for (final (i, item) in raw.indexed) {
    if (item is String) {
      if (item.trim().isNotEmpty) out.add((text: item.trim(), status: i == 0 ? 'in_progress' : 'pending'));
      continue;
    }
    if (item is! Map) continue;
    final text = [for (final k in const ['content', 'step', 'title', 'text', 'activeForm']) item[k]]
        .whereType<String>()
        .map((t) => t.trim())
        .firstWhere((t) => t.isNotEmpty, orElse: () => '');
    final status = '${item['status'] ?? ''}'.replaceAll('-', '_');
    if (text.isEmpty || !const ['pending', 'in_progress', 'completed'].contains(status)) continue;
    out.add((text: text, status: status));
  }
  return out;
}

/// The todo row's summary: the item in progress, else the first unfinished
/// one, else the last.
String? currentTodo(List<TodoEntry> todos) {
  if (todos.isEmpty) return null;
  return (todos.where((t) => t.status == 'in_progress').firstOrNull ??
          todos.where((t) => t.status != 'completed').firstOrNull ??
          todos.last)
      .text;
}

/// The command of a shell call without ZCode's `bash -lc '…'` wrapper.
String shellCommand(Map<String, dynamic> row) {
  final input = row['input'];
  var command = input is Map && input['command'] is String
      ? input['command'] as String
      : (row['inputText'] as String? ?? '');
  final m = RegExp(r'''^(?:/\S*/)?(?:ba|z)?sh\s+-l?c\s+(['"])([\s\S]*)\1\s*$''').firstMatch(command.trim());
  if (m != null) command = m.group(2)!;
  return command.trim();
}

/// The call's output text: the full output, else its preview.
String toolOutputText(Map<String, dynamic> row) {
  final output = row['output'];
  var text = output is Map ? (output['text'] as String? ?? '') : '';
  final preview = row['outputPreview'];
  if (text.isEmpty && preview is Map) text = '${preview['text'] ?? ''}';
  return text.length > 20000 ? '${text.substring(0, 20000)}\n…' : text;
}

String? toolErrorText(Map<String, dynamic> row) {
  final error = row['error'];
  if (error is! Map) return null;
  return '${error['message'] ?? error['code'] ?? ''}'.trim();
}

const _gap = SizedBox(height: 12);

TextStyle _mono(double size, Color color, {double height = 1.5}) => TextStyle(
      fontFamily: zMonoFamily,
      fontFamilyFallback: zMonoFallback,
      fontSize: size,
      height: height,
      color: color,
    );

/// The expanded body of a tool call, 8 px under its row.
class ToolDetails extends StatelessWidget {
  const ToolDetails({super.key, required this.row, required this.family, this.diff});
  final Map<String, dynamic> row;
  final ToolFamily family;
  final Map<String, dynamic>? diff;

  @override
  Widget build(BuildContext context) {
    final body = switch (family) {
      ToolFamily.shell => ShellDetails(row: row),
      ToolFamily.write when diff != null => DiffView(display: diff!),
      ToolFamily.todo when parseTodos(row).isNotEmpty => TodoDetails(todos: parseTodos(row)),
      _ => GenericDetails(row: row),
    };
    return Padding(padding: const EdgeInsets.only(top: 4, bottom: 8), child: body);
  }
}

/// `$ command` (at most three lines) over the output or error, in one panel
/// card; the output scrolls inside 100 px, as in ZCode.
class ShellDetails extends StatelessWidget {
  const ShellDetails({super.key, required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    final status = row['status'] as String? ?? 'running';
    final running = status == 'running' || status == 'inputStreaming';
    final error = toolErrorText(row);
    final output = error?.isNotEmpty ?? false ? error! : toolOutputText(row).trimRight();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: z.panel,
        borderRadius: BorderRadius.circular(ZRadius.xl),
        border: Border.all(color: z.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(r'$', style: TextStyle(fontSize: ZText.base, height: 1.45, color: z.foregroundSubtle)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(shellCommand(row),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: ZText.base, height: 1.45, color: z.foreground)),
          ),
        ]),
        if (output.isNotEmpty) ...[
          _gap,
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 100),
            child: SingleChildScrollView(
              child: SelectableText(output, style: _mono(ZText.caption, z.foregroundSubtle)),
            ),
          ),
        ] else if (!running) ...[
          _gap,
          Text(s.noOutput, style: _mono(ZText.caption, z.foregroundSubtle)),
        ],
      ]),
    );
  }
}

/// The todo list on a tinted card: done items checked and struck through,
/// the one in progress at full strength, pending ones muted.
class TodoDetails extends StatelessWidget {
  const TodoDetails({super.key, required this.todos});
  final List<TodoEntry> todos;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: z.surface, borderRadius: BorderRadius.circular(ZRadius.xl)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final t in todos)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: switch (t.status) {
                  'completed' => Icon(Icons.check_circle_outline_rounded, size: 14, color: z.success),
                  'in_progress' => Icon(Icons.arrow_forward_rounded, size: 14, color: z.foreground),
                  _ => Icon(Icons.circle_outlined, size: 14, color: z.foregroundSubtlest),
                },
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  t.text,
                  style: TextStyle(
                    fontSize: ZText.base,
                    height: 1.45,
                    color: switch (t.status) {
                      'completed' => z.foregroundSubtlest,
                      'in_progress' => z.foreground,
                      _ => z.foregroundSubtle,
                    },
                    decoration: t.status == 'completed' ? TextDecoration.lineThrough : null,
                    decorationColor: z.foregroundSubtlest,
                  ),
                ),
              ),
            ]),
          ),
      ]),
    );
  }
}

/// MCP / other tools: the result (or error), then "View call details" for
/// the parameters.
class GenericDetails extends StatefulWidget {
  const GenericDetails({super.key, required this.row});
  final Map<String, dynamic> row;

  @override
  State<GenericDetails> createState() => _GenericDetailsState();
}

class _GenericDetailsState extends State<GenericDetails> {
  bool _details = false;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    final row = widget.row;
    final error = toolErrorText(row);
    final output = toolOutputText(row).trim();
    final input = row['input'];
    final params = input is Map && input.isNotEmpty
        ? const JsonEncoder.withIndent('  ').convert(input)
        : (row['inputText'] as String? ?? '').trim();
    final short = output.length <= 160 && !output.contains('\n') && !_looksJson(output);
    return ExpandAnchor(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (error != null && error.isNotEmpty) ...[
        Text(s.result, style: TextStyle(fontSize: ZText.base, fontWeight: FontWeight.w500, color: z.destructive)),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: z.destructive.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(ZRadius.lg),
          ),
          child: SelectableText(error, style: TextStyle(fontSize: ZText.base, color: z.destructive)),
        ),
        _gap,
      ] else if (output.isNotEmpty) ...[
        if (short)
          _Card(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: SelectableText(output, style: TextStyle(fontSize: ZText.base, color: z.foregroundSubtle)),
          )
        else
          _ResultCard(text: output),
        _gap,
      ],
      if (params.isNotEmpty) ...[
        Align(
          alignment: Alignment.centerLeft,
          child: InkWell(
            borderRadius: BorderRadius.circular(ZRadius.md),
            onTap: () => toggleInPlace(context, () => setState(() => _details = !_details)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(s.callDetails,
                    style: TextStyle(fontSize: ZText.base, color: _details ? z.foreground : z.foregroundSubtlest)),
                const SizedBox(width: 2),
                AnimatedRotation(
                  turns: _details ? 0.25 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(Icons.chevron_right_rounded,
                      size: 14, color: _details ? z.foreground : z.foregroundSubtlest),
                ),
              ]),
            ),
          ),
        ),
        if (_details) ...[
          const SizedBox(height: 8),
          Text(s.parameters,
              style: TextStyle(fontSize: ZText.sm, fontWeight: FontWeight.w500, color: z.foregroundSubtlest)),
          const SizedBox(height: 6),
          _Card(
            maxHeight: 288,
            padding: const EdgeInsets.all(12),
            child: SelectableText(params, style: _mono(ZText.sm, z.foreground)),
          ),
        ],
      ],
    ]));
  }

  static bool _looksJson(String text) {
    final t = text.trimLeft();
    return t.startsWith('{') || t.startsWith('[');
  }
}

/// A long result: `Result` with a copy button over the scrolling text.
class _ResultCard extends StatelessWidget {
  const _ResultCard({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    return _Card(
      maxHeight: 288,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
          child: Row(children: [
            Expanded(
              child: Text(s.result,
                  style: TextStyle(fontSize: ZText.base, fontWeight: FontWeight.w500, color: z.foregroundSubtle)),
            ),
            ZIconButton(
              icon: Icons.copy_rounded,
              iconSize: 14,
              size: 30,
              tooltip: s.copyResult,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: text));
                showToast(context, s.copied);
              },
            ),
          ]),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: SelectableText(text, style: _mono(ZText.sm, z.foreground)),
          ),
        ),
      ]),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child, this.padding = EdgeInsets.zero, this.maxHeight});
  final Widget child;
  final EdgeInsets padding;
  final double? maxHeight;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    Widget body = Padding(padding: padding, child: child);
    if (maxHeight != null) {
      body = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight!),
        child: child is Column ? body : SingleChildScrollView(child: body),
      );
    }
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: z.card,
        borderRadius: BorderRadius.circular(ZRadius.xl),
        border: Border.all(color: z.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: body,
    );
  }
}

enum _DiffKind { added, removed, context }

/// ZCode's file diff: no header and no `@@` lines; a numbered gutter, and
/// added / removed lines tinted with a 3 px bar on the left. Scrolls inside
/// 240 px, lines don't wrap.
class DiffView extends StatelessWidget {
  const DiffView({super.key, required this.display});
  final Map<String, dynamic> display;

  /// Long diffs keep their head and tail (ZCode truncates past 800 lines).
  static const maxLines = 800;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    final all = <(String, _DiffKind)>[
      for (final hunk in (display['structuredPatch'] as List? ?? const []).whereType<Map>())
        for (final l in (hunk['lines'] as List? ?? const []))
          switch ('$l') {
            final t when t.startsWith('+') => (t.substring(1), _DiffKind.added),
            final t when t.startsWith('-') => (t.substring(1), _DiffKind.removed),
            final t => (t.startsWith(' ') ? t.substring(1) : t, _DiffKind.context),
          },
    ];
    final omitted = all.length > maxLines ? all.length - maxLines : 0;
    final lines = omitted == 0 ? all : [...all.take(maxLines ~/ 2), ...all.skip(all.length - maxLines ~/ 2)];
    const lineHeight = 12 * 1.625;
    final code = _mono(12, z.foreground, height: 1.625);

    Color? tint(_DiffKind k, double alpha) => switch (k) {
          _DiffKind.added => z.success.withValues(alpha: alpha),
          _DiffKind.removed => z.destructive.withValues(alpha: alpha),
          _DiffKind.context => null,
        };
    Border? bar(_DiffKind k) => k == _DiffKind.context
        ? null
        : Border(left: BorderSide(color: k == _DiffKind.added ? z.success : z.destructive, width: 3));

    final gutter = Container(
      decoration: BoxDecoration(border: Border(right: BorderSide(color: z.border))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (var i = 0; i < lines.length; i++) ...[
          if (omitted > 0 && i == maxLines ~/ 2) const SizedBox(height: lineHeight + 8),
          Container(
            height: lineHeight,
            width: 48,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.centerRight,
            decoration: BoxDecoration(color: tint(lines[i].$2, 0.18), border: bar(lines[i].$2)),
            child: Text('${i + 1}',
                style: _mono(12, tint(lines[i].$2, 1) ?? z.foregroundSubtlest, height: 1.625)
                    .copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
          ),
        ],
      ]),
    );
    final body = LayoutBuilder(
      builder: (context, c) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: c.maxWidth),
          child: IntrinsicWidth(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (var i = 0; i < lines.length; i++) ...[
                if (omitted > 0 && i == maxLines ~/ 2)
                  Container(
                    height: lineHeight + 8,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    alignment: Alignment.centerLeft,
                    child: Text(s.diffPreviewTruncated(omitted),
                        style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtle)),
                  ),
                Container(
                  height: lineHeight,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  alignment: Alignment.centerLeft,
                  color: tint(lines[i].$2, 0.14),
                  child: Text(lines[i].$1, softWrap: false, style: code),
                ),
              ],
            ]),
          ),
        ),
      ),
    );
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 240),
      decoration: BoxDecoration(
        color: z.card,
        borderRadius: BorderRadius.circular(ZRadius.xl),
        border: Border.all(color: z.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [gutter, Expanded(child: body)]),
      ),
    );
  }
}
