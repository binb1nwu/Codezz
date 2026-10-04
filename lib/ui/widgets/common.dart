import 'package:flutter/material.dart';

import '../../core/connection/device_connection.dart';
import '../../state/task_list_store.dart';
import '../l10n.dart';
import '../theme/tokens.dart';
import 'glass.dart';

/// Square ghost icon button (`size-8`, `rounded-lg`), ZCode's `icon-sm`.
class ZIconButton extends StatelessWidget {
  const ZIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.tooltip,
    this.size = 32,
    this.iconSize = 18,
    this.color,
    this.filled = false,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  final double size;
  final double iconSize;
  final Color? color;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final enabled = onPressed != null;
    Widget child = Material(
      color: filled ? (enabled ? z.primary : z.secondary) : Colors.transparent,
      borderRadius: BorderRadius.circular(ZRadius.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(ZRadius.lg),
        onTap: onPressed,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(
            icon,
            size: iconSize,
            color: filled
                ? (enabled ? z.primaryForeground : z.foregroundSubtlest)
                : (color ?? (enabled ? z.foregroundSubtle : z.foregroundSubtlest)),
          ),
        ),
      ),
    );
    if (tooltip != null) child = Tooltip(message: tooltip!, child: child);
    return child;
  }
}

/// Compact ghost button with optional leading icon and trailing chevron,
/// like the composer toolbar pickers.
class ZChipButton extends StatelessWidget {
  const ZChipButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.chevron = true,
    this.maxWidth = 180,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool chevron;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final color = onPressed == null ? z.foregroundSubtlest : z.foregroundSubtle;
    return InkWell(
      borderRadius: BorderRadius.circular(ZRadius.lg),
      onTap: onPressed,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth, minHeight: 32),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, size: 16, color: color), const SizedBox(width: 4)],
            Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: TextStyle(fontSize: ZText.sm, color: color)),
            ),
            if (chevron) Icon(Icons.expand_more, size: 14, color: color),
          ]),
        ),
      ),
    );
  }
}

class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.color, this.size = 8, this.pulse = false});
  final Color color;
  final double size;
  final bool pulse;

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
    if (!pulse) return dot;
    return _Pulse(child: dot);
  }
}

class _Pulse extends StatefulWidget {
  const _Pulse({required this.child});
  final Widget child;
  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
        ..repeat(reverse: true);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: Tween(begin: 0.35, end: 1.0).animate(_c),
        child: widget.child,
      );
}

Color connectionColor(BuildContext context, ConnectionPhase phase) {
  final z = context.z;
  return switch (phase) {
    ConnectionPhase.online => z.success,
    ConnectionPhase.connecting => z.warning,
    ConnectionPhase.offline => z.foregroundSubtlest,
    ConnectionPhase.unauthorized => z.destructive,
    ConnectionPhase.idle => z.foregroundSubtlest,
  };
}

String connectionLabel(BuildContext context, ConnectionStatus status) {
  final s = S.of(context);
  switch (status.phase) {
    case ConnectionPhase.online:
      return s.online;
    case ConnectionPhase.connecting:
    case ConnectionPhase.idle:
      return s.connecting;
    case ConnectionPhase.unauthorized:
      return s.unauthorized;
    case ConnectionPhase.offline:
      final at = status.nextRetryAt;
      if (at == null) return s.offline;
      final secs = at.difference(DateTime.now()).inSeconds;
      return secs > 0 ? '${s.offline} · ${s.retryingIn(secs)}' : s.connecting;
  }
}

/// Small spinner used for running states.
class ZSpinner extends StatelessWidget {
  const ZSpinner({super.key, this.size = 12, this.color});
  final double size;
  final Color? color;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CircularProgressIndicator(
          strokeWidth: 1.6,
          color: color ?? context.z.foregroundSubtle,
        ),
      );
}

