import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/v4/conversation_store.dart';
import '../../core/v4/synced_topic.dart';
import '../../state/attachments.dart';
import '../../state/device_session.dart';
import '../../state/model_catalog.dart';
import '../l10n.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import '../widgets/glass.dart';
import '../widgets/tucked_below.dart';
import 'add_context_sheet.dart';
import 'composer.dart';
import 'context_usage.dart';
import 'interaction_panel.dart';
import 'scroll_to_bottom.dart';
import 'status_capsule.dart';
import 'timeline.dart';

/// A task conversation: live timeline, blocking interactions, queue and
/// composer, all driven by one [ConversationStore].
class ConversationView extends StatefulWidget {
  const ConversationView({super.key, required this.device, required this.workspace, required this.sessionId});
  final DeviceSession device;
  final WorkspaceSession workspace;
  final String sessionId;

  @override
  State<ConversationView> createState() => _ConversationViewState();
}

class _ConversationViewState extends State<ConversationView> {
  late ConversationStore _store;

  /// Model / reasoning picked in the composer and not sent yet. Like ZCode's
  /// draft config, it goes out with the next message
  /// (`sendText.modelSelection`) instead of switching the session at once.
  ModelSelection? _draft;

  /// Whether the status capsule is expanded into its panel.
  final ValueNotifier<bool> _statusExpanded = ValueNotifier(false);

  /// Height of the floating dock, the timeline's bottom padding with glass.
  final ValueNotifier<double> _dockHeight = ValueNotifier(0);

  /// Errors the user closed, so they stay closed.
  final Set<String> _dismissedErrors = {};

  static String _errorKey(Map<String, dynamic> e) => '${e['code']}|${e['message']}';

  /// Mode picked in the composer and not sent yet (see [_draft]).
  String? _draftMode;

  ModelSelection get _sessionSelection {
    final c = _store.config;
    return ModelSelection(
        c['provider'] as String? ?? '', c['model'] as String? ?? '', c['thought'] as String?);
  }

  ModelSelection get _selection => _draft ?? _sessionSelection;
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(covariant ConversationView old) {
    super.didUpdateWidget(old);
    if (old.sessionId != widget.sessionId || old.workspace != widget.workspace) _bind();
  }

  void _bind() {
    _store = widget.workspace.conversation(widget.sessionId);
    _draft = null;
    _draftMode = null;
    // Not during build: markRead notifies the sidebar list.
    final tasks = widget.workspace.tasks;
    final id = widget.sessionId;
    WidgetsBinding.instance.addPostFrameCallback((_) => tasks.markRead(id));
  }

  @override
  void dispose() {
    _scroll.dispose();
    _statusExpanded.dispose();
    _dockHeight.dispose();
    super.dispose();
  }

