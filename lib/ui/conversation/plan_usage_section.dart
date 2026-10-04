import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../state/plan_usage.dart';
import '../l10n.dart';
import '../theme/tokens.dart';
import '../widgets/common.dart';

/// `剩余额度` / `今日余额` of ZCode's usage card: one bar per quota with the
/// remaining share and its reset time.
class PlanUsageSection extends StatelessWidget {
  const PlanUsageSection({super.key, required this.entry, required this.startPlan, this.onRefresh});

  /// Null until the first fetch starts.
  final PlanUsageEntry? entry;
  final bool startPlan;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    final e = entry;
    final snapshot = e?.snapshot;
    final loading = e == null || e.loading;
    final quotas = snapshot?.quotas ?? const <PlanQuota>[];

    Widget body;
    if (snapshot == null && loading) {
      body = Row(children: [
        const ZSpinner(size: 14),
        const SizedBox(width: 8),
        Text(s.planLoading, style: TextStyle(fontSize: ZText.base, color: z.foregroundSubtle)),
      ]);
    } else if (snapshot == null) {
      body = _Notice(message: s.planUpdateFailed, onRefresh: onRefresh);
    } else if (quotas.isEmpty) {
      body = _Notice(message: s.planUnavailable(snapshot.unavailableReason), onRefresh: onRefresh);
    } else {
      body = _QuotaGrid(quotas: quotas, startPlan: startPlan);
    }

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
          child: Text(
            startPlan ? s.startPlanTitle : s.planTitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: ZText.base, fontWeight: FontWeight.w500, color: z.foreground),
          ),
        ),
        if (loading)
          const Padding(padding: EdgeInsets.all(8), child: ZSpinner(size: 14))
        else ...[
          if (snapshot != null && e.error != null)
            Tooltip(
              message: s.planUpdateFailed,
              child: Icon(Icons.warning_amber_rounded, size: 16, color: z.warning),
            ),
          if (onRefresh != null && snapshot != null && quotas.isNotEmpty)
            ZIconButton(icon: Icons.refresh_rounded, iconSize: 16, tooltip: s.planRefresh, onPressed: onRefresh),
        ],
      ]),
      const SizedBox(height: 4),
      body,
    ]);
  }
}

/// `grid gap-2` with up to three columns; the MCP quota spans the width
/// below three primary quotas.
class _QuotaGrid extends StatelessWidget {
  const _QuotaGrid({required this.quotas, required this.startPlan});
  final List<PlanQuota> quotas;
  final bool startPlan;

  @override
  Widget build(BuildContext context) {
    final primary = quotas.where((q) => q.key != 'mcp').toList();
    final mcp = quotas.where((q) => q.key == 'mcp').firstOrNull;
    final wideMcp = mcp != null && primary.length >= 3;
    final tiles = [...primary, if (mcp != null && !wideMcp) mcp];
    return LayoutBuilder(builder: (context, c) {
      const gap = 8.0;
      final columns = math.max(1, math.min(tiles.length, 3));
      final width = (c.maxWidth - gap * (columns - 1)) / columns;
      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: gap, runSpacing: gap, children: [
          for (final q in tiles) SizedBox(width: width, child: _QuotaTile(quota: q, startPlan: startPlan)),
        ]),
        if (wideMcp) _WideMcpRow(quota: mcp, barWidth: width),
      ]);
    });
  }
}

class _QuotaTile extends StatelessWidget {
  const _QuotaTile({required this.quota, required this.startPlan});
  final PlanQuota quota;
  final bool startPlan;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    final reset = quotaResetText(quota, zh: s.zh);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        Flexible(
          child: Text(
            quota.label ?? s.planQuota(quota.key),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtle),
          ),
        ),
        if (quota.key == 'mcp') _McpInfo(),
      ]),
      const SizedBox(height: 2),
      Text.rich(
        TextSpan(children: [
          TextSpan(
            text: quotaPercentText(quota.remaining, wholeOnly: startPlan),
            style: TextStyle(
                fontFamily: zMonoFamily, fontFamilyFallback: zMonoFallback, fontSize: ZText.sm, color: z.foreground),
          ),
          if (reset != null)
            TextSpan(text: ' · $reset', style: TextStyle(fontSize: ZText.xs, color: z.foregroundSubtle)),
        ]),
        maxLines: 1,
        overflow: TextOverflow.fade,
        softWrap: false,
      ),
      const SizedBox(height: 6),
      QuotaBar(remaining: quota.remaining, color: quotaColor(z, quota.key)),
    ]);
  }
}

