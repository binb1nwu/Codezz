import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/app_state.dart';
import '../../state/attachments.dart';
import '../../state/model_catalog.dart';
import '../../state/plan_usage.dart';
import '../l10n.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import '../widgets/glass.dart';
import 'add_context_sheet.dart';
import 'attachment_chip.dart';
import 'context_usage.dart';
import 'plan_usage_section.dart';

const composerModes = ['build', 'edit', 'plan', 'yolo'];

IconData modeIcon(String mode) => switch (mode) {
      'build' => Icons.pan_tool_alt_outlined,
      'edit' => Icons.edit_outlined,
      'plan' => Icons.checklist_rounded,
      'yolo' => Icons.bolt_rounded,
      _ => Icons.tune_rounded,
    };

/// Main chat input shell (`rounded-2xl`, the approved exception in DESIGN.md)
/// with ZCode's toolbar: mode · model · reasoning · context · send/stop.
///
/// Mode and reasoning are icon controls (the reasoning level as a strength
/// meter); the model is the only control that shows text, and only its short
/// name (`GLM-5.3-Flash`), never the provider.
class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.hint,
    required this.onSend,
    this.addContext,
    this.enabled = true,
    this.running = false,
    this.stopping = false,
    this.onStop,
    this.mode,
    this.onMode,
    this.model,
    this.catalog,
    this.onModel,
    this.reasoningLevels = const [],
    this.reasoning,
    this.onReasoning,
    this.contextUsage,
    this.planUsage,
    this.backgroundBash = 0,
    this.backgroundAgents = 0,
    this.onBackground,
    this.autofocus = false,
  });

  final String hint;

  /// Returns true when the message was accepted (the field and the
  /// attachments are then cleared). Attachments are already uploaded when
  /// the composer knows the session, otherwise the callback uploads them.
  final Future<bool> Function(String text, List<ComposerAttachment> attachments) onSend;

  /// Enables the "+" (add context) menu.
  final AddContextSource? addContext;
  final bool enabled;
  final bool running;
  final bool stopping;
  final VoidCallback? onStop;
  final String? mode;
  final ValueChanged<String>? onMode;

  /// The selected model.
  final ModelSelection? model;
  final ModelCatalog? catalog;
  final ValueChanged<ModelOption>? onModel;
  final List<String> reasoningLevels;
  final String? reasoning;
  final ValueChanged<String>? onReasoning;

  /// The conversation's context window; the ring is hidden while null.
  final ContextUsage? contextUsage;

  /// Coding-plan quota, shown in the usage card for plan providers.
  final PlanUsageStore? planUsage;

  /// Running background terminals / agents; the toolbar shows their count
  /// and [onBackground] opens the status panel.
  final int backgroundBash;
  final int backgroundAgents;
  final VoidCallback? onBackground;
  final bool autofocus;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();
  bool _sending = false;

  /// Feeds an open context sheet so it follows the live usage.
  late final ValueNotifier<ContextUsage?> _usage = ValueNotifier(widget.contextUsage);

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
  }

  @override
  void didUpdateWidget(covariant Composer old) {
    super.didUpdateWidget(old);
    if (widget.contextUsage == _usage.value) return;
    // Not during build: the listener lives in the sheet route.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _usage.value = widget.contextUsage;
    });
  }

  @override
  void dispose() {
    for (final a in _attachments) {
      a.cancel();
    }
    _text.dispose();
    _focus.dispose();
    _usage.dispose();
    super.dispose();
  }

  final List<ComposerAttachment> _attachments = [];

  /// Text or attachments to send, with no attachment unreadable or still
  /// uploading. Uploads that have not run yet (the connection was down when
  /// the file was picked) run on send.
  bool get _canSend {
    if (_text.text.trim().isEmpty && _attachments.isEmpty) return false;
    return _attachments.every((a) =>
        a.isReady ||
        (a.content != null &&
            a.problem != AttachmentProblem.unreadable &&
            a.status != AttachmentStatus.uploading &&
            a.status != AttachmentStatus.committing));
  }

  Future<void> _send() async {
    final text = _text.text.trim();
    if (!_canSend || _sending || !widget.enabled) return;
    setState(() => _sending = true);
    try {
      final source = widget.addContext;
      final session = source?.sessionId;
      final api = source?.workspace.api;
      if (source != null && session != null) {
        for (final a in _attachments.where((a) => !a.isReady)) {
          if (api == null) return;
          await a.upload(api, source.workspace.workspace, session);
          if (!a.isReady) {
            if (mounted) showToast(context, S.of(context).uploadFailed(a.error ?? a.fileName));
            return;
          }
        }
      }
      if (await widget.onSend(text, List.of(_attachments))) {
        _text.clear();
        setState(_attachments.clear);
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  bool _planFetchScheduled = false;

  /// Keeps the ring's quota reasonably fresh (at most every five minutes);
  /// opening the card still refreshes after a minute, as in ZCode.
  void _fetchPlanForRing(String providerId) {
    if (_planFetchScheduled) return;
    _planFetchScheduled = true;
    // Not during build: fetching notifies the store's listeners.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _planFetchScheduled = false;
      if (mounted) widget.planUsage?.access(providerId, maxAge: const Duration(minutes: 5));
    });
  }

  void _openAddContext() {
    final source = widget.addContext;
    if (source == null) return;
    showAddContext(
      context,
      source: source,
      allowGoal: source.sessionId == null && _text.text.isEmpty,
      onAttach: _pickFiles,
      onGoal: () => _insert('/goal ', atStart: true),
      onInsert: (markdown) => _insert('$markdown '),
    );
  }

  /// Inserts at the caret (or the start), keeping the field focused.
  void _insert(String text, {bool atStart = false}) {
    final value = _text.value;
    final sel = value.selection;
    final at = atStart ? 0 : (sel.isValid ? sel.start : value.text.length);
    final end = atStart ? 0 : (sel.isValid ? sel.end : value.text.length);
    final next = value.text.replaceRange(at, end, text);
    _text.value = TextEditingValue(text: next, selection: TextSelection.collapsed(offset: at + text.length));
    _focus.requestFocus();
  }

  Future<void> _pickFiles() async {
    final s = S.of(context);
    List<PlatformFile> files;
    try {
      files = await FilePicker.pickFiles();
    } catch (e) {
      if (mounted) showToast(context, s.readFailed('$e'));
      return;
    }
    if (files.isEmpty || !mounted) return;
    final room = AttachmentLimits.maxFiles - _attachments.length;
    if (files.length > room) {
      showToast(context, s.maxAttachments(AttachmentLimits.maxFiles));
      files = files.take(room < 0 ? 0 : room).toList();
    }
    for (final f in files) {
      // Oversized files are refused before they are read into memory.
      if ((f.lengthSync() ?? 0) > AttachmentLimits.maxInlineBytes && attachmentIsInline(f.name)) {
        showToast(context, s.attachmentTooLarge(f.name));
        continue;
      }
      final Uint8List bytes;
      try {
        bytes = await f.readAsBytes();
      } catch (e) {
        if (mounted) showToast(context, s.readFailed('${f.name}: $e'));
        continue;
      }
      if (!mounted) return;
      final a = ComposerAttachment.fromFile(f.name, bytes, truncatedNote: s.truncatedNote);
      if (a.problem == AttachmentProblem.tooLarge) {
        showToast(context, s.attachmentTooLarge(f.name));
        continue;
      }
      a.addListener(() {
        if (mounted) setState(() {});
      });
      setState(() => _attachments.add(a));
      _upload(a);
    }
  }

  /// Uploads right away when the session exists (ZCode's `waitingSession`
  /// otherwise).
  void _upload(ComposerAttachment a) {
    final source = widget.addContext;
    final api = source?.workspace.api;
    final session = source?.sessionId;
    if (source == null || api == null || session == null) return;
    a.upload(api, source.workspace.workspace, session);
  }

  void _removeAttachment(ComposerAttachment a) {
    a.cancel();
    setState(() => _attachments.remove(a));
  }

  void _pickMode() {
    final s = S.of(context);
    showZSheet<void>(context, title: s.modeLabel(widget.mode ?? 'build'), builder: (ctx) {
      return ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
        for (final m in composerModes)
          ZMenuItem(
            icon: modeIcon(m),
            title: s.modeLabel(m),
            subtitle: s.modeDescription(m),
            selected: m == widget.mode,
            onTap: () {
              Navigator.pop(ctx);
              widget.onMode?.call(m);
            },
          ),
      ]);
    });
  }

  void _pickModel() {
    final catalog = widget.catalog;
    if (catalog == null) return;
    final s = S.of(context);
    final current = widget.model;
    showZSheet<void>(context, title: s.model, builder: (ctx) {
      if (catalog.isEmpty) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Text(s.noModels, style: TextStyle(color: ctx.z.foregroundSubtle)),
        );
      }
      return ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
        for (final p in catalog.providers) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Text(p.name, style: TextStyle(fontSize: ZText.xs, color: ctx.z.foregroundSubtlest)),
          ),
          for (final m in p.models)
            ZMenuItem(
              title: m.displayName,
              subtitle: m.displayName == m.modelId ? null : m.modelId,
              selected: current != null && current.providerId == m.providerId && current.modelId == m.modelId,
              onTap: () {
                Navigator.pop(ctx);
                widget.onModel?.call(m);
              },
            ),
        ],
      ]);
    });
  }

  /// Opens the reasoning slider in a sheet, like the mode and model pickers.
  /// Each level the slider settles on is applied at once.
  void _pickReasoning(String current) {
    final s = S.of(context);
    showZSheet<void>(context, title: s.reasoning, builder: (ctx) {
      return ReasoningSlider(
        levels: widget.reasoningLevels,
        value: current,
        onChanged: (l) => widget.onReasoning?.call(l),
      );
    });
  }

  /// Short model name; falls back to the id without its provider prefix.
  String _modelLabel(S s) {
    final m = widget.model;
    if (m == null || m.modelId.isEmpty) return s.modelShort;
    final option = widget.catalog?.find(m.providerId, m.modelId);
    return option?.displayName ?? shortModelName(m.modelId);
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    final hasText = _text.text.trim().isNotEmpty;
    final showStop = widget.running && !hasText && widget.onStop != null;
    final mode = widget.mode ?? 'build';
    final levels = widget.reasoningLevels;
    final reasoning = widget.reasoning ?? (levels.isEmpty ? null : levels.last);
    final muted = widget.enabled ? z.foregroundSubtle : z.foregroundSubtlest;
    final providerId = widget.model?.providerId;
    final planProvider =
        widget.planUsage != null && providerId != null && planAccountAccess(providerId) != null ? providerId : null;
    if (planProvider != null) _fetchPlanForRing(planProvider);
    if (widget.planUsage != null && widget.planUsage!.shown != planProvider) {
      // Not during build: the header listens to the store.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.planUsage!.shown = planProvider;
      });
    }
    final asBar = ContextDisplayScope.of(context) == ContextDisplay.bar;
    // The quotas join the context ring unless the header shows them.
    final ringPlan = ContextDisplayScope.quotasOf(context) == QuotaPlacement.ring ? planProvider : null;
    final barRatio = asBar ? (widget.contextUsage?.ratio ?? 0).clamp(0.0, 1.0) : 0.0;
    final glass = GlassScope.of(context);
    final card = glassColor(context, z.card);
    // The whole input box can double as the context bar, filled from the left.
    return TweenAnimationBuilder<double>(
      tween: Tween(end: barRatio),
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutCubic,
      builder: (context, ratio, child) => Glass(
        borderRadius: BorderRadius.circular(ZRadius.x2l),
        child: Container(
          decoration: BoxDecoration(
            color: ratio > 0 ? null : card,
            gradient: ratio > 0 ? contextBarGradient(z, ratio, base: card) : null,
            borderRadius: BorderRadius.circular(ZRadius.x2l),
            border: Border.all(color: z.border),
            // A shadow would show through the frosted card.
            boxShadow: glass
                ? null
                : [
                    BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 16, offset: const Offset(0, 4)),
                  ],
          ),
          child: child,
        ),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (_attachments.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                for (final a in _attachments)
                  AttachmentChip(
                    attachment: a,
                    onRemove: () => _removeAttachment(a),
                    onRetry: widget.addContext?.sessionId == null ? null : () => _upload(a),
                  ),
              ]),
            ),
          ),
        CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.enter, control: true): _send,
            const SingleActivator(LogicalKeyboardKey.enter, meta: true): _send,
          },
          child: TextField(
            controller: _text,
            focusNode: _focus,
            autofocus: widget.autofocus,
            enabled: widget.enabled,
            minLines: 1,
            maxLines: 8,
            textInputAction: TextInputAction.newline,
            keyboardType: TextInputType.multiline,
            style: TextStyle(fontSize: 16, height: 1.45, color: z.foreground),
            decoration: InputDecoration(
              hintText: widget.hint,
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              contentPadding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 8, 8),
          child: Row(children: [
            if (widget.addContext != null)
              _ToolbarButton(
                tooltip: s.addContext,
                onTap: widget.enabled ? _openAddContext : null,
                child: Icon(Icons.add_rounded, size: 20, color: muted),
              ),
            if (widget.onMode != null)
              _ToolbarButton(
                tooltip: s.modeLabel(mode),
                onTap: widget.enabled ? _pickMode : null,
                child: Icon(modeIcon(mode), size: 19, color: mode == 'yolo' ? z.warning : muted),
              ),
            if (widget.backgroundBash + widget.backgroundAgents > 0 && widget.onBackground != null)
              _ToolbarButton(
                tooltip: widget.backgroundAgents == 0
                    ? s.openRunningTerminals
                    : widget.backgroundBash == 0
                        ? s.openRunningAgents
                        : s.openRunningBoth,
                onTap: widget.onBackground,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.monitor_heart_outlined, size: 17, color: muted),
                  const SizedBox(width: 3),
                  Text('${widget.backgroundBash + widget.backgroundAgents}',
                      style: TextStyle(
                          fontSize: ZText.sm, color: muted, fontFeatures: const [FontFeature.tabularFigures()])),
                ]),
              ),
            Expanded(
              child: widget.onModel == null
                  ? const SizedBox.shrink()
                  : Align(
                      alignment: Alignment.centerRight,
                      child: _ToolbarButton(
                        tooltip: s.model,
                        onTap: widget.enabled ? _pickModel : null,
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Flexible(
                            child: Text(
                              _modelLabel(s),
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: ZText.sm,
                                fontWeight: FontWeight.w600,
                                color: widget.enabled ? z.foreground : z.foregroundSubtlest,
                              ),
                            ),
                          ),
                          Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: muted),
                        ]),
                      ),
                    ),
            ),
            if (widget.onReasoning != null && reasoning != null)
              _ToolbarButton(
                tooltip: '${s.reasoning} · ${s.reasoningLevel(reasoning)}',
                onTap: widget.enabled ? () => _pickReasoning(reasoning) : null,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: ThoughtMeter(ratio: thoughtRatio(reasoning, levels), enabled: widget.enabled),
              ),
            if ((widget.contextUsage != null && !asBar) || ringPlan != null)
              ListenableBuilder(
                listenable: widget.planUsage ?? _usage,
                builder: (context, _) {
                  final snapshot = ringPlan == null ? null : widget.planUsage!.entry(ringPlan)?.snapshot;
                  // Outermost first: weekly, 5-hour (or today's balance).
                  final quotas = [
                    snapshot?.quotas.where((q) => q.key == 'weekly').firstOrNull,
                    snapshot?.ringQuota,
                  ].whereType<PlanQuota>().toList();
                  final usage = widget.contextUsage;
                  // The input box already shows the context: no ring left.
                  if (asBar && quotas.isEmpty) return const SizedBox.shrink();
                  return _ToolbarButton(
                    tooltip: [
                      switch (usage) {
                        final u? => s.contextUsage(groupedCount(u.used), groupedCount(u.size)),
                        null => s.planTitle,
                      },
                      for (final q in quotas) '${s.planQuota(q.key)} ${quotaPercentText(q.remaining)}',
                    ].join('\n'),
                    onTap: () => showContextUsage(
                      context,
                      _usage,
                      plans: widget.planUsage,
                      planProvider: planProvider,
                    ),
                    // With a coding plan every ring shows what is left, so
                    // arcs shrink as they are used up. When the input box is
                    // the context bar, only the quotas stay as rings.
                    child: ringPlan == null
                        ? ContextRing(ratio: usage?.ratio ?? 0, color: muted)
                        : ContextRing.concentric(
                            size: quotas.length > 1 ? 22 : 20,
                            rings: [
                              for (final q in quotas)
                                RingValue((q.remaining ?? 0) / 100,
                                    quotaColor(z, q.key == 'weekly' ? 'weekly' : 'fiveHour')),
                              if (!asBar) RingValue(usage == null ? 1 : 1 - usage.ratio, muted),
                            ],
                          ),
                  );
                },
              ),
            const SizedBox(width: 4),
            if (showStop)
              ZIconButton(
                icon: widget.stopping ? Icons.hourglass_top_rounded : Icons.stop_rounded,
                filled: true,
                tooltip: s.stop,
                onPressed: widget.stopping ? null : widget.onStop,
              )
            else
              ZIconButton(
                icon: Icons.arrow_upward_rounded,
                filled: true,
                tooltip: s.send,
                onPressed: _canSend && widget.enabled && !_sending ? _send : null,
              ),
          ]),
        ),
      ]),
    );
  }
}