  Future<bool> _send(String text, List<ComposerAttachment> attachments) async {
    final s = S.of(context);
    final routing = _store.inputRouting;
    final refs = [for (final a in attachments) if (a.ref != null) a.ref!];
    final objective = attachments.isEmpty ? goalObjective(text) : null;
    // ZCode ignores a `/goal` without an objective.
    if (objective != null && objective.isEmpty) return false;
    // The message carries the composer's model, reasoning and mode, as in
    // ZCode; that is how a changed selection reaches the session.
    final selection = _selection;
    final modelSelection = selection.modelId.isEmpty ? null : selection.toJson();
    final mode = _draftMode ?? _store.config['mode'] as String? ?? 'build';
    if (objective != null && modelSelection == null) {
      showToast(context, s.noModels);
      return false;
    }
    Future<void> send({String? disposition, List<String>? expected}) {
      if (objective == null) {
        return _store.sendText(text,
            attachments: refs,
            modelSelection: modelSelection,
            mode: mode,
            heldQueueDisposition: disposition,
            expectedHeldQueueItemIds: expected);
      }
      return _store.sendGoal(
        objective,
        displayText: text,
        modelSelection: modelSelection!,
        mode: mode,
        heldQueueDisposition: disposition,
        expectedHeldQueueItemIds: expected,
      );
    }

    try {
      switch (routing['mode']) {
        case 'reject':
          showToast(context, '${routing['reasonCode'] ?? s.error}');
          return false;
        case 'choice':
          final disposition = await _heldQueueChoice();
          if (disposition == null) return false;
          await send(
              disposition: disposition,
              expected: [for (final q in _store.queueItems) '${q['queueItemId']}']);
        default:
          await send();
      }
      if (_scroll.hasClients) {
        _scroll.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
      return true;
    } catch (e) {
      if (mounted) showToast(context, '$e');
      return false;
    }
  }

  Future<String?> _heldQueueChoice() {
    final s = S.of(context);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.heldQueueTitle),
        content: Text(s.heldQueueBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.cancel)),
          TextButton(
              onPressed: () => Navigator.pop(ctx, 'clearQueueAndSend'), child: Text(s.clearQueueAndSend)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, 'keepQueueAndSend'), child: Text(s.keepQueueAndSend)),
        ],
      ),
    );
  }

  Future<void> _guard(Future<void> Function() op) async {
    try {
      await op();
    } catch (e) {
      if (mounted) showToast(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final conversation = ListenableBuilder(
      listenable: Listenable.merge([_store, widget.device]),
      builder: (context, _) => _build(context),
    );
    // Back closes the expanded status panel before it leaves the app.
    return ValueListenableBuilder<bool>(
      valueListenable: _statusExpanded,
      builder: (context, expanded, child) => PopScope(
        canPop: !expanded,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _statusExpanded.value = false;
        },
        child: child!,
      ),
      child: conversation,
    );
  }

  Widget _build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    final store = _store;
    if (!store.hasState) {
      return Center(
        child: store.status == TopicStatus.error
            ? Column(mainAxisSize: MainAxisSize.min, children: [
                Text(store.error ?? s.error, style: TextStyle(color: z.foregroundSubtle)),
                const SizedBox(height: 12),
                OutlinedButton(onPressed: store.refresh, child: Text(s.retry)),
              ])
            : Column(mainAxisSize: MainAxisSize.min, children: [
                const ZSpinner(size: 18),
                const SizedBox(height: 12),
                Text(s.loadingConversation, style: TextStyle(color: z.foregroundSubtle, fontSize: ZText.sm)),
              ]),
      );
    }
    final config = store.config;
    final catalog = widget.device.models;
    // The draft is done once the session reports the same selection.
    final session = _sessionSelection;
    final draft = _draft;
    if (draft != null &&
        draft.providerId == session.providerId &&
        draft.modelId == session.modelId &&
        draft.reasoningLevel == session.reasoningLevel) {
      _draft = null;
    }
    final selection = _selection;
    final sessionMode = config['mode'] as String? ?? 'build';
    if (_draftMode == sessionMode) _draftMode = null;
    final mode = _draftMode ?? sessionMode;
    final option = catalog.find(selection.providerId, selection.modelId);
    final levels = _draft != null && option != null
        ? option.reasoningLevels
        : [for (final l in (config['thoughtLevels'] as List? ?? const [])) '$l'];
    final pending = store.pendingInteractions
        .where((p) => (p['payload'] as Map?)?['kind'] != 'workspaceHookReview')
        .toList();
    final lastError = store.lastError;
    final queue = store.queueItems;
    final offline = !widget.device.status.isOnline;
    final running = [for (final w in store.backgroundWorks) if (w['status'] == 'running') w];

    final banner = offline || store.status == TopicStatus.recovering
        ? _Banner(text: offline ? s.offlineBanner : s.syncing, color: z.warning)
        : null;
    // The button pads its 28 px circle by 6 px: the circle sits 16 px from
    // the right and 8 px above the composer.
    final scrollButton = ScrollToBottomButton(controller: _scroll);
    // ZCode's status capsule, 16 px from the top and right edges.
    final capsule = StatusCapsule(store: store, workspace: widget.workspace, expanded: _statusExpanded);
    final dock = Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: TuckedBelow(
              // The queue tucks 28 px behind the top of what follows it.
              top: queue.isEmpty ? null : _QueueStrip(store: store, queue: queue),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (pending.isNotEmpty) ...[
                InteractionPanel(store: store, interaction: pending.first),
                const SizedBox(height: 8),
              ],
              // ZCode only mentions API retries from the third attempt on.
              if (((store.apiRetry?['attempt'] as num?) ?? 0) >= 3)
                _RetryLine(retry: store.apiRetry!),
              if (lastError != null && !store.running && !_dismissedErrors.contains(_errorKey(lastError)))
                _ErrorCard(
                  error: lastError,
                  onDismiss: () => setState(() => _dismissedErrors.add(_errorKey(lastError))),
                ),
              Composer(
                addContext: AddContextSource(workspace: widget.workspace, sessionId: widget.sessionId),
                hint: store.running ? s.placeholderQueue : s.placeholderFollowUp,
                enabled: !offline,
                running: store.running,
                stopping: store.stopping,
                onStop: store.canStop ? () => _guard(store.stop) : null,
                onSend: _send,
                mode: mode,
                onMode: (m) => setState(() => _draftMode = m),
                model: selection.modelId.isEmpty ? null : selection,
                catalog: catalog,
                onModel: (m) => setState(() =>
                    _draft = ModelSelection(m.providerId, m.modelId, _thoughtFor(m, selection.reasoningLevel))),
                reasoningLevels: levels,
                reasoning: selection.reasoningLevel,
                onReasoning: (l) => setState(() => _draft = selection.withReasoning(l)),
                contextUsage: ContextUsage.fromUsage(store.usage),
                planUsage: widget.device.planUsage,
                backgroundBash: running.where((w) => w['kind'] == 'bash').length,
                backgroundAgents: running.where((w) => w['kind'] != 'bash').length,
                onBackground: () => _statusExpanded.value = true,
              ),
            ]),
            ),
          ),
        ),
    );

    if (!GlassScope.of(context)) {
      return Column(children: [
        if (banner != null) banner,
        Expanded(
          child: Stack(children: [
            Positioned.fill(child: Timeline(store: store, controller: _scroll)),
            Positioned(right: 10, bottom: 2, child: scrollButton),
            Positioned(top: 16, right: 16, child: capsule),
          ]),
        ),
        dock,
      ]);
    }
    // Glass: the timeline runs under the frosted header (its height arrives
    // as the top padding) and under the dock, which floats over it.
    final top = MediaQuery.paddingOf(context).top;
    return ValueListenableBuilder<double>(
      valueListenable: _dockHeight,
      builder: (context, dockHeight, _) => Stack(children: [
        Positioned.fill(
          child: Timeline(store: store, controller: _scroll, topPadding: top, bottomPadding: dockHeight),
        ),
        Positioned(right: 10, bottom: dockHeight + 2, child: scrollButton),
        if (banner != null) Positioned(top: top + 6, left: 12, right: 12, child: banner),
        Positioned(top: top + 16 + (banner == null ? 0 : 36), right: 16, child: capsule),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: ReportSize(onHeight: (h) => _dockHeight.value = h, child: dock),
        ),
      ]),
    );
  }

  String? _thoughtFor(ModelOption m, String? current) {
    if (m.reasoningLevels.isEmpty) return null;
    if (current != null && m.reasoningLevels.contains(current)) return current;
    return m.reasoningLevels.last;
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, required this.color});
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(ZRadius.lg),
      ),
      child: Row(children: [
        StatusDot(color: color, pulse: true, size: 6),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: TextStyle(fontSize: ZText.sm, color: context.z.foreground))),
      ]),
    );
  }
}

