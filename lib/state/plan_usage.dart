import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/zcode/zcode_api.dart';

/// `accountAccess` of a coding-plan provider id
/// (`account:<family>-<planKind>`), or null for other providers. Team plans
/// need organisation ids the model config does not carry, so they are not
/// supported.
Map<String, Object?>? planAccountAccess(String providerId) {
  final m = RegExp(r'^account:(zai|bigmodel)-(individual-coding-plan|start-plan)$').firstMatch(providerId);
  if (m == null) return null;
  return {'type': 'zhipu-account', 'family': m[1], 'planKind': m[2]};
}

/// One quota bar: what is left of a limit and when it resets.
class PlanQuota {
  const PlanQuota({required this.key, this.label, this.remaining, this.resetAt});

  /// `fiveHour`, `weekly`, `toolCalls`, `mcp`, or `balance` (start plan).
  final String key;

  /// Only for `balance` rows: the models the balance covers.
  final String? label;

  /// Remaining share in percent (0‥100); null when the server gave none.
  final double? remaining;
  final DateTime? resetAt;
}

/// `usage-stats.getEntitlementSnapshot` for one provider, reduced to the
/// rows ZCode's composer card shows.
class PlanSnapshot {
  const PlanSnapshot({
    this.active = false,
    this.unavailableReason,
    this.quotas = const [],
    this.startPlan = false,
  });

  factory PlanSnapshot.fromJson(Map<String, dynamic> json, String providerId) {
    final quota = json['quota'] is Map ? json['quota'] as Map : const {};
    final limits = [
      for (final l in quota['limits'] is List ? quota['limits'] as List : const []) if (l is Map) l,
    ];
    final reason = json['unavailableReason'] as String?;
    final provider = json['provider'] is Map ? (json['provider'] as Map)['id'] : null;
    final active = provider == providerId &&
        reason != 'no_plan' &&
        (json['quota'] != null || json['subscription'] != null || json['remaining'] != null);
    final startPlan = providerId.endsWith('-start-plan');
    final quotas = <PlanQuota>[];
    if (startPlan) {
      for (final l in limits) {
        final total = _num(l['number']) ?? _num(l['unit']) ?? 0;
        final left = _num(l['remaining']) ?? 0;
        if (total <= 0 && left <= 0) continue;
        quotas.add(PlanQuota(
          key: 'balance',
          label: _limitLabel(l),
          remaining: total > 0 ? (left / total * 100).clamp(0.0, 100.0) : 0,
          resetAt: _time(l['nextResetTime']),
        ));
      }
    } else {
      void add(String key, Map? l) {
        if (l != null) quotas.add(PlanQuota(key: key, remaining: _remaining(l), resetAt: _time(l['nextResetTime'])));
      }

      add('fiveHour', _find(limits, 'TOKENS_LIMIT', 3, 5));
      add('weekly', _find(limits, 'TOKENS_LIMIT', 6));
      add('toolCalls', _find(limits, 'TIME_LIMIT', 5, 1));
      final mcp = json['mcpQuota'] is Map ? (json['mcpQuota'] as Map)['aggregate'] : null;
      add('mcp', mcp is Map ? mcp : null);
    }
    return PlanSnapshot(
      active: active,
      unavailableReason: reason,
      quotas: quotas,
      startPlan: startPlan,
    );
  }

  final bool active;
  final String? unavailableReason;
  final List<PlanQuota> quotas;
  final bool startPlan;

  /// The quota the composer's ring shows: the 5-hour window, or today's
  /// balance on a start plan.
  PlanQuota? get ringQuota {
    for (final q in quotas) {
      if (q.key == 'fiveHour' || q.key == 'balance') return q;
    }
    return null;
  }

  static double? _num(Object? v) => v is num && v.isFinite ? v.toDouble() : null;

  static DateTime? _time(Object? v) {
    if (v is num && v.isFinite) return DateTime.fromMillisecondsSinceEpoch(v.toInt());
    if (v is String) return DateTime.tryParse(v)?.toLocal();
    return null;
  }

  /// `100 - percentage`: the server reports the used share.
  static double? _remaining(Map l) {
    final used = _num(l['percentage']);
    return used == null ? null : (100 - used).clamp(0.0, 100.0);
  }