/// Card background filled up to [ratio] of its width with the used context,
/// turning to the warning colour once the window is nearly full.
LinearGradient contextBarGradient(ZTokens z, double ratio, {Color? base}) {
  final card = base ?? z.card;
  final tint = ratio >= 0.9 ? z.warning.withValues(alpha: 0.16) : z.foreground.withValues(alpha: 0.07);
  final fill = Color.alphaBlend(tint, card);
  return LinearGradient(colors: [fill, fill, card, card], stops: [0, ratio, ratio, 1]);
}

/// `provider/model` → `model`.
String shortModelName(String value) {
  final i = value.lastIndexOf('/');
  return i >= 0 && i < value.length - 1 ? value.substring(i + 1) : value;
}

/// Fill of the reasoning meter. Known levels keep a fixed strength (low is
/// always one bar, high three), whatever else the model offers; unknown
/// names fall back to their position among the levels that reason.
double thoughtRatio(String level, List<String> levels) {
  const off = {'disabled', 'none', 'off'};
  if (off.contains(level)) return 0;
  switch (level) {
    case 'minimal' || 'low':
      return 0.25;
    case 'medium':
      return 0.5;
    case 'high':
      return 0.75;
    case 'xhigh' || 'max' || 'enabled':
      return 1;
  }
  final on = levels.where((l) => !off.contains(l)).toList();
  final i = on.indexOf(level);
  return i >= 0 ? (i + 1) / on.length : 1;
}

