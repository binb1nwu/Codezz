import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/link/device_link.dart';
import '../core/v4/ids.dart';
import 'credential_cipher.dart';

/// A linked ZCode desktop (remote-control relay link or ZCode Web server).
class Device {
  Device({
    required this.id,
    required this.link,
    this.label,
    required this.addedAt,
    this.lastWorkspacePath,
  });

  final String id;
  DeviceLink link;

  /// User given name; falls back to the server's name, then the host.
  String? label;
  final int addedAt;
  String? lastWorkspacePath;

  Map<String, Object?> toJson(String storedLink) => {
        'id': id,
        'link': storedLink,
        if (label != null) 'label': label,
        'addedAt': addedAt,
        if (lastWorkspacePath != null) 'lastWorkspacePath': lastWorkspacePath,
      };
}

/// Persisted list of linked devices. Links carry the server token, so on
/// Android they are encrypted with the Keystore (see [CredentialCipher]).
class DeviceRegistry extends ChangeNotifier {
  static const _prefsKey = 'codezz.devices.v2';
  static const _activeKey = 'codezz.activeDevice.v2';

  final List<Device> _devices = [];
  List<Device> get devices => List.unmodifiable(_devices);

  String? _activeId;
  String? get activeId => _activeId;
  Device? get active {
    for (final d in _devices) {
      if (d.id == _activeId) return d;
    }
    return _devices.isEmpty ? null : _devices.first;
  }

  bool loaded = false;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _devices.clear();
    final raw = prefs.getString(_prefsKey);
    if (raw != null) {
      try {
        for (final item in jsonDecode(raw) as List) {
          if (item is! Map) continue;
          var stored = '${item['link'] ?? ''}';
          if (CredentialCipher.isEncrypted(stored)) {
            final plain = await CredentialCipher.decrypt(stored);
            if (plain == null) continue; // key lost (reinstall): re-link needed
            stored = plain;
          }
          final link = DeviceLink.tryParse(stored);
          if (link == null) continue;
          _devices.add(Device(
            id: '${item['id'] ?? uuidv4()}',
            link: link,
            label: item['label'] as String?,
            addedAt: (item['addedAt'] as num?)?.toInt() ?? 0,
            lastWorkspacePath: item['lastWorkspacePath'] as String?,
          ));
        }
      } catch (e) {
        debugPrint('device registry corrupt: $e');
      }
    }
    _activeId = prefs.getString(_activeKey);
    loaded = true;
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final out = <Map<String, Object?>>[];
    for (final d in _devices) {
      final canonical = d.link.canonical;
      out.add(d.toJson(await CredentialCipher.encrypt(canonical) ?? canonical));
    }
    await prefs.setString(_prefsKey, jsonEncode(out));
    if (_activeId != null) {
      await prefs.setString(_activeKey, _activeId!);
    } else {
      await prefs.remove(_activeKey);
    }
  }

  Device? findByLink(DeviceLink link) {
    for (final d in _devices) {
      if (d.link.identity == link.identity) return d;
    }
    return null;
  }

  /// Adds a device, or updates the link of an already linked desktop (remote
  /// links rotate, and every `zcode --web` start prints a new token).
  Future<Device> addOrUpdate(DeviceLink link, {String? label}) async {
    final existing = findByLink(link);
    if (existing != null) {
      existing.link = link;
      if (label != null && label.trim().isNotEmpty) existing.label = label.trim();
      _activeId = existing.id;
      await _save();
      notifyListeners();
      return existing;
    }
    final device = Device(
      id: uuidv4(),
      link: link,
      label: label?.trim().isEmpty ?? true ? null : label!.trim(),
      addedAt: DateTime.now().millisecondsSinceEpoch,
    );
    _devices.add(device);
    _activeId = device.id;
    await _save();
    notifyListeners();
    return device;
  }

  Future<void> updateLink(Device device, DeviceLink link) async {
    device.link = link;
    await _save();
    notifyListeners();
  }

  Future<void> rename(Device device, String? label) async {
    device.label = label?.trim().isEmpty ?? true ? null : label!.trim();
    await _save();
    notifyListeners();
  }

  Future<void> setActive(Device device) async {
    if (_activeId == device.id) return;
    _activeId = device.id;
    await _save();
    notifyListeners();
  }

  Future<void> rememberWorkspace(Device device, String path) async {
    if (device.lastWorkspacePath == path) return;
    device.lastWorkspacePath = path;
    await _save();
  }

  Future<void> remove(Device device) async {
    _devices.removeWhere((d) => d.id == device.id);
    if (_activeId == device.id) _activeId = _devices.isEmpty ? null : _devices.first.id;
    await _save();
    notifyListeners();
  }

  Future<void> reorder(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex--;
    final d = _devices.removeAt(oldIndex);
    _devices.insert(newIndex, d);
    await _save();
    notifyListeners();
  }
}
