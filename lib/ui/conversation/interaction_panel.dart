import 'package:flutter/material.dart';

import '../../core/v4/conversation_store.dart';
import '../l10n.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import '../widgets/markdown_view.dart';

/// Blocking interaction above the composer: permission prompts,
/// AskUserQuestion / ExitPlanMode question flows and plain input requests.
/// Answers use the same `resolveInteraction` payloads as ZCode's
/// `V4InteractionDialogs`.
class InteractionPanel extends StatelessWidget {
  const InteractionPanel({super.key, required this.store, required this.interaction});
  final ConversationStore store;
  final Map<String, dynamic> interaction;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final payload = interaction['payload'] as Map<String, dynamic>? ?? const {};
    final id = interaction['interactionId'] as String;
    final Widget body = switch (payload['kind']) {
      'permission' => _PermissionBody(key: ValueKey(id), store: store, id: id, payload: payload),
      'userInput' when (payload['questions'] as List?)?.isNotEmpty ?? false => _QuestionsBody(
          key: ValueKey(id),
          store: store,
          id: id,
          payload: payload,
          autoResolution: interaction['autoResolution'] != null),
      'userInput' => _InputBody(key: ValueKey(id), store: store, id: id, payload: payload),
      _ => Text('${payload['kind']}: open ZCode on the computer to review.',
          style: TextStyle(color: z.foregroundSubtle, fontSize: ZText.sm)),
    };
    return Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.55),
      decoration: BoxDecoration(
        color: z.popover,
        borderRadius: BorderRadius.circular(ZRadius.x2l),
        border: Border.all(color: z.borderHover),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 18)],
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: SingleChildScrollView(child: body),
    );
  }
}

Future<void> _resolve(BuildContext context, ConversationStore store, String id,
    Map<String, Object?> answer) async {
  try {
    await store.resolveInteraction(id, answer);
  } catch (e) {
    if (context.mounted) showToast(context, '$e');
  }
}

Widget _badge(BuildContext context, String text) {
  final z = context.z;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: z.confirmSurface,
      borderRadius: BorderRadius.circular(ZRadius.md),
    ),
    child: Text(text, style: TextStyle(fontSize: ZText.xs, color: z.confirmForeground)),
  );
}

class _PermissionBody extends StatefulWidget {
  const _PermissionBody({super.key, required this.store, required this.id, required this.payload});
  final ConversationStore store;
  final String id;
  final Map<String, dynamic> payload;
  @override
  State<_PermissionBody> createState() => _PermissionBodyState();
}

class _PermissionBodyState extends State<_PermissionBody> {
  final _feedback = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _feedback.dispose();
    super.dispose();
  }

  Future<void> _answer(Map option) async {
    setState(() => _busy = true);
    final fb = _feedback.text.trim();
    await _resolve(context, widget.store, widget.id, {
      'optionId': option['optionId'],
      if (fb.isNotEmpty) 'freeText': fb,
    });
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    final p = widget.payload;
    final options = [
      ...((p['options'] as List?) ?? const []).whereType<Map>(),
      if (p['fullAccessOption'] is Map) p['fullAccessOption'] as Map,
    ];
    final detail = p['detail'];
    String? command;
    if (detail is Map) {
      command = (detail['command'] ?? detail['file_path'] ?? detail['path'])?.toString();
    } else if (detail is String && detail.trim().isNotEmpty) {
      command = detail;
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Icon(Icons.shield_outlined, size: 16, color: z.foregroundSubtle),
        const SizedBox(width: 6),
        Expanded(
          child: Text(s.permissionTitle,
              style: TextStyle(fontSize: ZText.base, fontWeight: FontWeight.w600, color: z.foreground)),
        ),
        _badge(context, '${p['toolName'] ?? ''}'),
      ]),
      const SizedBox(height: 8),
      if ((p['summary'] as String? ?? '').isNotEmpty)
        Text('${p['summary']}',
            style: TextStyle(fontSize: ZText.base, color: z.foreground, height: 1.5)),
      if (command != null) ...[
        const SizedBox(height: 8),
        CodeBlock(code: command, maxHeight: 160),
      ],
      if (p['freeText'] == true) ...[
        const SizedBox(height: 8),
        TextField(
          controller: _feedback,
          minLines: 1,
          maxLines: 3,
          decoration: InputDecoration(hintText: s.feedbackPlaceholder),
        ),
      ],
      const SizedBox(height: 10),
      for (final o in options)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: _optionButton(context, o),
        ),
    ]);
  }

  Widget _optionButton(BuildContext context, Map o) {
    final kind = o['kind'];
    final label = '${o['label'] ?? o['optionId']}';
    final onPressed = _busy ? null : () => _answer(o);
    if (kind == 'allowOnce') {
      return FilledButton(onPressed: onPressed, child: Text(label));
    }
    if (kind == 'deny') {
      return TextButton(
        onPressed: onPressed,
        child: Text(label, style: TextStyle(color: context.z.destructive)),
      );
    }
    return OutlinedButton(onPressed: onPressed, child: Text(label, textAlign: TextAlign.center));
  }
}

/// AskUserQuestion / plan approval: one question at a time.
class _QuestionsBody extends StatefulWidget {
  const _QuestionsBody({
    super.key,
    required this.store,
    required this.id,
    required this.payload,
    required this.autoResolution,
  });
  final ConversationStore store;
  final String id;
  final Map<String, dynamic> payload;
  final bool autoResolution;
  @override
  State<_QuestionsBody> createState() => _QuestionsBodyState();
}

class _QuestionsBodyState extends State<_QuestionsBody> {
  int _index = 0;
  final Map<int, Set<String>> _selected = {};
  final Map<int, TextEditingController> _custom = {};
  bool _snoozed = false;
  bool _busy = false;

