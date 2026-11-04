// A small speech bubble over an icon, e.g. "Update" on the rail's Settings.
import 'package:flutter/material.dart';

class SpeechBubbleBadge extends StatelessWidget {
  const SpeechBubbleBadge({super.key, required this.text, required this.child, this.show = true});
  final String text;
  final Widget child;
  final bool show;

  @override
  Widget build(BuildContext context) {
    if (!show) return child;
    final cs = Theme.of(context).colorScheme;
    return Stack(clipBehavior: Clip.none, children: [
      child,
      // Centred above the icon, its tail pointing down at it; kept within the
      // rail's width, since the page beside the rail would cover it.
      Positioned(
        left: -40,
        right: -40,
        bottom: 19,
        child: IgnorePointer(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: cs.tertiary, borderRadius: BorderRadius.circular(8)),
              child: Text(
                text,
                maxLines: 1,
                softWrap: false,
                style: TextStyle(color: cs.onTertiary, fontSize: 10, fontWeight: FontWeight.w700, height: 1.2),
              ),
            ),
            CustomPaint(size: const Size(8, 4), painter: _Tail(cs.tertiary)),
          ]),
        ),
      ),
    ]);
  }
}

class _Tail extends CustomPainter {
  const _Tail(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_Tail old) => old.color != color;
}
