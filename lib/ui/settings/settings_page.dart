import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/app_state.dart';
import '../devices/add_device_page.dart';
import '../devices/devices_sheet.dart';
import '../l10n.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    final segmentStyle = SegmentedButton.styleFrom(
      selectedBackgroundColor: z.selected,
      selectedForegroundColor: z.foreground,
      foregroundColor: z.foregroundSubtle,
      side: BorderSide(color: z.border),
      textStyle: const TextStyle(fontSize: ZText.sm),
    );
    return Scaffold(
      backgroundColor: z.panel,
      appBar: AppBar(title: Text(s.settings)),
      body: ListenableBuilder(
        listenable: Listenable.merge([app, app.registry, ...app.sessions]),
        builder: (context, _) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(padding: const EdgeInsets.all(16), children: [
              _Section(title: s.devices, children: [
                for (final session in app.sessions)
                  DeviceTile(
                    session: session,
                    active: session.device.id == app.registry.active?.id,
                    onTap: () => app.registry.setActive(session.device),
                    onMore: () => showDeviceActions(context, app, session),
                  ),
                ZMenuItem(
                  icon: Icons.add,
                  title: s.addDevice,
                  onTap: () => Navigator.of(context)
                      .push(MaterialPageRoute(builder: (_) => AddDevicePage(app: app))),
                ),
              ]),
              _Section(title: s.appearance, children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: SegmentedButton<AppThemeMode>(
                    showSelectedIcon: false,
                    style: segmentStyle,
                    segments: [
                      ButtonSegment(value: AppThemeMode.system, label: Text(s.themeSystem)),
                      ButtonSegment(value: AppThemeMode.light, label: Text(s.themeLight)),
                      ButtonSegment(value: AppThemeMode.dark, label: Text(s.themeDark)),
                    ],
                    selected: {app.themeMode},
                    onSelectionChanged: (v) => app.setThemeMode(v.first),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Row(children: [
                    Text(s.textSize, style: TextStyle(fontSize: ZText.base, color: z.foreground)),
                    Expanded(
                      child: Slider(
                        value: app.textScale,
                        min: 0.85,
                        max: 1.3,
                        divisions: 9,
                        activeColor: z.foreground,
                        inactiveColor: z.secondary,
                        label: '${(app.textScale * 100).round()}%',
                        onChanged: app.setTextScale,
                      ),
                    ),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Row(children: [
                    Expanded(
                      child: Text(s.contextDisplay, style: TextStyle(fontSize: ZText.base, color: z.foreground)),
                    ),
                    SegmentedButton<ContextDisplay>(
                      showSelectedIcon: false,
                      style: segmentStyle,
                      segments: [
                        ButtonSegment(value: ContextDisplay.ring, label: Text(s.contextDisplayRing)),
                        ButtonSegment(value: ContextDisplay.bar, label: Text(s.contextDisplayBar)),
                      ],
                      selected: {app.contextDisplay},
                      onSelectionChanged: (v) => app.setContextDisplay(v.first),
                    ),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Row(children: [
                    Expanded(
                      child: Text(s.quotaPlacement, style: TextStyle(fontSize: ZText.base, color: z.foreground)),
                    ),
                    SegmentedButton<QuotaPlacement>(
                      showSelectedIcon: false,
                      style: segmentStyle,
                      segments: [
                        ButtonSegment(value: QuotaPlacement.ring, label: Text(s.quotaPlacementRing)),
                        ButtonSegment(value: QuotaPlacement.header, label: Text(s.quotaPlacementHeader)),
                      ],
                      selected: {app.quotaPlacement},
                      onSelectionChanged: (v) => app.setQuotaPlacement(v.first),
                    ),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 4, 8),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(s.glassEffect, style: TextStyle(fontSize: ZText.base, color: z.foreground)),
                        const SizedBox(height: 2),
                        Text(s.glassEffectHint,
                            style: TextStyle(fontSize: ZText.xs, color: z.foregroundSubtle, height: 1.4)),
                      ]),
                    ),
                    const SizedBox(width: 8),
                    Switch(
                      value: app.glass,
                      activeThumbColor: z.primaryForeground,
                      activeTrackColor: z.foreground,
                      onChanged: app.setGlass,
                    ),
                  ]),
                ),
              ]),
              _Section(title: s.diagnostics, children: [
                ZMenuItem(
                  icon: Icons.receipt_long_outlined,
                  title: s.diagnostics,
                  subtitle: '${app.logs.lines.length}',
                  onTap: () => Navigator.of(context)
                      .push(MaterialPageRoute(builder: (_) => _LogPage(app: app))),
                ),
              ]),
              _Section(title: s.about, children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text('Codezz $appVersion\n\n${s.aboutBody}',
                      style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtle, height: 1.5)),
                ),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Text(title,
              style: TextStyle(fontSize: ZText.sm, fontWeight: FontWeight.w500, color: z.foregroundSubtle)),
        ),
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: z.card,
            borderRadius: BorderRadius.circular(ZRadius.xl),
            border: Border.all(color: z.border),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        ),
      ]),
    );
  }
}

class _LogPage extends StatelessWidget {
  const _LogPage({required this.app});
  final AppState app;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    return Scaffold(
      backgroundColor: z.panel,
      appBar: AppBar(title: Text(s.diagnostics), actions: [
        ZIconButton(
          icon: Icons.copy_rounded,
          tooltip: s.copy,
          onPressed: () {
            Clipboard.setData(ClipboardData(text: app.logs.lines.join('\n')));
            showToast(context, s.copied);
          },
        ),
        ZIconButton(icon: Icons.delete_outline, tooltip: s.clear, onPressed: app.logs.clear),
        const SizedBox(width: 8),
      ]),
      body: ListenableBuilder(
        listenable: app.logs,
        builder: (context, _) {
          final lines = app.logs.lines.reversed.toList();
          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: lines.length,
            itemBuilder: (context, i) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: SelectableText(lines[i],
                  style: TextStyle(
                      fontFamily: zMonoFamily,
                      fontFamilyFallback: zMonoFallback,
                      fontSize: 11.5,
                      color: z.foregroundSubtle)),
            ),
          );
        },
      ),
    );
  }
}
