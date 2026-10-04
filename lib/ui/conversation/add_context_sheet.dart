import 'package:flutter/material.dart';

import '../../state/device_session.dart';
import '../../state/task_list_store.dart';
import '../l10n.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';

/// Where the composer's "+" menu gets its context from.
class AddContextSource {
  const AddContextSource({required this.workspace, this.sessionId});
  final WorkspaceSession workspace;

  /// Null on the new-task screen (the session does not exist yet).
  final String? sessionId;
}

/// `\`, `[`, `]` and `>` are escaped in mention labels and targets.
String _escape(String s) => s.replaceAllMapped(RegExp(r'[\\\[\]>]'), (m) => '\\${m[0]}');

/// `[name](./rel/path)`; directories keep a trailing `/`.
String fileMention(Map<String, dynamic> f) {
  final dir = f['type'] == 'directory';
  var rel = '${f['relativePath'] ?? f['path'] ?? ''}'.replaceAll('\\', '/');
  if (dir && !rel.endsWith('/')) rel = '$rel/';
  final absolute = RegExp(r'^(/|\./|\.\./|#|[a-zA-Z][a-zA-Z0-9+.-]*:)').hasMatch(rel);
  final name = '${f['name'] ?? rel}${dir ? '/' : ''}';
  return '[${_escape(name)}](${absolute ? '' : './'}${_escape(rel)})';
}

/// `[#Title](#sessionId)`, or `#sessionId` without a title.
String sessionMention(String sessionId, String title) {
  final t = title.replaceFirst(RegExp(r'^#sess_\S*\s*'), '').trim();
  return t.isEmpty ? '#$sessionId' : '[#${_escape(t)}](#$sessionId)';
}

/// `[@name](plugin://pluginId)`.
String pluginMention(Map<String, dynamic> p) =>
    '[@${_escape('${p['displayName'] ?? p['name']}')}](plugin://${p['pluginId']})';

/// ZCode's "Add context" menu: Attachments and Goal, then plugins, files
/// and sessions of the workspace to mention in the message.
Future<void> showAddContext(
  BuildContext context, {
  required AddContextSource source,
  required bool allowGoal,
  required VoidCallback onAttach,
  required VoidCallback onGoal,
  required ValueChanged<String> onInsert,
}) {
  final s = S.of(context);
  return showZSheet<void>(context, title: s.addContext, builder: (ctx) {
    void pick(VoidCallback action) {
      Navigator.pop(ctx);
      action();
    }

    return _AddContextList(
      source: source,
      allowGoal: allowGoal,
      onAttach: () => pick(onAttach),
      onGoal: () => pick(onGoal),
      onInsert: (text) => pick(() => onInsert(text)),
    );
  });
}

class _AddContextList extends StatefulWidget {
  const _AddContextList({
    required this.source,
    required this.allowGoal,
    required this.onAttach,
    required this.onGoal,
    required this.onInsert,
  });

  final AddContextSource source;
  final bool allowGoal;
  final VoidCallback onAttach;
  final VoidCallback onGoal;
  final ValueChanged<String> onInsert;

  @override
  State<_AddContextList> createState() => _AddContextListState();
}

class _AddContextListState extends State<_AddContextList> {
  late final Future<List<Map<String, dynamic>>> _plugins = _loadPlugins();
  late final Future<List<Map<String, dynamic>>> _files = _loadFiles();

  WorkspaceSession get ws => widget.source.workspace;

  Future<List<Map<String, dynamic>>> _loadPlugins() async {
    final api = ws.api;
    if (api == null) return const [];
    final res = await api.pluginReferenceCatalog(ws.workspace, sessionId: widget.source.sessionId);
    return [
      for (final p in res['plugins'] is List ? res['plugins'] as List : const [])
        if (p is Map && p['enabled'] == true) Map<String, dynamic>.from(p),
    ];
  }

  /// The first ten entries, files before directories.
  Future<List<Map<String, dynamic>>> _loadFiles() async {
    final api = ws.api;
    if (api == null) return const [];
    final all = await api.listWorkspaceFiles(ws.workspace);
    final files = all.where((f) => f['type'] != 'directory');
    final dirs = all.where((f) => f['type'] == 'directory');
    return [...files, ...dirs].take(10).toList();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final sessions = ws.tasks
        .items(TaskListKind.active)
        .where((t) => t.taskId != widget.source.sessionId)
        .toList();
    return ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
      _Header(s.addSection),
      ZMenuItem(icon: Icons.attach_file_rounded, title: s.attachment, onTap: widget.onAttach),
      if (widget.allowGoal) ZMenuItem(icon: Icons.flag_outlined, title: s.goal, onTap: widget.onGoal),
      _Header(s.plugins),
      _Async(
        future: _plugins,
        empty: s.pluginsEmpty,
        itemBuilder: (p) {
          final conflict = (p['conflictingPluginIds'] as List?)?.isNotEmpty ?? false;
          return ZMenuItem(
            icon: Icons.extension_outlined,
            title: '${p['displayName'] ?? p['name']}',
            subtitle: s.pluginDescription(
              '${p['marketplace'] ?? ''}',
              (p['skillQualifiedNames'] as List?)?.length ?? 0,
              (p['mcpServerNames'] as List?)?.length ?? 0,
            ),
            onTap: conflict ? null : () => widget.onInsert(pluginMention(p)),
          );
        },
      ),
      _Async(
        future: _files,
        header: s.files,
        empty: null,
        itemBuilder: (f) => ZMenuItem(
          icon: f['type'] == 'directory' ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
          title: '${f['name']}',
          subtitle: '${f['relativePath'] ?? ''}',
          onTap: () => widget.onInsert(fileMention(f)),
        ),
      ),
      if (sessions.isNotEmpty) ...[
        _Header(s.sessions),
        for (final t in sessions)
          ZMenuItem(
            icon: Icons.forum_outlined,
            title: t.title.isEmpty ? s.untitledSession : t.title,
            subtitle: ws.workspace.label,
            onTap: () => widget.onInsert(sessionMention(t.taskId, t.title)),
          ),
      ],
      const SizedBox(height: 8),
    ]);
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        child: Text(text, style: TextStyle(fontSize: ZText.xs, color: context.z.foregroundSubtlest)),
      );
}

/// A section fed by an RPC: a status row while loading or when empty /
/// failed. With [empty] null the whole section hides when there is nothing.
class _Async extends StatelessWidget {
  const _Async({required this.future, required this.empty, required this.itemBuilder, this.header});
  final Future<List<Map<String, dynamic>>> future;
  final String? empty;
  final String? header;
  final Widget Function(Map<String, dynamic>) itemBuilder;

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final z = context.z;
    Widget status(String text, {bool spinner = false}) => Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: Row(children: [
            if (spinner) ...[const ZSpinner(size: 12), const SizedBox(width: 8)],
            Flexible(child: Text(text, style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtle))),
          ]),
        );
    return FutureBuilder(
      future: future,
      builder: (context, snap) {
        final items = snap.data ?? const [];
        final List<Widget> body;
        if (snap.connectionState != ConnectionState.done) {
          body = [status(s.mentionLoading, spinner: true)];
        } else if (snap.hasError) {
          if (empty == null) return const SizedBox.shrink();
          body = [status('${snap.error}')];
        } else if (items.isEmpty) {
          if (empty == null) return const SizedBox.shrink();
          body = [status(empty!)];
        } else {
          body = [for (final i in items) itemBuilder(i)];
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (header != null) _Header(header!),
          ...body,
        ]);
      },
    );
  }
}
