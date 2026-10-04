import 'package:flutter/material.dart';

import '../../state/device_session.dart';
import '../../state/side_pane.dart';
import '../l10n.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import 'review_view.dart';
import 'terminal_tab.dart';

const reviewIcon = Icons.difference_outlined;
const terminalIcon = Icons.terminal_rounded;

/// Header button that shows / hides the side pane (`sidePane.togglePanel`).
class SidePaneToggle extends StatelessWidget {
  const SidePaneToggle({super.key, required this.pane});
  final SidePane pane;

  @override
  Widget build(BuildContext context) => ZIconButton(
        icon: Icons.view_sidebar_outlined,
        tooltip: S.of(context).togglePanel,
        onPressed: pane.toggle,
      );
}

/// Shows the side pane (Review / Terminal tabs) as a page of its own while
/// `pane.visible`: back closes it and returns to the conversation, and
/// hiding the pane (its back button, closing the last tab elsewhere) pops
/// the page.
class SidePaneHost extends StatefulWidget {
  const SidePaneHost({super.key, required this.workspace, required this.child});
  final WorkspaceSession workspace;
  final Widget child;

  @override
  State<SidePaneHost> createState() => _SidePaneHostState();
}

class _SidePaneHostState extends State<SidePaneHost> {
  Route<void>? _route;
  NavigatorState? _navigator;

  SidePane get pane => widget.workspace.sidePane;

  @override
  void initState() {
    super.initState();
    pane.addListener(_onPane);
    if (pane.visible) _onPane();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigator = Navigator.of(context);
  }

  @override
  void didUpdateWidget(covariant SidePaneHost old) {
    super.didUpdateWidget(old);
    if (old.workspace.sidePane != pane) {
      old.workspace.sidePane.removeListener(_onPane);
      pane.addListener(_onPane);
    }
  }

  @override
  void dispose() {
    pane.removeListener(_onPane);
    _close();
    super.dispose();
  }

  // Not while notifying (possibly mid-build): the navigator changes routes.
  void _onPane() => Future.microtask(_sync);

  void _sync() {
    if (!mounted) return;
    if (pane.visible && _route == null) {
      final route = MaterialPageRoute<void>(builder: (_) => SidePanePage(workspace: widget.workspace));
      _route = route;
      _navigator!.push(route).then((_) {
        // Back (or a swipe) closed the page.
        if (_route == route) _route = null;
        if (pane.visible) pane.hide();
      });
    } else if (!pane.visible) {
      _close();
    }
  }

  void _close() {
    final route = _route;
    _route = null;
    if (route == null || !route.isActive) return;
    if (route.isCurrent) {
      _navigator!.pop();
    } else {
      _navigator!.removeRoute(route);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The side pane page: ZCode's Review and Terminal tabs, full screen.
class SidePanePage extends StatelessWidget {
  const SidePanePage({super.key, required this.workspace});
  final WorkspaceSession workspace;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: workspace.sidePane,
      builder: (context, _) => Scaffold(backgroundColor: context.z.panel, body: _Panel(workspace: workspace)),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.workspace});
  final WorkspaceSession workspace;

  SidePane get pane => workspace.sidePane;

  void _openTerminal(BuildContext context) {
    final api = workspace.api;
    final s = S.of(context);
    if (api == null) {
      showToast(context, s.offlineBanner);
      return;
    }
    pane.openTerminal(
      api,
      workspace.workspace.path,
      TerminalTexts(exited: s.terminalExited, failed: s.terminalFailed, disconnected: s.terminalDisconnected),
    );
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    final active = pane.active;
    // Review is offered once; terminals can be opened repeatedly.
    final choices = [
      if (!pane.hasReview) (reviewIcon, s.review, pane.openReview),
      (terminalIcon, s.terminal, () => _openTerminal(context)),
    ];
    return Material(
      color: z.panel,
      elevation: 0,
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: z.border))),
            child: Row(children: [
              ZIconButton(icon: Icons.arrow_back_rounded, tooltip: s.back, onPressed: pane.hide),
              Expanded(
                child: ListView(scrollDirection: Axis.horizontal, children: [
                  for (final t in pane.tabs)
                    _TabChip(
                      tab: t,
                      label: t.kind == SidePaneKind.review ? s.review : t.title,
                      selected: t.id == pane.activeId,
                      onTap: () => pane.select(t.id),
                      onClose: () => pane.closeTab(t.id),
                    ),
                ]),
              ),
              PopupMenuButton<VoidCallback>(
                tooltip: s.addTab,
                icon: Icon(Icons.add_rounded, size: 18, color: z.foregroundSubtle),
                onSelected: (action) => action(),
                itemBuilder: (_) => [
                  for (final (icon, label, action) in choices)
                    PopupMenuItem(
                      value: action,
                      child: Row(children: [
                        Icon(icon, size: 16, color: z.foregroundSubtle),
                        const SizedBox(width: 10),
                        Text(label),
                      ]),
                    ),
                ],
              ),
            ]),
          ),
          Expanded(
            child: switch (active) {
              null => _OpenTab(choices: choices),
              final t when t.kind == SidePaneKind.review => ReviewView(workspace: workspace),
              final t => TerminalTab(key: ValueKey(t.id), session: t.terminal!),
            },
          ),
        ]),
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.tab,
    required this.label,
    required this.selected,
    required this.onTap,
    required this.onClose,
  });

  final SidePaneTab tab;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    final color = selected ? z.foreground : z.foregroundSubtle;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
      child: Material(
        color: selected ? z.selected : Colors.transparent,
        borderRadius: BorderRadius.circular(ZRadius.lg),
        child: InkWell(
          borderRadius: BorderRadius.circular(ZRadius.lg),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(tab.kind == SidePaneKind.review ? reviewIcon : terminalIcon, size: 14, color: color),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 120),
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: ZText.sm, color: color)),
              ),
              ZIconButton(
                icon: Icons.close_rounded,
                size: 26,
                iconSize: 13,
                tooltip: s.closeTab(label),
                onPressed: onClose,
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Empty pane: `打开标签页` with one large button per tab kind.
class _OpenTab extends StatelessWidget {
  const _OpenTab({required this.choices});
  final List<(IconData, String, VoidCallback)> choices;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text(s.openTab, style: TextStyle(fontSize: ZText.base, fontWeight: FontWeight.w600, color: z.foreground)),
      const SizedBox(height: 4),
      Text(s.openTabDescription, style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtle)),
      const SizedBox(height: 16),
      for (final (icon, label, action) in choices)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Material(
            color: z.surface,
            borderRadius: BorderRadius.circular(ZRadius.xl),
            child: InkWell(
              borderRadius: BorderRadius.circular(ZRadius.xl),
              onTap: action,
              child: SizedBox(
                height: 48,
                child: Row(children: [
                  const SizedBox(width: 14),
                  Icon(icon, size: 18, color: z.foreground),
                  const SizedBox(width: 12),
                  Text(label, style: TextStyle(fontSize: ZText.base, color: z.foreground)),
                ]),
              ),
            ),
          ),
        ),
    ]);
  }
}
