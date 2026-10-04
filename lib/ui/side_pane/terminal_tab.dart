import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../../state/side_pane.dart';
import '../l10n.dart';
import '../theme/tokens.dart';

/// `--color-terminal-*` defaults of ZCode (background #171717, foreground
/// #e5e5e5) on xterm's standard palette.
const _theme = TerminalTheme(
  cursor: Color(0xFFE5E5E5),
  selection: Color(0x664099FF),
  foreground: Color(0xFFE5E5E5),
  background: Color(0xFF171717),
  black: Color(0xFF000000),
  red: Color(0xFFCD3131),
  green: Color(0xFF0DBC79),
  yellow: Color(0xFFE5E510),
  blue: Color(0xFF2472C8),
  magenta: Color(0xFFBC3FBC),
  cyan: Color(0xFF11A8CD),
  white: Color(0xFFE5E5E5),
  brightBlack: Color(0xFF666666),
  brightRed: Color(0xFFF14C4C),
  brightGreen: Color(0xFF23D18B),
  brightYellow: Color(0xFFF5F543),
  brightBlue: Color(0xFF3B8EEA),
  brightMagenta: Color(0xFFD670D6),
  brightCyan: Color(0xFF29B8DB),
  brightWhite: Color(0xFFFFFFFF),
  searchHitBackground: Color(0xFFFFFF2B),
  searchHitBackgroundCurrent: Color(0xFF31FF26),
  searchHitForeground: Color(0xFF000000),
);

/// One terminal tab: the xterm view plus a key bar for what a phone
/// keyboard lacks (Esc, Tab, Ctrl, arrows, copy / paste).
class TerminalTab extends StatefulWidget {
  const TerminalTab({super.key, required this.session});
  final TerminalSession session;

  @override
  State<TerminalTab> createState() => _TerminalTabState();
}

class _TerminalTabState extends State<TerminalTab> {
  final TerminalController _controller = TerminalController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  TerminalSession get session => widget.session;

  Future<void> _copy() async {
    final selection = _controller.selection;
    if (selection == null) return;
    await Clipboard.setData(ClipboardData(text: session.terminal.buffer.getText(selection)));
    _controller.clearSelection();
  }

  Future<void> _paste() async {
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (text != null && text.isNotEmpty) session.terminal.paste(text);
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Expanded(
        child: ColoredBox(
          color: _theme.background,
          child: TerminalView(
            session.terminal,
            controller: _controller,
            theme: _theme,
            autofocus: true,
            padding: const EdgeInsets.all(6),
            textStyle: const TerminalStyle(
              fontSize: 13,
              fontFamily: zMonoFamily,
              fontFamilyFallback: zMonoFallback,
            ),
          ),
        ),
      ),
      ListenableBuilder(
        listenable: Listenable.merge([session, _controller]),
        builder: (context, _) => _KeyBar(
          ctrl: session.ctrl,
          enabled: !session.exited,
          canCopy: _controller.selection != null,
          onKey: (k) => session.terminal.keyInput(k),
          onCtrl: () => session.setCtrl(!session.ctrl),
          onCopy: _copy,
          onPaste: _paste,
        ),
      ),
    ]);
  }
}

class _KeyBar extends StatelessWidget {
  const _KeyBar({
    required this.ctrl,
    required this.enabled,
    required this.canCopy,
    required this.onKey,
    required this.onCtrl,
    required this.onCopy,
    required this.onPaste,
  });

  final bool ctrl;
  final bool enabled;
  final bool canCopy;
  final ValueChanged<TerminalKey> onKey;
  final VoidCallback onCtrl;
  final VoidCallback onCopy;
  final VoidCallback onPaste;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    Widget key(String label, VoidCallback? onTap, {bool active = false, IconData? icon}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Material(
            color: active ? z.selected : z.surface,
            borderRadius: BorderRadius.circular(ZRadius.md),
            child: InkWell(
              borderRadius: BorderRadius.circular(ZRadius.md),
              onTap: onTap,
              child: Container(
                constraints: const BoxConstraints(minWidth: 36),
                height: 32,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                alignment: Alignment.center,
                child: icon != null
                    ? Icon(icon, size: 16, color: onTap == null ? z.foregroundSubtlest : z.foreground)
                    : Text(label,
                        style: TextStyle(
                          fontSize: ZText.sm,
                          fontFamily: zMonoFamily,
                          fontFamilyFallback: zMonoFallback,
                          fontWeight: active ? FontWeight.w600 : null,
                          color: onTap == null ? z.foregroundSubtlest : z.foreground,
                        )),
              ),
            ),
          ),
        );
    VoidCallback? on(TerminalKey k) => enabled ? () => onKey(k) : null;
    return Container(
      height: 44,
      decoration: BoxDecoration(color: z.panel, border: Border(top: BorderSide(color: z.border))),
      child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.all(6), children: [
        key('Esc', on(TerminalKey.escape)),
        key('Tab', on(TerminalKey.tab)),
        key('Ctrl', enabled ? onCtrl : null, active: ctrl),
        key('←', on(TerminalKey.arrowLeft), icon: Icons.keyboard_arrow_left_rounded),
        key('↑', on(TerminalKey.arrowUp), icon: Icons.keyboard_arrow_up_rounded),
        key('↓', on(TerminalKey.arrowDown), icon: Icons.keyboard_arrow_down_rounded),
        key('→', on(TerminalKey.arrowRight), icon: Icons.keyboard_arrow_right_rounded),
        key(s.terminalCopy, canCopy ? onCopy : null),
        key(s.terminalPaste, enabled ? onPaste : null),
      ]),
    );
  }
}