  /// TOKENS_LIMIT and CREDIT_LIMIT are the same kind of limit.
  static bool _sameType(Object? a, String b) {
    const tokens = {'TOKENS_LIMIT', 'CREDIT_LIMIT'};
    return a == b || (tokens.contains(b) && tokens.contains(a));
  }

  static Map? _find(List<Map> limits, String type, int unit, [int? number]) {
    for (final l in limits) {
      if (_sameType(l['type'], type) && l['unit'] == unit && (number == null || l['number'] == number)) return l;
    }
    return null;
  }

  static String _limitLabel(Map l) {
    final names = [
      for (final d in l['usageDetails'] is List ? l['usageDetails'] as List : const [])
        if (d is Map) _modelName(((d['displayName'] as String?)?.trim().isNotEmpty ?? false)
            ? d['displayName'] as String
            : '${d['modelCode'] ?? ''}'.replaceFirst(RegExp('^model:', caseSensitive: false), '').toUpperCase()),
    ].where((n) => n.isNotEmpty).toList();
    return names.isEmpty ? '${l['type'] ?? ''}' : names.join(' / ');
  }

  /// `glm-5-turbo` → `GLM-5-Turbo`, as ZCode normalises plan model names.
  static String _modelName(String raw) {
    final t = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (RegExp(r'^GLM-\S+$', caseSensitive: false).hasMatch(t)) {
      final parts = t.split('-');
      return [
        for (var i = 0; i < parts.length; i++)
          i == 0 ? 'GLM' : (parts[i].toLowerCase() == 'turbo' ? 'Turbo' : parts[i]),
      ].join('-');
    }
    return t.replaceAll(RegExp('[_-]+'), ' ');
  }
}

class PlanUsageEntry {
  PlanSnapshot? snapshot;
  bool loading = false;
  Object? error;
  DateTime? fetchedAt;
  DateTime? retryAfter;
  int failures = 0;
}

/// Coding-plan quota per provider, fetched the way ZCode's composer does:
/// on opening the card (reusing a snapshot younger than a minute, backing
/// off after failures) and on an explicit refresh.
class PlanUsageStore extends ChangeNotifier {
  PlanUsageStore(this._api, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  final ZCodeApi? Function() _api;
  final DateTime Function() _now;
  final Map<String, PlanUsageEntry> _entries = {};

  static const _fresh = Duration(minutes: 1);
  static const _backoff = [30, 60, 120, 300];

  PlanUsageEntry? entry(String providerId) => _entries[providerId];

  /// The plan provider of the composer on screen (null when its model is not
  /// on a coding plan), so the header can show the same quotas.
  String? get shown => _shown;
  String? _shown;
  set shown(String? providerId) {
    if (providerId == _shown) return;
    _shown = providerId;
    notifyListeners();
  }

  /// The card was opened, or (with a longer [maxAge]) the composer's ring
  /// wants a value to show.
  Future<void> access(String providerId, {Duration maxAge = _fresh}) {
    final e = _entries[providerId];
    final now = _now();
    if (e != null) {
      if (e.loading) return Future.value();
      if (e.fetchedAt != null && now.difference(e.fetchedAt!) < maxAge) return Future.value();
      if (e.retryAfter != null && now.isBefore(e.retryAfter!)) return Future.value();
    }
    return refresh(providerId);
  }

  Future<void> refresh(String providerId) async {
    final access = planAccountAccess(providerId);
    final api = _api();
    if (access == null || api == null) return;
    final e = _entries.putIfAbsent(providerId, PlanUsageEntry.new);
    if (e.loading) return;
    e.loading = true;
    notifyListeners();
    try {
      e.snapshot = PlanSnapshot.fromJson(await api.entitlementSnapshot(providerId, access), providerId);
      e
        ..error = null
        ..failures = 0
        ..retryAfter = null
        ..fetchedAt = _now();
    } catch (err) {
      e
        ..error = err
        ..retryAfter = _now().add(Duration(seconds: _backoff[e.failures.clamp(0, _backoff.length - 1)]))
        ..failures = e.failures + 1;
    } finally {
      e.loading = false;
      notifyListeners();
    }
  }
}
