import 'package:flutter/material.dart';

import '../../core/connection/device_connection.dart';
import '../../state/app_state.dart';
import '../../state/device_session.dart';
import '../l10n.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import 'add_device_page.dart';

/// Device switcher: every linked device with its live status. Devices stay
/// connected in the background, so switching is instant.
Future<void> showDevicesSheet(BuildContext context, AppState app) {
  final s = S.of(context);
  return showZSheet<void>(
    context,
    title: s.devices,
    builder: (ctx) => ListenableBuilder(
      listenable: Listenable.merge([app, app.registry, ...app.sessions]),
      builder: (ctx, _) {
        final sessions = app.sessions;
        final activeId = app.registry.active?.id;
        return ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          children: [
            for (final session in sessions)
              DeviceTile(
                session: session,
                active: session.device.id == activeId,
                onTap: () {
                  app.registry.setActive(session.device);
                  Navigator.pop(ctx);
                },
                onMore: () => showDeviceActions(ctx, app, session),
              ),
            const SizedBox(height: 4),
            ZMenuItem(
              icon: Icons.add,
              title: s.addDevice,
              onTap: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => AddDevicePage(app: app)));
              },
            ),
          ],
        );
      },
    ),
  );
}

class DeviceTile extends StatelessWidget {
  const DeviceTile({super.key, required this.session, required this.active, this.onTap, this.onMore});
  final DeviceSession session;
  final bool active;
  final VoidCallback? onTap;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final status = session.status;
    final running = session.activeTaskCount;
    return Material(
      color: active ? z.selected : Colors.transparent,
      borderRadius: BorderRadius.circular(ZRadius.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(ZRadius.lg),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Row(children: [
            Stack(clipBehavior: Clip.none, children: [
              Icon(Icons.computer_rounded, size: 22, color: z.foreground),
              Positioned(
                right: -2,
                bottom: -2,
                child: Container(
                  padding: const EdgeInsets.all(1.5),
                  decoration: BoxDecoration(color: z.popover, shape: BoxShape.circle),
                  child: StatusDot(
                    color: connectionColor(context, status.phase),
                    size: 7,
                    pulse: status.phase == ConnectionPhase.connecting,
                  ),
                ),
              ),
            ]),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(session.displayName,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: ZText.base, fontWeight: FontWeight.w500, color: z.foreground)),
                const SizedBox(height: 2),
                Text(
                  [
                    connectionLabel(context, status),
                    session.device.link.displayHost,
                    if (status.latencyMs != null && status.isOnline) '${status.latencyMs}ms',
                  ].join(' · '),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtle),
                ),
              ]),
            ),
            if (running > 0)
              Container(
                margin: const EdgeInsets.only(left: 6),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: z.confirmSurface,
                  borderRadius: BorderRadius.circular(ZRadius.md),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  ZSpinner(size: 9, color: z.confirmForeground),
                  const SizedBox(width: 4),
                  Text('$running', style: TextStyle(fontSize: ZText.xs, color: z.confirmForeground)),
                ]),
              ),
            if (onMore != null)
              ZIconButton(icon: Icons.more_horiz, onPressed: onMore, tooltip: S.of(context).editDevice),
          ]),
        ),
      ),
    );
  }
}

Future<void> showDeviceActions(BuildContext context, AppState app, DeviceSession session) {
  final s = S.of(context);
  return showZSheet<void>(context, title: session.displayName, builder: (ctx) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      ZMenuItem(
        icon: Icons.refresh_rounded,
        title: s.reconnect,
        onTap: () {
          Navigator.pop(ctx);
          session.connection.forceReconnect();
        },
      ),
      ZMenuItem(
        icon: Icons.edit_outlined,
        title: s.editDevice,
        subtitle: s.updateLink,
        onTap: () {
          Navigator.pop(ctx);
          Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => AddDevicePage(app: app, device: session.device)));
        },
      ),
      ZMenuItem(
        icon: Icons.delete_outline,
        title: s.removeDevice,
        destructive: true,
        onTap: () async {
          Navigator.pop(ctx);
          if (await confirm(context,
              title: s.removeDevice,
              body: s.removeDeviceConfirm(session.displayName),
              action: s.delete,
              destructive: true)) {
            await app.registry.remove(session.device);
          }
        },
      ),
    ]);
  });
}
