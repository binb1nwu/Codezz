import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../state/app_state.dart';
import '../../state/plan_usage.dart';
import '../l10n.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';
import 'plan_usage_section.dart';

/// Order of `breakdown` sources when their sizes tie (`Tz` in ZCode).
const _sourceOrder = [
  'messages',
  'system_prompt',
  'meta_user_context',
  'skills',
  'tool_prompt',
  'system_tool_schemas',
  'mcp_tool_schemas',
];

/// ZCode hides the cache hit rate below this value.
const _hitRateThreshold = 0.78;

class ContextSource {
  const ContextSource(this.source, this.chars, this.percent);
  final String source;
  final int chars;

  /// Share of all breakdown characters, 0‥1.
  final double percent;

  @override
  bool operator ==(Object other) => other is ContextSource && other.source == source && other.chars == chars;
  @override
  int get hashCode => Object.hash(source, chars);
}

/// `usage.contextWindow` of a V4 conversation, as the composer's context
/// ring shows it.
class ContextUsage {
  const ContextUsage({
    required this.used,
    required this.size,
    this.hitRate,
    this.breakdown = const [],
  });

  final int used;
  final int size;
  final double? hitRate;
  final List<ContextSource> breakdown;

  double get ratio => (used / size).clamp(0.0, 1.0);

  @override
  bool operator ==(Object other) =>
      other is ContextUsage &&
      other.used == used &&
      other.size == size &&
      other.hitRate == hitRate &&
      listEquals(other.breakdown, breakdown);
  @override
  int get hashCode => Object.hash(used, size, hitRate, Object.hashAll(breakdown));

  /// Null until the session has reported a non-empty context window.
  static ContextUsage? fromUsage(Map<String, dynamic> usage) {
    final window = usage['contextWindow'];
    if (window is! Map) return null;
    final used = window['usedTokens'];
    final size = window['maxTokens'];
    if (used is! num || size is! num || !used.isFinite || !size.isFinite || used <= 0 || size <= 0) {
      return null;
    }
    final cache = window['cache'];
    final hitRate = cache is Map ? cache['hitRate'] : null;
    return ContextUsage(
      used: used.round(),
      size: size.round(),
      hitRate: hitRate is num && hitRate.isFinite ? hitRate.toDouble() : null,
      breakdown: _breakdown(window['breakdown']),
    );
  }

  static List<ContextSource> _breakdown(Object? raw) {
    final chars = <String, int>{};
    if (raw is List) {
      for (final e in raw) {
        if (e is! Map || e['source'] is! String || e['chars'] is! num) continue;
        final n = (e['chars'] as num).round();
        if (n > 0) chars.update(e['source'] as String, (v) => v + n, ifAbsent: () => n);
      }
    }
    final total = chars.values.fold<int>(0, (a, b) => a + b);
    if (total <= 0) return const [];
    int order(String s) {
      final i = _sourceOrder.indexOf(s);
      return i < 0 ? _sourceOrder.length : i;
    }

    return [for (final e in chars.entries) ContextSource(e.key, e.value, e.value / total)]
      ..sort((a, b) => b.chars != a.chars ? b.chars - a.chars : order(a.source) - order(b.source));
  }
}

/// `Intl.NumberFormat` compact notation as ZCode uses it for token counts:
/// `71.5K` / `200K`, or `7.2万` / `20万` in Chinese.
String compactCount(num value, {required bool zh, int fractionDigits = 1}) {
  final units = zh ? const [(1e4, '万'), (1e8, '亿')] : const [(1e3, 'K'), (1e6, 'M'), (1e9, 'B'), (1e12, 'T')];
  final abs = value.abs();
  if (abs < units.first.$1) return _fixed(value, fractionDigits);
  var i = units.lastIndexWhere((u) => abs >= u.$1);
  // 999.96K rounds to 1000K; Intl shows it in the next unit (1M).
  if (i + 1 < units.length &&
      double.parse(_fixed(abs / units[i].$1, fractionDigits)) >= units[i + 1].$1 / units[i].$1) {
    i++;
  }
  return '${_fixed(value / units[i].$1, fractionDigits)}${units[i].$2}';
}

