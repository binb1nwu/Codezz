import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/v4/ids.dart';
import 'device_registry.dart';
import 'device_session.dart';
import 'log_store.dart';

const appVersion = '1.0.0';

enum AppThemeMode { system, light, dark }

/// How the composer shows the context window: the toolbar ring, or the
/// whole input box filling up like a progress bar.
enum ContextDisplay { ring, bar }

/// Where the 5-hour / weekly coding-plan quota shows: as rings around the
/// composer's context ring, or as small bars next to the device in the
/// header.
enum QuotaPlacement { ring, header }

/// Root application state: linked devices, their live sessions and
/// preferences.
class AppState extends ChangeNotifier with WidgetsBindingObserver {
  AppState();

  final DeviceRegistry registry = DeviceRegistry();
  final LogStore logs = LogStore();
  final Map<String, DeviceSession> _sessions = {};
  late final String clientId;

  AppThemeMode themeMode = AppThemeMode.system;
  double textScale = 1.0;
  ContextDisplay contextDisplay = ContextDisplay.ring;
  QuotaPlacement quotaPlacement = QuotaPlacement.ring;

  /// Frosted-glass header, composer and sheets.
  bool glass = true;

  /// Open task per `device|workspace` (absent: the new task screen), so the
  /// app reopens where it was closed.
  final Map<String, String> selections = {};
  bool ready = false;

  static const _clientIdKey = 'codezz.clientId';
  static const _themeKey = 'codezz.theme';
  static const _scaleKey = 'codezz.textScale';
  static const _contextDisplayKey = 'codezz.contextDisplay';
  static const _quotaPlacementKey = 'codezz.quotaPlacement';
  static const _glassKey = 'codezz.glass';
  static const _selectionsKey = 'codezz.selections';

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    clientId = prefs.getString(_clientIdKey) ?? 'client-${uuidv7()}';
    await prefs.setString(_clientIdKey, clientId);
    themeMode = AppThemeMode.values.firstWhere(
      (m) => m.name == prefs.getString(_themeKey),
      orElse: () => AppThemeMode.system,
    );
    textScale = prefs.getDouble(_scaleKey) ?? 1.0;
    contextDisplay = ContextDisplay.values.firstWhere(
      (d) => d.name == prefs.getString(_contextDisplayKey),
      orElse: () => ContextDisplay.ring,
    );
    quotaPlacement = QuotaPlacement.values.firstWhere(
      (p) => p.name == prefs.getString(_quotaPlacementKey),
      orElse: () => QuotaPlacement.ring,
    );
    glass = prefs.getBool(_glassKey) ?? true;
    try {
      final saved = jsonDecode(prefs.getString(_selectionsKey) ?? '{}');
      if (saved is Map) {
        for (final e in saved.entries) {
          if (e.value is String) selections['${e.key}'] = e.value as String;
        }
      }
    } on FormatException {
      // A corrupt entry only loses the restored page.
    }
    await registry.load();
    registry.addListener(_syncSessions);
    _syncSessions();
    WidgetsBinding.instance.addObserver(this);
    ready = true;
    notifyListeners();
  }

  /// Keeps one [DeviceSession] per linked device; all devices stay connected.
  void _syncSessions() {
    final ids = registry.devices.map((d) => d.id).toSet();
    for (final id in _sessions.keys.toList()) {
      if (!ids.contains(id)) _sessions.remove(id)!.dispose();
    }
    for (final device in registry.devices) {
      final session = _sessions[device.id];
      if (session == null) {
        _sessions[device.id] = DeviceSession(device,
            clientId: clientId, appVersion: appVersion, logs: logs)
          ..start();
      } else if (session.connection.link != device.link) {
        session.relink();
      }
    }
    notifyListeners();
  }

  List<DeviceSession> get sessions =>
      [for (final d in registry.devices) if (_sessions[d.id] != null) _sessions[d.id]!];

  DeviceSession? get activeSession {
    final active = registry.active;
    return active == null ? null : _sessions[active.id];
  }

  DeviceSession? sessionFor(String deviceId) => _sessions[deviceId];

  Future<void> setThemeMode(AppThemeMode mode) async {
    themeMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, mode.name);
  }

  Future<void> setTextScale(double scale) async {
    textScale = scale;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_scaleKey, scale);
  }

  Future<void> setContextDisplay(ContextDisplay display) async {
    contextDisplay = display;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_contextDisplayKey, display.name);
  }

  Future<void> setQuotaPlacement(QuotaPlacement placement) async {
    quotaPlacement = placement;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_quotaPlacementKey, placement.name);
  }

  /// Remembers the open task of `device|workspace` [key] (null: new task).
  Future<void> setSelection(String key, String? taskId) async {
    if (taskId == null ? selections.remove(key) == null : selections[key] == taskId) return;
    if (taskId != null) selections[key] = taskId;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_selectionsKey, jsonEncode(selections));
  }

  Future<void> setGlass(bool value) async {
    glass = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_glassKey, value);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Sockets that lived through sleep / network changes may be dead while
      // still looking open: probe them, reconnect immediately if needed.
      for (final s in _sessions.values) {
        s.connection.verifyAlive();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final s in _sessions.values) {
      s.dispose();
    }
    super.dispose();
  }
}
