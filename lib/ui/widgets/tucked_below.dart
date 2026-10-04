import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Lays [top] out above [child] with [child] pulled up by [overlap] px and
/// painted over it: ZCode tucks the message queue under the composer
/// (`-mb-7 pb-7`).
class TuckedBelow extends StatelessWidget {
  const TuckedBelow({super.key, required this.top, required this.child});
  final Widget? top;
  final Widget child;

  static const overlap = 28.0;

  @override
  Widget build(BuildContext context) {
    final top = this.top;
    if (top == null) return child;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [top, PullUp(by: overlap, child: child)],
    );
  }
}

/// Reports its child [by] px shorter and paints / hit-tests it [by] px
/// higher, so it overlaps whatever is laid out above it.
class PullUp extends SingleChildRenderObjectWidget {
  const PullUp({super.key, required this.by, required super.child});
  final double by;

  @override
  RenderObject createRenderObject(BuildContext context) => RenderPullUp(by);

  @override
  void updateRenderObject(BuildContext context, RenderPullUp renderObject) => renderObject.by = by;
}

class RenderPullUp extends RenderProxyBox {
  RenderPullUp(this._by);

  double _by;
  set by(double value) {
    if (value == _by) return;
    _by = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final child = this.child!;
    child.layout(constraints.loosen().copyWith(minWidth: constraints.minWidth), parentUsesSize: true);
    size = constraints.constrain(Size(child.size.width, math.max(0, child.size.height - _by)));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    context.paintChild(child!, offset.translate(0, -_by));
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (position.dx < 0 || position.dx > size.width || position.dy < -_by || position.dy > size.height) {
      return false;
    }
    if (hitTestChildren(result, position: position)) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    return false;
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) => result.addWithPaintOffset(
        offset: Offset(0, -_by),
        position: position,
        hitTest: (result, transformed) => child!.hitTest(result, position: transformed),
      );

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) => transform.translateByDouble(0, -_by, 0, 1);
}