/// `71,505`.
String groupedCount(int value) =>
    value.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

/// Percent with at most one fraction digit: `35.8%`, `12%`.
String percentText(double ratio) => '${_fixed(ratio * 100, 1)}%';

String _fixed(num v, int digits) {
  var s = v.toStringAsFixed(digits);
  if (s.contains('.')) s = s.replaceFirst(RegExp(r'\.?0+$'), '');
  return s == '-0' ? '0' : s;
}

/// `71.5K/200K (35.8%)`.
String contextUsageSummary(ContextUsage u, {required bool zh}) =>
    '${compactCount(u.used, zh: zh)}/${compactCount(u.size, zh: zh, fractionDigits: 0)} (${percentText(u.ratio)})';

/// Swatch colours of the breakdown: the chart colour mixed into [surface].
List<Color> contextSwatches(ZTokens z, Color surface) => [
      for (final p in const [1.0, 0.78, 0.58, 0.42, 0.28]) Color.lerp(surface, z.usageChart, p)!,
    ];

/// One ring of [ContextRing]: its filled share (0‥1) and colour.
class RingValue {
  const RingValue(this.value, this.color);
  final double value;
  final Color color;

  @override
  bool operator ==(Object other) => other is RingValue && other.value == value && other.color == color;
  @override
  int get hashCode => Object.hash(value, color);
}

/// The composer's usage ring.
///
/// Alone it is ZCode's context meter (the used share). With a coding plan it
/// becomes concentric rings, outermost first, each showing what is left:
/// weekly quota, 5-hour quota (or a start plan's balance), then context.
class ContextRing extends StatelessWidget {
  const ContextRing({super.key, required double ratio, this.size = 17, Color? color})
      : _ratio = ratio,
        _color = color,
        rings = null;

  const ContextRing.concentric({super.key, required List<RingValue> this.rings, this.size = 20})
      : _ratio = 0,
        _color = null;

  final double _ratio;
  final Color? _color;
  final List<RingValue>? rings;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: CustomPaint(
          painter: _RingPainter(rings ?? [RingValue(_ratio, _color ?? context.z.foregroundSubtle)]),
        ),
      );
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.rings);
  final List<RingValue> rings;

  @override
  void paint(Canvas canvas, Size size) {
    // ZCode's SVG: viewBox 24, r 10, stroke 4. More rings share the same
    // box, outermost first, each radius one stroke inside the previous so
    // the bands touch without a gap.
    final scale = size.shortestSide / 24;
    final center = size.center(Offset.zero);
    final (List<double> radii, double stroke) = switch (rings.length) {
      1 => (const [10.0], 4.0),
      2 => (const [10.25, 7.5], 2.75),
      _ => (const [10.5, 8.25, 6.0], 2.25),
    };
    for (var i = 0; i < rings.length && i < radii.length; i++) {
      _ring(canvas, center, radii[i] * scale, stroke * scale, rings[i].value.clamp(0.0, 1.0), rings[i].color);
    }
  }

  void _ring(Canvas canvas, Offset center, double radius, double stroke, double value, Color color) {
    final rect = Rect.fromCircle(center: center, radius: radius);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawOval(rect, paint..color = color.withValues(alpha: color.a * 0.25));
    if (value <= 0) return;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      2 * math.pi * value,
      false,
      paint
        ..color = color.withValues(alpha: color.a * 0.85)
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => !listEquals(old.rings, rings);
}