/// Task status glyph used in the sidebar and headers.
class TaskStatusIcon extends StatelessWidget {
  const TaskStatusIcon({super.key, required this.status, this.size = 14});
  final TaskStatus status;
  final double size;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return switch (status) {
      TaskStatus.running => ZSpinner(size: size - 2),
      TaskStatus.waiting => Icon(Icons.pan_tool_alt_outlined, size: size, color: z.confirmForeground),
      TaskStatus.error => Icon(Icons.error_outline, size: size, color: z.destructive),
      TaskStatus.interrupted => Icon(Icons.stop_circle_outlined, size: size, color: z.foregroundSubtle),
      _ => SizedBox(width: size, height: size),
    };
  }
}

/// `2m`, `3h`, `5d` like ZCode's sidebar.
String shortAgo(int epochMs) {
  if (epochMs <= 0) return '';
  final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(epochMs));
  if (d.inMinutes < 1) return 'now';
  if (d.inHours < 1) return '${d.inMinutes}m';
  if (d.inDays < 1) return '${d.inHours}h';
  if (d.inDays < 30) return '${d.inDays}d';
  return '${(d.inDays / 30).floor()}mo';
}

String formatDuration(int ms) {
  final s = (ms / 1000).round();
  if (s < 60) return '${s}s';
  final m = s ~/ 60;
  if (m < 60) return '${m}m ${s % 60}s';
  return '${m ~/ 60}h ${m % 60}m';
}

void showToast(BuildContext context, String message) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 3)));
}

Future<bool> confirm(BuildContext context,
    {required String title, String? body, required String action, bool destructive = false}) async {
  final s = S.of(context);
  final z = context.z;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: body == null ? null : Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.cancel)),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(backgroundColor: z.destructive, foregroundColor: Colors.white)
              : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Menu-style option row for bottom sheets (`rounded-md`, compact).
class ZMenuItem extends StatelessWidget {
  const ZMenuItem({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.selected = false,
    this.onTap,
    this.trailing,
    this.destructive = false,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final bool selected;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final color = destructive ? z.destructive : z.foreground;
    return InkWell(
      borderRadius: BorderRadius.circular(ZRadius.md),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(children: [
          if (icon != null) ...[
            Icon(icon, size: 18, color: destructive ? z.destructive : z.foregroundSubtle),
            const SizedBox(width: 12),
          ],
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontSize: ZText.base, color: color)),
              if (subtitle != null && subtitle!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(subtitle!,
                      style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtle)),
                ),
            ]),
          ),
          if (trailing != null) trailing!,
          if (selected) Icon(Icons.check, size: 18, color: z.foreground),
        ]),
      ),
    );
  }
}

Future<T?> showZSheet<T>(BuildContext context,
    {required Widget Function(BuildContext) builder, String? title}) {
  final glass = GlassScope.of(context);
  const radius = BorderRadius.vertical(top: Radius.circular(ZRadius.x2l));
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 560),
    // With glass the sheet draws its own frosted card and drag handle.
    backgroundColor: glass ? Colors.transparent : null,
    elevation: glass ? 0 : null,
    showDragHandle: glass ? false : null,
    builder: (ctx) => _SheetCard(
      glass: glass,
      radius: radius,
      child: Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(title,
                  style: TextStyle(
                      fontSize: ZText.base, fontWeight: FontWeight.w600, color: ctx.z.foreground)),
            ),
          Flexible(child: builder(ctx)),
          const SizedBox(height: 8),
        ]),
      ),
    ),
    ),
  );
}

/// The sheet's frosted card with a 32×4 drag handle, as the theme's sheet
/// draws them when glass is off.
class _SheetCard extends StatelessWidget {
  const _SheetCard({required this.glass, required this.radius, required this.child});
  final bool glass;
  final BorderRadius radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!glass) return child;
    final z = context.z;
    return Glass(
      borderRadius: radius,
      // Sheets cover other glass, so they blur on their own.
      grouped: false,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: glassColor(context, z.popover),
          borderRadius: radius,
          border: Border(top: BorderSide(color: z.border)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            height: kMinInteractiveDimension,
            child: Center(
              child: Container(
                width: 32,
                height: 4,
                decoration: BoxDecoration(color: z.foregroundSubtlest, borderRadius: BorderRadius.circular(2)),
              ),
            ),
          ),
          Flexible(child: child),
        ]),
      ),
    );
  }
}

