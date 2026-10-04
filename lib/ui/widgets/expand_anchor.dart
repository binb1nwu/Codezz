import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Runs [change] (an expand / collapse) keeping the expandable widget of
/// [context] where it is on screen, so its new content opens downwards.
///
/// The timeline is a reversed list anchored at the newest message: a
/// growing row would push itself and everything above it up. [context] must
/// be the state of a widget whose build returns an [ExpandAnchor], inside a
/// list scrolled with [AnchoredScrollPhysics]; anywhere else this just runs
/// [change].
void toggleInPlace(BuildContext context, VoidCallback change) {
  final box = context.findRenderObject();
  if (box is RenderExpandAnchor) box.armed = true;
  change();
}

/// Scroll offset owed to anchors that changed size in this layout pass.
class ScrollCorrection {
  double _pending = 0;

  void add(double delta) {
    if (_pending == 0) {
      // Never carry a correction into a later, unrelated layout.
      WidgetsBinding.instance.addPostFrameCallback((_) => _pending = 0);
    }
    _pending += delta;
  }

  double take() {
    final d = _pending;
    _pending = 0;
    return d;
  }
}

/// Physics that apply [correction] while the viewport settles its new
/// content dimensions. Returning a different offset there makes the viewport
/// lay out again in the same frame, so an anchored row never paints in the
/// position it was pushed to.
class AnchoredScrollPhysics extends ScrollPhysics {
  const AnchoredScrollPhysics({super.parent, required this.correction});
  final ScrollCorrection correction;

  @override
  AnchoredScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      AnchoredScrollPhysics(parent: buildParent(ancestor), correction: correction);

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    final base = super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
    final delta = correction.take();
    if (delta == 0) return base;
    return (base + delta).clamp(newPosition.minScrollExtent, newPosition.maxScrollExtent);
  }
}

/// Marks the top edge to hold still in [toggleInPlace]: when it changes
/// height right after being armed, it owes the list's [AnchoredScrollPhysics]
/// that height so the content above stays put.
class ExpandAnchor extends SingleChildRenderObjectWidget {
  const ExpandAnchor({super.key, super.child});

  @override
  RenderExpandAnchor createRenderObject(BuildContext context) => RenderExpandAnchor(Scrollable.maybeOf(context));

  @override
  void updateRenderObject(BuildContext context, RenderExpandAnchor renderObject) =>
      renderObject.scrollable = Scrollable.maybeOf(context);
}

class RenderExpandAnchor extends RenderProxyBox {
  RenderExpandAnchor(this.scrollable);

  ScrollableState? scrollable;
  bool armed = false;

  @override
  void performLayout() {
    final before = hasSize ? size.height : null;
    super.performLayout();
    if (!armed) return;
    armed = false;
    final scrollable = this.scrollable;
    if (before == null || scrollable == null || !scrollable.mounted) return;
    // Only an upward (reversed) list moves what is above a growing child.
    if (scrollable.axisDirection != AxisDirection.up) return;
    final position = scrollable.position;
    final physics = position.physics;
    if (!position.hasPixels || physics is! AnchoredScrollPhysics) return;
    final delta = size.height - before;
    if (delta.abs() < 0.5) return;
    physics.correction.add(delta);
    // Makes the viewport re-check its dimensions, which applies the
    // correction through the physics.
    position.correctBy(0);
  }
}