/// The composer's usage card: the context window (`chat.contextUsage.*`)
/// and, for coding-plan providers, the remaining quota
/// (`sidebar.usage.plan.*`).
class ContextUsageCard extends StatelessWidget {
  const ContextUsageCard({super.key, this.usage, this.plan});
  final ContextUsage? usage;
  final Widget? plan;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final usage = this.usage;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (usage != null) _ContextSection(usage: usage),
        if (plan != null)
          Container(
            margin: EdgeInsets.only(top: usage == null ? 0 : 12),
            padding: EdgeInsets.only(top: usage == null ? 0 : 12),
            decoration: usage == null ? null : BoxDecoration(border: Border(top: BorderSide(color: z.border))),
            child: plan,
          ),
      ]),
    );
  }
}

/// Usage, a bar split by source, the per-source shares and the cache hit
/// rate.
class _ContextSection extends StatelessWidget {
  const _ContextSection({required this.usage});
  final ContextUsage usage;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    final swatches = contextSwatches(z, z.popover);
    Color swatch(int i) => swatches[math.min(i, swatches.length - 1)];
    const mono = TextStyle(fontFamily: zMonoFamily, fontFamilyFallback: zMonoFallback, fontSize: ZText.sm);
    final hitRate = usage.hitRate != null && usage.hitRate! >= _hitRateThreshold ? usage.hitRate : null;
    final breakdown = usage.breakdown;

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text(s.contextUsageTitle,
              style: TextStyle(fontSize: ZText.base, fontWeight: FontWeight.w500, color: z.foreground)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              contextUsageSummary(usage, zh: s.zh),
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: mono.copyWith(color: z.foregroundSubtle),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        _UsageBar(usage: usage, swatch: swatch),
        if (breakdown.isNotEmpty) ...[
          const SizedBox(height: 12),
          for (var i = 0; i < breakdown.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: swatch(i),
                    borderRadius: BorderRadius.circular(2),
                    border: Border.all(color: z.border),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(s.contextSource(breakdown[i].source),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtle)),
                ),
                Text(percentText(breakdown[i].percent), style: mono.copyWith(color: z.foreground)),
              ]),
            ),
        ],
        if (hitRate != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: EdgeInsets.only(top: breakdown.isEmpty ? 0 : 12),
            decoration: breakdown.isEmpty
                ? null
                : BoxDecoration(border: Border(top: BorderSide(color: z.border))),
            child: Row(children: [
              Expanded(
                child: Text(s.cacheHitRate, style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtle)),
              ),
              Text(percentText(hitRate), style: mono.copyWith(color: z.foreground)),
            ]),
          ),
        ],
    ]);
  }
}

/// `h-2` track with the used share filled, split into source segments.
class _UsageBar extends StatelessWidget {
  const _UsageBar({required this.usage, required this.swatch});
  final ContextUsage usage;
  final Color Function(int) swatch;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final segments = usage.breakdown;
    return ClipRRect(
      borderRadius: BorderRadius.circular(ZRadius.md),
      child: Container(
        height: 8,
        color: z.surface,
        alignment: Alignment.centerLeft,
        child: LayoutBuilder(builder: (context, c) {
          final width = math.max(c.maxWidth * usage.ratio, 8.0);
          return ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              width: width,
              height: 8,
              child: segments.isEmpty
                  ? ColoredBox(color: z.primary)
                  : Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      for (var i = 0; i < segments.length; i++)
                        SizedBox(width: width * segments[i].percent, child: ColoredBox(color: swatch(i))),
                    ]),
            ),
          );
        }),
      ),
    );
  }
}

/// Opens the usage card; it follows [usage] and [plans] while open. The
/// quota of [planProvider] is fetched on opening, as ZCode does.
Future<void> showContextUsage(
  BuildContext context,
  ValueListenable<ContextUsage?> usage, {
  PlanUsageStore? plans,
  String? planProvider,
}) {
  final plan = plans != null && planProvider != null ? planProvider : null;
  if (plan != null) unawaited(plans!.access(plan));
  return showZSheet<void>(context, builder: (ctx) {
    return ListenableBuilder(
      listenable: Listenable.merge([usage, if (plan != null) plans]),
      builder: (ctx, _) => ContextUsageCard(
        usage: usage.value,
        plan: plan == null
            ? null
            : PlanUsageSection(
                entry: plans!.entry(plan),
                startPlan: plan.endsWith('-start-plan'),
                onRefresh: () => plans.refresh(plan),
              ),
      ),
    );
  });
}

