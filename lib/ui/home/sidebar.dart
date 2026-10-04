import 'package:flutter/material.dart';

import '../../core/connection/device_connection.dart';
import '../../core/zcode/server_info.dart';
import '../../state/app_state.dart';
import '../../state/device_session.dart';
import '../../state/task_list_store.dart';
import '../devices/devices_sheet.dart';
import '../l10n.dart';
import '../settings/settings_page.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';

/// ZCode-style sidebar: device switcher, new task, search, task tabs.
class Sidebar extends StatefulWidget {
  const Sidebar({
    super.key,
    required this.app,
    required this.device,
    required this.selectedTaskId,
    required this.onSelectTask,
    required this.onNewTask,
  });

  final AppState app;
  final DeviceSession? device;
  final String? selectedTaskId;
  final ValueChanged<String> onSelectTask;
  final VoidCallback onNewTask;

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  TaskListKind _kind = TaskListKind.active;
  final TextEditingController _search = TextEditingController();
  bool _searching = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    final device = widget.device;
    return Container(
      color: z.sidebar,
      child: SafeArea(
        right: false,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: _DeviceSwitcher(app: widget.app, device: device),
          ),
          if (device != null) ...[
            ListenableBuilder(
              listenable: device,
              builder: (context, _) => _WorkspaceRow(device: device),
            ),
            const SizedBox(height: 4),
            _NavRow(icon: Icons.add_comment_outlined, label: s.newTask, onTap: widget.onNewTask),
            if (_searching)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: TextField(
                  controller: _search,
                  autofocus: true,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: s.search,
                    prefixIcon: Icon(Icons.search, size: 16, color: z.foregroundSubtle),
                    prefixIconConstraints: const BoxConstraints(minWidth: 36),
                    suffixIcon: IconButton(
                      icon: Icon(Icons.close, size: 16, color: z.foregroundSubtle),
                      onPressed: () => setState(() {
                        _search.clear();
                        _searching = false;
                      }),
                    ),
                  ),
                ),
              )
            else
              _NavRow(icon: Icons.search, label: s.search, onTap: () => setState(() => _searching = true)),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: _KindTabs(kind: _kind, onChanged: (k) => setState(() => _kind = k)),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: device.workspace == null
                  ? const SizedBox.shrink()
                  : _TaskList(
                      workspace: device.workspace!,
                      kind: _kind,
                      query: _search.text,
                      selectedTaskId: widget.selectedTaskId,
                      onSelect: widget.onSelectTask,
                    ),
            ),
          ] else
            const Spacer(),
          Divider(height: 1, color: z.border),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: Row(children: [
              ZIconButton(
                icon: Icons.devices_other_rounded,
                tooltip: s.devices,
                onPressed: () => showDevicesSheet(context, widget.app),
              ),
              const Spacer(),
              ZIconButton(
                icon: Icons.settings_outlined,
                tooltip: s.settings,
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => SettingsPage(app: widget.app)),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _DeviceSwitcher extends StatelessWidget {
  const _DeviceSwitcher({required this.app, required this.device});
  final AppState app;
  final DeviceSession? device;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    final d = device;
    return InkWell(
      borderRadius: BorderRadius.circular(ZRadius.lg),
      onTap: () => showDevicesSheet(context, app),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: d == null
            ? Row(children: [
                Icon(Icons.add, size: 18, color: z.foreground),
                const SizedBox(width: 8),
                Text(s.addDevice, style: TextStyle(fontSize: ZText.base, color: z.foreground)),
              ])
            : ListenableBuilder(
                listenable: d,
                builder: (context, _) => Row(children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: z.card,
                      borderRadius: BorderRadius.circular(ZRadius.lg),
                      border: Border.all(color: z.border),
                    ),
                    child: Icon(Icons.computer_rounded, size: 16, color: z.foreground),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(d.displayName,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: ZText.base, fontWeight: FontWeight.w600, color: z.foreground)),
                      Row(children: [
                        StatusDot(color: connectionColor(context, d.status.phase), size: 6),
                        const SizedBox(width: 5),
                        Flexible(
                          child: Text(connectionLabel(context, d.status),
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: ZText.xs, color: z.foregroundSubtle)),
                        ),
                      ]),
                    ]),
                  ),
                  if (app.sessions.length > 1)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: z.tag,
                        borderRadius: BorderRadius.circular(ZRadius.md),
                      ),
                      child: Text('${app.sessions.length}',
                          style: TextStyle(fontSize: ZText.xs, color: z.foregroundSubtle)),
                    ),
                  Icon(Icons.unfold_more_rounded, size: 16, color: z.foregroundSubtlest),
                ]),
              ),
      ),
    );
  }
}

