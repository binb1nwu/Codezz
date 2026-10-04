import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Whether the floating surfaces (header, composer, status capsule, sheets)
/// are frosted glass instead of solid.
class GlassScope extends InheritedWidget {
  const GlassScope({super.key, required this.enabled, required super.child});
  final bool enabled;

  static bool of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<GlassScope>()?.enabled ?? false;

  @override
  bool updateShouldNotify(GlassScope old) => old.enabled != enabled;
}

/// How much of a surface's own colour stays in front of the blur.
const glassTint = 0.6;
const glassSigma = 6.0;

/// [color] made see-through for a glass surface; unchanged when glass is off.
Color glassColor(BuildContext context, Color color) =>
    GlassScope.of(context) ? color.withValues(alpha: color.a * glassTint) : color;

/// Blurs whatever is painted behind [child] within [borderRadius] (or
/// [shape]) when glass is on, and paints nothing extra when it is off: the
/// child keeps drawing its own (by then translucent, see [glassColor])
/// background and border.
///
/// Surfaces that never overlap share one blur pass through the app's
/// [BackdropGroup]; pass [grouped] false for ones that sit over other glass
/// (sheets, popovers).
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.borderRadius = BorderRadius.zero,
    this.circle = false,
    this.grouped = true,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final bool circle;
  final bool grouped;

  @override
  Widget build(BuildContext context) {
    if (!GlassScope.of(context)) return child;
    final filter = BackdropFilter(
      filter: ui.ImageFilter.blur(sigmaX: glassSigma, sigmaY: glassSigma),
      backdropGroupKey: grouped ? BackdropGroup.of(context)?.backdropKey : null,
      child: child,
    );
    return circle ? ClipOval(child: filter) : ClipRRect(borderRadius: borderRadius, child: filter);
  }
}

/// Reports [child]'s height after each layout where it changed, so content
/// under a floating surface can leave room for it.
class ReportSize extends SingleChildRenderObjectWidget {
  const ReportSize({super.key, required this.onHeight, super.child});
  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) => RenderReportSize(onHeight);

  @override
  void updateRenderObject(BuildContext context, RenderReportSize renderObject) => renderObject.onHeight = onHeight;
}

class RenderReportSize extends RenderProxyBox {
  RenderReportSize(this.onHeight);
  ValueChanged<double> onHeight;
  double? _reported;

  @override
  void performLayout() {
    super.performLayout();
    final h = size.height;
    if (h == _reported) return;
    _reported = h;
    // Not during layout: listeners rebuild.
    WidgetsBinding.instance.addPostFrameCallback((_) => onHeight(h));
  }
}