/// The queue above the composer (ZCode's `h8e`): a paused notice with
/// Continue, then one row per queued message with Steer / Remove.
class _QueueStrip extends StatelessWidget {
  const _QueueStrip({required this.store, required this.queue});
  final ConversationStore store;
  final List<Map<String, dynamic>> queue;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    final paused = store.queue['autoDrain'] == false;
    final reason = store.queue['pauseReason'];
    void fail(Object e) {
      if (context.mounted) showToast(context, '$e');
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 4 + TuckedBelow.overlap),
      decoration: BoxDecoration(
        color: z.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(ZRadius.x2l)),
        border: Border.all(color: z.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (paused)
          Container(
            constraints: const BoxConstraints(minHeight: 40),
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
            decoration: BoxDecoration(
              color: z.card,
              borderRadius: BorderRadius.circular(ZRadius.xl),
              border: Border.all(color: z.border),
            ),
            child: Row(children: [
              Expanded(
                child: Text(
                  switch (reason) {
                    'stopped' => s.queuePausedStopped,
                    'error' => s.queuePausedError,
                    _ => s.queuePaused,
                  },
                  style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtle),
                ),
              ),
              TextButton(
                onPressed: () => store.setAutoDrain(true).catchError(fail),
                child: Text(s.resume, style: const TextStyle(fontSize: ZText.sm)),
              ),
            ]),
          ),
        for (final item in queue)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Row(children: [
              Expanded(
                child: item['kind'] == 'compact'
                    ? Text('/compact',
                        style: TextStyle(
                            fontFamily: zMonoFamily,
                            fontFamilyFallback: zMonoFallback,
                            fontSize: ZText.sm,
                            color: z.foreground))
                    : Text('${item['text']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: ZText.sm, color: z.foreground)),
              ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 28),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                // Only items still waiting in the queue can be sent now.
                onPressed: item['dispatch'] == null || (item['dispatch'] as Map)['state'] == 'queued'
                    ? () => store.sendQueuedNow('${item['queueItemId']}').catchError(fail)
                    : null,
                icon: const Icon(Icons.upload_rounded, size: 14),
                label: Text(s.sendNow, style: const TextStyle(fontSize: ZText.sm)),
              ),
              ZIconButton(
                icon: Icons.delete_outline_rounded,
                size: 28,
                iconSize: 15,
                tooltip: s.removeQueued,
                onPressed: () => store.deleteQueueItem('${item['queueItemId']}').catchError(fail),
              ),
            ]),
          ),
      ]),
    );
  }
}