class _WorkspaceRow extends StatelessWidget {
  const _WorkspaceRow({required this.device});
  final DeviceSession device;

  Future<void> _select(BuildContext context, WorkspaceRef w) async {
    final s = S.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (!w.connected) {
      messenger?.showSnackBar(SnackBar(content: Text(s.workspaceReconnecting(w.label))));
    }
    try {
      await device.selectWorkspace(w);
      if (!w.connected) messenger?.hideCurrentSnackBar();
    } catch (e) {
      messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
          content: Text(s.workspaceReconnectFailed(w.label, '$e')),
          duration: const Duration(seconds: 6),
        ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final ws = device.workspace;
    final list = device.workspaces;
    if (ws == null) return const SizedBox.shrink();
    return InkWell(
      borderRadius: BorderRadius.circular(ZRadius.lg),
      onTap: list.length < 2
          ? null
          : () => showZSheet<void>(context, title: S.of(context).workspace, builder: (ctx) {
                return ListView(shrinkWrap: true, padding: const EdgeInsets.symmetric(horizontal: 8), children: [
                  for (final w in list)
                    ZMenuItem(
                      icon: w.isRemote ? Icons.dns_outlined : Icons.folder_outlined,
                      title: w.label,
                      subtitle: w.path,
                      selected: w.key == ws.workspace.key,
                      trailing: w.connected
                          ? null
                          : Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: Text(S.of(ctx).workspaceDisconnected,
                                  style: TextStyle(fontSize: ZText.sm, color: ctx.z.warning)),
                            ),
                      onTap: () {
                        Navigator.pop(ctx);
                        _select(context, w);
                      },
                    ),
                ]);
              }),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(children: [
          Icon(ws.workspace.isRemote ? Icons.dns_outlined : Icons.folder_open_outlined,
              size: 16, color: z.foregroundSubtle),
          const SizedBox(width: 10),
          Expanded(
            child: Text(ws.workspace.label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtle)),
          ),
          if (device.reconnectingWorkspace != null ||
              device.status.phase == ConnectionPhase.connecting) ...[
            const ZSpinner(size: 12),
            const SizedBox(width: 6),
          ],
          if (list.length > 1) Icon(Icons.expand_more, size: 14, color: z.foregroundSubtlest),
        ]),
      ),
    );
  }
}

class _NavRow extends StatelessWidget {
  const _NavRow({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(ZRadius.lg),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          child: Row(children: [
            Icon(icon, size: 18, color: z.foreground),
            const SizedBox(width: 10),
            Text(label, style: TextStyle(fontSize: ZText.base, color: z.foreground)),
          ]),
        ),
      ),
    );
  }
}

class _KindTabs extends StatelessWidget {
  const _KindTabs({required this.kind, required this.onChanged});
  final TaskListKind kind;
  final ValueChanged<TaskListKind> onChanged;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    Widget tab(TaskListKind k, String label) {
      final active = k == kind;
      return Expanded(
        child: GestureDetector(
          onTap: () => onChanged(k),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: active ? z.card : Colors.transparent,
              borderRadius: BorderRadius.circular(ZRadius.md),
              border: Border.all(color: active ? z.border : Colors.transparent),
            ),
            alignment: Alignment.center,
            child: Text(label,
                style: TextStyle(
                  fontSize: ZText.sm,
                  color: active ? z.foreground : z.foregroundSubtle,
                  fontWeight: active ? FontWeight.w500 : FontWeight.normal,
                )),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: z.surface, borderRadius: BorderRadius.circular(ZRadius.lg)),
      child: Row(children: [
        tab(TaskListKind.active, s.tasks),
        tab(TaskListKind.pinned, s.pinned),
        tab(TaskListKind.archived, s.archived),
      ]),
    );
  }
}

