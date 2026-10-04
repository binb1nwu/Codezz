import 'package:flutter/material.dart';

import '../l10n.dart';
import '../theme/tokens.dart';
import '../widgets/glass.dart';

/// ZCode's "Scroll to bottom" button: a 28 px outlined circle with an arrow,
/// shown once the reversed timeline is more than 48 px away from the newest
/// message; tapping jumps straight back (no animation, as in ZCode).
class ScrollToBottomButton extends StatefulWidget {
  const ScrollToBottomButton({super.key, required this.controller});
  final ScrollController controller;

  /// Distance from the bottom that counts as "at the bottom".
  static const threshold = 48.0;

  @override
  State<ScrollToBottomButton> createState() => _ScrollToBottomButtonState();
}

class _ScrollToBottomButtonState extends State<ScrollToBottomButton> {
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_update);
  }

  @override
  void didUpdateWidget(covariant ScrollToBottomButton old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_update);
      widget.controller.addListener(_update);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_update);
    super.dispose();
  }

  void _update() {
    final c = widget.controller;
    // The timeline is reversed: offset 0 is the newest message.
    final visible = c.hasClients && c.position.pixels > ScrollToBottomButton.threshold;
    if (visible != _visible) setState(() => _visible = visible);
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    final z = context.z;
    final label = S.of(context).scrollToBottom;
    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (widget.controller.hasClients) widget.controller.jumpTo(0);
          },
          // A 40 px touch target around the 28 px circle.
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Glass(
              circle: true,
              child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: glassColor(context, z.card),
                shape: BoxShape.circle,
                border: Border.all(color: z.border),
                boxShadow: GlassScope.of(context) ? null : const [
                  BoxShadow(color: Color(0x1A000000), blurRadius: 3, offset: Offset(0, 1)),
                  BoxShadow(color: Color(0x1A000000), blurRadius: 2, spreadRadius: -1, offset: Offset(0, 1)),
                ],
              ),
              child: Icon(Icons.arrow_downward_rounded, size: 16, color: z.foreground),
            ),
            ),
          ),
        ),
      ),
    );
  }
}