  List<Map> get _questions => ((widget.payload['questions'] as List?) ?? const []).whereType<Map>().toList();

  @override
  void dispose() {
    for (final c in _custom.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _touched() {
    // First interaction pauses AskUserQuestion's automatic resolution.
    if (widget.autoResolution && !_snoozed) {
      _snoozed = true;
      widget.store.snoozeAutoResolution(widget.id).catchError((_) {});
    }
  }

  List<String> _answers(int i) {
    final custom = _custom[i]?.text.trim() ?? '';
    return [...?_selected[i], if (custom.isNotEmpty) custom];
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    final qs = _questions;
    final answers = <String, Object?>{};
    final content = <String, Object?>{'answers': answers};
    for (var i = 0; i < qs.length; i++) {
      final a = _answers(i);
      if (a.isEmpty) continue;
      answers['${qs[i]['question']}'] = a.join(', ');
      content['answer_$i'] = qs[i]['multiSelect'] == true ? a : a.first;
    }
    if (qs.length == 1) {
      final a = _answers(0);
      if (a.isNotEmpty) content['answer'] = qs[0]['multiSelect'] == true ? a : a.first;
    }
    await _resolve(context, widget.store, widget.id, {'action': 'accept', 'content': content});
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    final qs = _questions;
    if (qs.isEmpty) return const SizedBox.shrink();
    final q = qs[_index.clamp(0, qs.length - 1)];
    final multi = q['multiSelect'] == true;
    final selected = _selected.putIfAbsent(_index, () => {});
    final custom = _custom.putIfAbsent(_index, () => TextEditingController());
    final last = _index >= qs.length - 1;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Icon(Icons.help_outline_rounded, size: 16, color: z.foregroundSubtle),
        const SizedBox(width: 6),
        Expanded(
          child: Text('${q['header'] ?? s.questionTitle}',
              style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtle)),
        ),
        if (qs.length > 1)
          Text('${_index + 1}/${qs.length}',
              style: TextStyle(fontSize: ZText.xs, color: z.foregroundSubtlest)),
      ]),
      const SizedBox(height: 8),
      MarkdownView('${q['question'] ?? ''}', dense: true),
      const SizedBox(height: 8),
      for (final o in ((q['options'] as List?) ?? const []).whereType<Map>())
        Builder(builder: (context) {
          final value = '${o['value'] ?? o['label']}';
          final isOn = selected.contains(value);
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: InkWell(
              borderRadius: BorderRadius.circular(ZRadius.lg),
              onTap: () {
                _touched();
                setState(() {
                  if (multi) {
                    isOn ? selected.remove(value) : selected.add(value);
                  } else {
                    selected
                      ..clear()
                      ..add(value);
                  }
                });
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: isOn ? z.selected : z.surface,
                  borderRadius: BorderRadius.circular(ZRadius.lg),
                  border: Border.all(color: isOn ? z.borderHover : z.border),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(
                    multi
                        ? (isOn ? Icons.check_box : Icons.check_box_outline_blank)
                        : (isOn ? Icons.radio_button_checked : Icons.radio_button_off),
                    size: 16,
                    color: isOn ? z.foreground : z.foregroundSubtlest,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${o['label']}', style: TextStyle(fontSize: ZText.base, color: z.foreground)),
                      if ((o['description'] as String?)?.isNotEmpty ?? false)
                        Text('${o['description']}',
                            style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtle)),
                    ]),
                  ),
                ]),
              ),
            ),
          );
        }),
      TextField(
        controller: custom,
        onChanged: (_) => _touched(),
        minLines: 1,
        maxLines: 3,
        decoration: InputDecoration(hintText: s.customAnswer),
      ),
      const SizedBox(height: 10),
      Row(children: [
        TextButton(
          onPressed: _busy
              ? null
              : () => _resolve(context, widget.store, widget.id, {'action': 'decline'}),
          child: Text(s.decline, style: TextStyle(color: z.foregroundSubtle)),
        ),
        const Spacer(),
        if (_index > 0)
          TextButton(onPressed: () => setState(() => _index--), child: const Icon(Icons.arrow_back, size: 16)),
        FilledButton(
          onPressed: _busy
              ? null
              : () {
                  _touched();
                  if (last) {
                    _submit();
                  } else {
                    setState(() => _index++);
                  }
                },
          child: Text(last ? s.submit : s.next),
        ),
      ]),
    ]);
  }
}

class _InputBody extends StatefulWidget {
  const _InputBody({super.key, required this.store, required this.id, required this.payload});
  final ConversationStore store;
  final String id;
  final Map<String, dynamic> payload;
  @override
  State<_InputBody> createState() => _InputBodyState();
}

class _InputBodyState extends State<_InputBody> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    final p = widget.payload;
    final options = ((p['options'] as List?) ?? const []).whereType<Map>();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(s.questionTitle, style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtle)),
      const SizedBox(height: 6),
      MarkdownView('${p['prompt'] ?? ''}', dense: true),
      const SizedBox(height: 8),
      for (final o in options)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: OutlinedButton(
            onPressed: () => _resolve(context, widget.store, widget.id, {'optionId': o['optionId']}),
            child: Text('${o['label']}'),
          ),
        ),
      if (p['freeText'] == true) ...[
        TextField(
          controller: _text,
          obscureText: p['sensitive'] == true,
          minLines: 1,
          maxLines: p['sensitive'] == true ? 1 : 4,
          decoration: InputDecoration(hintText: s.customAnswer),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            onPressed: () => _resolve(context, widget.store, widget.id, {'freeText': _text.text}),
            child: Text(s.submit),
          ),
        ),
      ],
    ]);
  }
}
