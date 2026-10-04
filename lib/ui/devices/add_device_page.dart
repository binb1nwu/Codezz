import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/link/device_link.dart';
import '../../state/app_state.dart';
import '../../state/device_registry.dart';
import '../l10n.dart';
import '../theme/tokens.dart';
import 'qr_scan_page.dart';

/// Link a new ZCode desktop, or update the link of an existing one.
class AddDevicePage extends StatefulWidget {
  const AddDevicePage({super.key, required this.app, this.device, this.initialLink});
  final AppState app;
  final Device? device;
  final String? initialLink;

  @override
  State<AddDevicePage> createState() => _AddDevicePageState();
}

class _AddDevicePageState extends State<AddDevicePage> {
  late final TextEditingController _link =
      TextEditingController(text: widget.initialLink ?? widget.device?.link.canonical ?? '');
  late final TextEditingController _name = TextEditingController(text: widget.device?.label ?? '');
  String? _error;
  bool _saving = false;

  bool get _scanSupported =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  @override
  void dispose() {
    _link.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) setState(() => _link.text = data!.text!.trim());
  }

  Future<void> _scan() async {
    final value = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScanPage()),
    );
    if (value != null) setState(() => _link.text = value.trim());
  }

  Future<void> _save() async {
    final s = S.of(context);
    final result = DeviceLink.parse(_link.text);
    if (result.link == null) {
      setState(() => _error = result.error == 'relayIncomplete' ? s.linkIncomplete : s.linkInvalid);
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    final registry = widget.app.registry;
    final device = widget.device;
    if (device != null) {
      await registry.updateLink(device, result.link!);
      await registry.rename(device, _name.text);
      await registry.setActive(device);
    } else {
      await registry.addOrUpdate(result.link!, label: _name.text);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.device == null ? s.addDevice : s.editDevice)),
      backgroundColor: z.panel,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(padding: const EdgeInsets.all(20), children: [
              Text(s.deviceLink,
                  style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtle, fontWeight: FontWeight.w500)),
              const SizedBox(height: 8),
              TextField(
                controller: _link,
                minLines: 1,
                maxLines: 3,
                keyboardType: TextInputType.url,
                autocorrect: false,
                style: TextStyle(fontFamily: zMonoFamily, fontFamilyFallback: zMonoFallback, fontSize: 13, color: z.foreground),
                decoration: InputDecoration(hintText: s.deviceLinkHint, errorText: _error, errorMaxLines: 3),
              ),
              const SizedBox(height: 8),
              Row(children: [
                OutlinedButton.icon(
                  onPressed: _paste,
                  icon: const Icon(Icons.content_paste_rounded, size: 16),
                  label: Text(s.paste),
                ),
                const SizedBox(width: 8),
                if (_scanSupported)
                  OutlinedButton.icon(
                    onPressed: _scan,
                    icon: const Icon(Icons.qr_code_scanner_rounded, size: 16),
                    label: Text(s.scanQr),
                  ),
              ]),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: z.surface,
                  borderRadius: BorderRadius.circular(ZRadius.xl),
                  border: Border.all(color: z.border),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.info_outline, size: 16, color: z.foregroundSubtle),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(s.deviceLinkHelp,
                        style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtle, height: 1.5)),
                  ),
                ]),
              ),
              const SizedBox(height: 20),
              Text(s.deviceName,
                  style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtle, fontWeight: FontWeight.w500)),
              const SizedBox(height: 8),
              TextField(controller: _name, decoration: const InputDecoration(hintText: 'MacBook')),
              const SizedBox(height: 28),
              FilledButton(onPressed: _saving ? null : _save, child: Text(s.save)),
            ]),
          ),
        ),
      ),
    );
  }
}
