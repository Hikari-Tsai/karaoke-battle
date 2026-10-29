// A mechanical metronome glyph (pyramid case, tilted pendulum with a sliding
// weight). Neither Material Icons nor Font Awesome Free has one.
import 'dart:math' as math;

import 'package:flutter/material.dart';

class MetronomeIcon extends StatelessWidget {
  const MetronomeIcon({super.key, this.size, this.color});
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final s = size ?? theme.size ?? 24;
    final c = color ?? theme.color ?? Colors.white;
    return SizedBox(width: s, height: s, child: CustomPaint(painter: _MetronomePainter(c)));
  }
}

class _MetronomePainter extends CustomPainter {
  _MetronomePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final fill = Paint()..color = color;

    // Case: a narrow-topped pyramid.
    final body = Path()
      ..moveTo(9.6, 2.6)
      ..lineTo(14.4, 2.6)
      ..lineTo(18.6, 19.2)
      ..lineTo(5.4, 19.2)
      ..close();
    canvas.drawPath(body, stroke);
    // Base plate.
    canvas.drawRRect(RRect.fromLTRBR(3.4, 19.0, 20.6, 21.6, const Radius.circular(1.1)), fill);

    // Pendulum swung to the right, reaching past the case.
    const pivot = Offset(12, 16.6);
    const angle = 18 * math.pi / 180;
    const len = 13.6;
    final tip = pivot + Offset(math.sin(angle) * len, -math.cos(angle) * len);
    canvas.drawLine(pivot, tip, stroke..strokeWidth = 1.6);
    // Sliding weight on the arm.
    final w = pivot + Offset(math.sin(angle) * len * 0.45, -math.cos(angle) * len * 0.45);
    canvas.save();
    canvas.translate(w.dx, w.dy);
    canvas.rotate(angle);
    canvas.drawRRect(RRect.fromLTRBR(-1.8, -1.3, 1.8, 1.3, const Radius.circular(0.6)), fill);
    canvas.restore();
    canvas.drawCircle(pivot, 1.3, fill);
  }

  @override
  bool shouldRepaint(_MetronomePainter old) => old.color != color;
}