/// Reasoning strength as a small vertical green bar, filled from the
/// bottom (a stub when reasoning is off).
class ThoughtMeter extends StatelessWidget {
  const ThoughtMeter({super.key, required this.ratio, this.enabled = true});
  final double ratio;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return SizedBox(
      width: 5,
      height: 18,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2.5),
        child: Stack(children: [
          Positioned.fill(child: ColoredBox(color: z.border)),
          // widthFactor keeps the fill from collapsing under Align's loose
          // constraints.
          Align(
            alignment: Alignment.bottomCenter,
            child: FractionallySizedBox(
              widthFactor: 1,
              heightFactor: ratio <= 0 ? 0.08 : ratio.clamp(0.0, 1.0),
              child: ColoredBox(color: enabled ? z.success : z.foregroundSubtlest),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Stepped horizontal slider over the model's reasoning levels, with the
/// level names under the stops. Reports a level when the thumb settles.
class ReasoningSlider extends StatefulWidget {
  const ReasoningSlider({super.key, required this.levels, required this.value, required this.onChanged});
  final List<String> levels;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<ReasoningSlider> createState() => _ReasoningSliderState();
}

class _ReasoningSliderState extends State<ReasoningSlider> {
  late int _index = math.max(0, widget.levels.indexOf(widget.value));

  static const _inset = 12.0;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    final levels = widget.levels;
    final last = levels.length - 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (last == 0)
          Text(s.reasoningLevel(levels.single),
              style: TextStyle(fontSize: ZText.base, fontWeight: FontWeight.w600, color: z.foreground)),
        if (last > 0) ...[
          SliderTheme(
            data: SliderThemeData(
              trackHeight: 4,
              activeTrackColor: z.success,
              inactiveTrackColor: z.border,
              thumbColor: z.success,
              overlayColor: z.success.withValues(alpha: 0.12),
              activeTickMarkColor: z.primaryForeground.withValues(alpha: 0.6),
              inactiveTickMarkColor: z.foregroundSubtlest,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              padding: const EdgeInsets.symmetric(horizontal: _inset),
              showValueIndicator: ShowValueIndicator.never,
            ),
            child: Slider(
              value: _index.toDouble(),
              max: last.toDouble(),
              divisions: last,
              onChanged: (v) => setState(() => _index = v.round()),
              onChangeEnd: (v) => widget.onChanged(levels[v.round()]),
            ),
          ),
          // Level names centred under their stops.
          LayoutBuilder(builder: (context, c) {
            final track = c.maxWidth - _inset * 2;
            return SizedBox(
              height: 24,
              child: Stack(clipBehavior: Clip.none, children: [
                for (var i = 0; i <= last; i++)
                  Positioned(
                    left: _inset + track * i / last - 40,
                    width: 80,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        setState(() => _index = i);
                        widget.onChanged(levels[i]);
                      },
                      child: Text(
                        s.reasoningLevel(levels[i]),
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: ZText.sm,
                          fontWeight: i == _index ? FontWeight.w600 : null,
                          color: i == _index ? z.foreground : z.foregroundSubtle,
                        ),
                      ),
                    ),
                  ),
              ]),
            );
          }),
        ],
      ]),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    required this.child,
    required this.tooltip,
    this.onTap,
    this.padding = const EdgeInsets.all(8),
  });

  final Widget child;
  final String tooltip;
  final VoidCallback? onTap;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(ZRadius.lg),
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      );
}