/// Hands the user's [ContextDisplay] and [QuotaPlacement] preferences down
/// to the composers.
class ContextDisplayScope extends InheritedWidget {
  const ContextDisplayScope({
    super.key,
    required this.display,
    this.quotas = QuotaPlacement.ring,
    required super.child,
  });
  final ContextDisplay display;
  final QuotaPlacement quotas;

  static ContextDisplay of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ContextDisplayScope>()?.display ?? ContextDisplay.ring;

  static QuotaPlacement quotasOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ContextDisplayScope>()?.quotas ?? QuotaPlacement.ring;

  @override
  bool updateShouldNotify(ContextDisplayScope old) => old.display != display || old.quotas != quotas;
}

/// A [ValueListenable] over usage that lives elsewhere, e.g. a conversation
/// store the header reads when it opens the usage card.
class DerivedUsage implements ValueListenable<ContextUsage?> {
  DerivedUsage(this.source, this.read);
  final Listenable source;
  final ContextUsage? Function() read;

  @override
  ContextUsage? get value => read();
  @override
  void addListener(VoidCallback listener) => source.addListener(listener);
  @override
  void removeListener(VoidCallback listener) => source.removeListener(listener);
}

final _noUsage = ValueNotifier<ContextUsage?>(null);

/// `5h ▰▰▱ 98%  周 ▰▰▱ 99%` after the device in the header: the coding-plan
/// quota of the composer on screen, in the composer rings' colours. Tapping
/// opens the same usage card as the ring, with the conversation's context
/// from [usage] when a task is open.
class HeaderPlanQuota extends StatelessWidget {
  const HeaderPlanQuota({super.key, required this.plans, this.usage});
  final PlanUsageStore plans;
  final ValueListenable<ContextUsage?> Function()? usage;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: plans,
      builder: (context, _) {
        final z = context.z;
        final s = S.of(context);
        final provider = plans.shown;
        final snapshot = provider == null ? null : plans.entry(provider)?.snapshot;
        if (snapshot == null || !snapshot.active) return const SizedBox.shrink();
        final quotas = [
          snapshot.ringQuota,
          snapshot.quotas.where((q) => q.key == 'weekly').firstOrNull,
        ].whereType<PlanQuota>();
        final style = TextStyle(
            fontSize: ZText.xs, color: z.foregroundSubtle, fontFeatures: const [FontFeature.tabularFigures()]);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => showContextUsage(context, usage?.call() ?? _noUsage,
              plans: plans, planProvider: provider),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            for (final q in quotas) ...[
              const SizedBox(width: 10),
              Text(s.planQuotaShort(q.key), style: style),
              const SizedBox(width: 4),
              QuotaMiniBar(
                remaining: (q.remaining ?? 0) / 100,
                color: quotaColor(z, q.key == 'weekly' ? 'weekly' : 'fiveHour'),
              ),
              const SizedBox(width: 4),
              Text(quotaPercentText(q.remaining, wholeOnly: true), style: style),
            ],
          ]),
        );
      },
    );
  }
}

/// 18×4 track with the remaining share filled.
class QuotaMiniBar extends StatelessWidget {
  const QuotaMiniBar({super.key, required this.remaining, required this.color});
  final double remaining;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: Container(
        width: 18,
        height: 4,
        color: color.withValues(alpha: 0.25),
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: remaining.clamp(0.0, 1.0),
          heightFactor: 1,
          child: ColoredBox(color: color.withValues(alpha: 0.85)),
        ),
      ),
    );
  }
}