/// ZCode's "Reconnecting… n/m" while the model API is retried.
class _RetryLine extends StatelessWidget {
  const _RetryLine({required this.retry});
  final Map<String, dynamic> retry;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final attempt = (retry['attempt'] as num?)?.toInt() ?? 0;
    final max = math.max(((retry['maxAttempts'] as num?)?.toInt() ?? attempt) - 1, attempt);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Row(children: [
        const ZSpinner(size: 11),
        const SizedBox(width: 6),
        Text(S.of(context).apiRetry(attempt, max),
            style: TextStyle(fontSize: ZText.sm, fontWeight: FontWeight.w500, color: z.foregroundSubtle)),
      ]),
    );
  }
}

/// The last error as a card right above the input (ZCode's composer error
/// card): message, details / copy, and a close button.
class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.error, required this.onDismiss});
  final Map<String, dynamic> error;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    final message = '${error['message'] ?? error['code']}';
    final detail = error['detail'] as String?;
    Widget action(String label, VoidCallback onTap) => OutlinedButton(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 28),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          onPressed: onTap,
          child: Text(label, style: const TextStyle(fontSize: ZText.sm)),
        );
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: z.surface,
        borderRadius: BorderRadius.circular(ZRadius.xl),
        border: Border.all(color: z.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(error['code'] == 'fault.runtime.hookBlocked' ? Icons.anchor_rounded : Icons.info_outline_rounded,
              size: 16, color: z.foregroundSubtle),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: ZText.sm, fontWeight: FontWeight.w500, color: z.foreground)),
          ),
          ZIconButton(
              icon: Icons.close_rounded, size: 28, iconSize: 15, tooltip: s.dismissError, onPressed: onDismiss),
        ]),
        const SizedBox(height: 6),
        Wrap(spacing: 6, children: [
          if (detail != null && detail.trim().isNotEmpty)
            action(s.showDetails, () {
              showDialog<void>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text(message),
                  content: SingleChildScrollView(child: SelectableText(detail)),
                  actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(s.cancel))],
                ),
              );
            }),
          action(s.copy, () {
            Clipboard.setData(ClipboardData(text: [message, if (detail != null) detail].join('\n\n')));
            showToast(context, s.copied);
          }),
        ]),
      ]),
    );
  }
}