/// MCP quota under three primary quotas: label left, value and a bar as
/// wide as one column right.
class _WideMcpRow extends StatelessWidget {
  const _WideMcpRow({required this.quota, required this.barWidth});
  final PlanQuota quota;
  final double barWidth;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    final reset = quotaResetText(quota, zh: s.zh);
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.only(top: 6),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: z.border))),
      child: Row(children: [
        Text(s.planQuota('mcp'), style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtle)),
        _McpInfo(),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            [quotaPercentText(quota.remaining), if (reset != null) reset].join(' · '),
            textAlign: TextAlign.right,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtle),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(width: barWidth, child: QuotaBar(remaining: quota.remaining, color: quotaColor(z, 'mcp'))),
      ]),
    );
  }
}

class _McpInfo extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Tooltip(
        message: S.of(context).planMcpDescription,
        triggerMode: TooltipTriggerMode.tap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Icon(Icons.info_outline_rounded, size: 12, color: context.z.foregroundSubtle),
        ),
      );
}

/// `h-1.5` rounded track filled with the remaining share.
class QuotaBar extends StatelessWidget {
  const QuotaBar({super.key, required this.remaining, required this.color});
  final double? remaining;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final share = ((remaining ?? 0) / 100).clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: Container(
        height: 6,
        color: context.z.surfaceHover,
        alignment: Alignment.centerLeft,
        child: LayoutBuilder(builder: (context, c) {
          if (share <= 0) return const SizedBox.shrink();
          return Container(
            width: math.max(c.maxWidth * share, 6),
            height: 6,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
          );
        }),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.message, this.onRefresh});
  final String message;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final z = context.z;
    final s = S.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
      decoration: BoxDecoration(color: z.surface, borderRadius: BorderRadius.circular(ZRadius.lg)),
      child: Row(children: [
        Icon(Icons.warning_amber_rounded, size: 14, color: z.warning),
        const SizedBox(width: 8),
        Expanded(child: Text(message, style: TextStyle(fontSize: ZText.sm, color: z.foregroundSubtle))),
        if (onRefresh != null)
          ZIconButton(icon: Icons.refresh_rounded, iconSize: 16, tooltip: s.planRefresh, onPressed: onRefresh),
      ]),
    );
  }
}

/// Bar colour per quota (`--color-usage-chart-1/2/3/5`).
Color quotaColor(ZTokens z, String key) => switch (key) {
      'fiveHour' => z.usageChart,
      'weekly' || 'balance' => z.success,
      'toolCalls' => z.usageChart3,
      'mcp' => z.warning,
      _ => z.usageChart,
    };

/// `NN%`, one decimal below 10%; `--` when unknown. Start-plan balances are
/// always whole percents.
String quotaPercentText(double? percent, {bool wholeOnly = false}) {
  if (percent == null) return '--';
  final digits = wholeOnly || percent >= 10 ? 0 : 1;
  var text = percent.toStringAsFixed(digits);
  if (text.contains('.')) text = text.replaceFirst(RegExp(r'\.?0+$'), '');
  return '$text%';
}

/// The 5-hour window resets at `HH:mm`; longer ones on a day (`10月7日` /
/// `Oct 7`); a start-plan balance at `HH:mm` today, else on a day.
String? quotaResetText(PlanQuota q, {required bool zh, DateTime? now}) {
  final t = q.resetAt;
  if (t == null) return null;
  String hm() => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  String day() {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return zh ? '${t.month}月${t.day}日' : '${months[t.month - 1]} ${t.day}';
  }

  if (q.key == 'fiveHour') return hm();
  if (q.key == 'balance') {
    final n = now ?? DateTime.now();
    return n.year == t.year && n.month == t.month && n.day == t.day ? hm() : day();
  }
  return day();
}

