import 'package:flutter/material.dart';

import '../../core/rpc/channel_client.dart';
import '../../core/v4/conversation_store.dart';
import '../../state/attachments.dart';
import '../../state/device_session.dart';
import '../../state/model_catalog.dart';
import '../l10n.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import 'add_context_sheet.dart';
import 'composer.dart';

/// Empty state of a workspace: greeting + composer that creates a task
/// (`createSession` with `firstInput`), like ZCode's new-task screen.
class NewTaskView extends StatefulWidget {
  const NewTaskView({super.key, required this.device, required this.workspace, required this.onCreated});
  final DeviceSession device;
  final WorkspaceSession workspace;
  final ValueChanged<String> onCreated;

  @override
  State<NewTaskView> createState() => _NewTaskViewState();
}

class _NewTaskViewState extends State<NewTaskView> {
  String? _mode;
  ModelSelection? _model;

  ModelSelection? _effectiveModel(ModelCatalog catalog) {
    final picked = _model;
    if (picked != null && catalog.find(picked.providerId, picked.modelId) != null) return picked;
    return catalog.preferred;
  }

  /// Plain text goes out with `createSession.firstInput`. Attachments and
  /// goals need the session first: ZCode creates it empty, uploads into it,
  /// then sends the first message.
  Future<bool> _send(String text, List<ComposerAttachment> attachments) async {
    final s = S.of(context);
    final ws = widget.workspace;
    final model = _effectiveModel(widget.device.models);
    final mode = _mode ?? 'build';
    final objective = attachments.isEmpty ? goalObjective(text) : null;
    if (objective != null && objective.isEmpty) return false;
    try {
      if (attachments.isEmpty && objective == null) {
        widget.onCreated(await ws.createTask(text, model: model, mode: _mode));
        return true;
      }
      final id = await ws.createTask(null, model: model, mode: mode);
      final store = ws.conversation(id);
      if (objective != null) {
        if (model == null) throw StateError(s.noModels);
        await store.sendGoal(objective, displayText: text, modelSelection: model.toJson(), mode: mode);
      } else {
        final api = ws.api;
        if (api == null) throw const ConnectionClosedError('offline');
        for (final a in attachments) {
          await a.upload(api, ws.workspace, id);
          if (!a.isReady) throw StateError(a.error ?? a.fileName);
        }
        await store.sendText(text,
            attachments: [for (final a in attachments) a.ref!], modelSelection: model?.toJson(), mode: mode);
      }
      widget.onCreated(id);
      return true;
    } catch (e) {
      if (mounted) showToast(context, '$e');
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(listenable: widget.device, builder: (context, _) => _build(context));
  }

  Widget _build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    final catalog = widget.device.models;
    final model = _effectiveModel(catalog);
    final option = model == null ? null : catalog.find(model.providerId, model.modelId);
    final online = widget.device.status.isOnline;
    return LayoutBuilder(builder: (context, constraints) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight - 32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(
                  s.greeting(DateTime.now().hour),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500, color: z.foreground, height: 1.3),
                ),
                const SizedBox(height: 24),
                Container(
                  decoration: BoxDecoration(
                    color: z.surface,
                    borderRadius: BorderRadius.circular(ZRadius.x2l),
                  ),
                  child: Column(children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      child: Row(children: [
                        Icon(widget.workspace.workspace.isRemote ? Icons.dns_outlined : Icons.folder_outlined,
                            size: 16, color: z.foregroundSubtle),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(widget.workspace.workspace.label,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtle)),
                        ),
                      ]),
                    ),
                    Composer(
                      addContext: AddContextSource(workspace: widget.workspace),
                      hint: s.placeholderNewTask,
                      enabled: online,
                      onSend: _send,
                      mode: _mode ?? 'build',
                      onMode: (m) => setState(() => _mode = m),
                      model: model,
                      catalog: catalog,
                      onModel: (m) => setState(() => _model = ModelSelection(
                            m.providerId,
                            m.modelId,
                            m.reasoningLevels.isEmpty
                                ? null
                                : (m.reasoningLevels.contains(model?.reasoningLevel)
                                    ? model?.reasoningLevel
                                    : m.reasoningLevels.last),
                          )),
                      reasoningLevels: option?.reasoningLevels ?? const [],
                      reasoning: model?.reasoningLevel,
                      onReasoning: model == null
                          ? null
                          : (l) => setState(() => _model = model.withReasoning(l)),
                      planUsage: widget.device.planUsage,
                    ),
                  ]),
                ),
                if (online && catalog.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(s.noModels,
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtle)),
                  ),
              ]),
            ),
          ),
        ),
      );
    });
  }
}