class _TaskList extends StatelessWidget {
  const _TaskList({
    required this.workspace,
    required this.kind,
    required this.query,
    required this.selectedTaskId,
    required this.onSelect,
  });

  final WorkspaceSession workspace;
  final TaskListKind kind;
  final String query;
  final String? selectedTaskId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    return ListenableBuilder(
      listenable: workspace.tasks,
      builder: (context, _) {
        final items = workspace.tasks.items(kind, query: query);
        if (items.isEmpty) {
          final loading = !workspace.tasks.loadedIndex && !workspace.tasks.isLive;
          return Padding(
            padding: const EdgeInsets.all(16),
            child: loading
                ? const Align(alignment: Alignment.topCenter, child: ZSpinner(size: 14))
                : Text(s.noTasks, style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtlest)),
          );
        }
        return RefreshIndicator(
          onRefresh: () async {
            workspace.sessionsIndex.refresh();
            await workspace.tasks.refresh();
          },
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            itemCount: items.length,
            itemBuilder: (context, i) => _TaskRow(
              key: ValueKey(items[i].taskId),
              item: items[i],
              selected: items[i].taskId == selectedTaskId,
              onTap: () => onSelect(items[i].taskId),
              onMenu: () => _menu(context, items[i]),
            ),
          ),
        );
      },
    );
  }

  void _menu(BuildContext context, TaskItem item) {
    final s = S.of(context);
    final tasks = workspace.tasks;
    Future<void> run(Future<void> Function() op) async {
      try {
        await op();
      } catch (e) {
        if (context.mounted) showToast(context, '$e');
      }
    }

    showZSheet<void>(context, title: item.title, builder: (ctx) {
      return Column(mainAxisSize: MainAxisSize.min, children: [
        ZMenuItem(
          icon: item.pinned ? Icons.push_pin : Icons.push_pin_outlined,
          title: item.pinned ? s.unpin : s.pin,
          onTap: () {
            Navigator.pop(ctx);
            run(() => tasks.setPinned(item.taskId, !item.pinned));
          },
        ),
        ZMenuItem(
          icon: item.archived ? Icons.unarchive_outlined : Icons.archive_outlined,
          title: item.archived ? s.unarchive : s.archive,
          onTap: () {
            Navigator.pop(ctx);
            run(() => tasks.setArchived(item.taskId, !item.archived));
          },
        ),
        ZMenuItem(
          icon: Icons.delete_outline,
          title: s.delete,
          destructive: true,
          onTap: () async {
            Navigator.pop(ctx);
            if (await confirm(context,
                title: s.delete, body: s.deleteTaskConfirm, action: s.delete, destructive: true)) {
              run(() => tasks.delete(item.taskId));
            }
          },
        ),
      ]);
    });
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({
    super.key,
    required this.item,
    required this.selected,
    required this.onTap,
    required this.onMenu,
  });

  final TaskItem item;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final title = item.title.trim().isEmpty ? S.of(context).newTask : item.title;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Material(
        color: selected ? z.selected : Colors.transparent,
        borderRadius: BorderRadius.circular(ZRadius.lg),
        child: InkWell(
          borderRadius: BorderRadius.circular(ZRadius.lg),
          onTap: onTap,
          onLongPress: onMenu,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
            child: Row(children: [
              SizedBox(width: 16, child: Center(child: _leading(context))),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: ZText.base,
                      color: z.foreground,
                      fontWeight: item.unread ? FontWeight.w600 : FontWeight.normal,
                    )),
              ),
              const SizedBox(width: 8),
              Text(shortAgo(item.updatedAt),
                  style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtlest)),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _leading(BuildContext context) {
    final z = context.z;
    if (item.status == TaskStatus.running ||
        item.status == TaskStatus.waiting ||
        item.status == TaskStatus.error) {
      return TaskStatusIcon(status: item.status);
    }
    if (item.unread) return StatusDot(color: z.link, size: 7);
    if (item.pinned) return Icon(Icons.push_pin_outlined, size: 13, color: z.foregroundSubtlest);
    return const SizedBox.shrink();
  }
}
