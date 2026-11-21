// The profile's cartoon singer, chibi style: a big, round, softly shaded
// head on a short neck, big sparkly anime eyes and hatched blush, singing
// into a microphone. The head bobs to the
// beat, the mouth follows a sung line with pauses, the eyes blink and notes
// float up. Three people (female, male, neutral) and four small animals
// (cat, dog, rabbit, bear), each with its own colours. [headOnly] draws just
// the head, still, for the sidebar button and the look picker.
import 'dart:math' as math;

import 'package:flutter/material.dart';

enum AvatarKind {
  female,
  male,
  neutral,
  cat,
  dog,
  rabbit,
  bear;

  bool get human => index <= AvatarKind.neutral.index;
}

/// The saved look (setting 'avatar_gender'); anything unknown is female.
AvatarKind avatarKindOf(String value) => AvatarKind.values.firstWhere((k) => k.name == value, orElse: () => AvatarKind.female);

class SingingAvatar extends StatefulWidget {
  const SingingAvatar({super.key, required this.kind, this.size = 260, this.headOnly = false, this.animated = true});
  final AvatarKind kind;
  final double size;
  final bool headOnly;
  final bool animated;

  @override
  State<SingingAvatar> createState() => _SingingAvatarState();
}

class _SingingAvatarState extends State<SingingAvatar> with SingleTickerProviderStateMixin {
  late final _ticker = createTicker((elapsed) => setState(() => _t = elapsed.inMicroseconds / 1e6));
  double _t = 0.8; // a moment with the mouth open, for the still version

  @override
  void initState() {
    super.initState();
    if (widget.animated) _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: CustomPaint(
          size: Size.square(widget.size),
          painter: _AvatarPainter(t: _t, kind: widget.kind, headOnly: widget.headOnly, animated: widget.animated),
        ),
      );
}

/// Colours of a look: skin or fur (light, base, shade), hair, top, accent.
class _Look {
  const _Look({
    required this.light,
    required this.base,
    required this.shade,
    required this.top,
    required this.topDark,
    required this.accent,
    this.hairDark = const Color(0xFF000000),
    this.hairLight = const Color(0xFF000000),
    this.inner = const Color(0xFFFF9FB5),
    this.iris = const Color(0xFF5A3A2A),
  });
  final Color light, base, shade, top, topDark, accent, hairDark, hairLight, inner;

  /// The lower half of the eyes (anime eyes fade from dark to this).
  final Color iris;

  static const _skin = (Color(0xFFFFE6D2), Color(0xFFF8C9A6), Color(0xFFDDA07C));

  static _Look of(AvatarKind k) => switch (k) {
        AvatarKind.female => _Look(light: _skin.$1, base: _skin.$2, shade: _skin.$3, hairDark: const Color(0xFF3A1F45), hairLight: const Color(0xFF8A4C8F), top: const Color(0xFFFF7AB8), topDark: const Color(0xFFC2367E), accent: const Color(0xFFFFD60A), iris: const Color(0xFFC05AD8)),
        AvatarKind.male => _Look(light: _skin.$1, base: _skin.$2, shade: _skin.$3, hairDark: const Color(0xFF1E2235), hairLight: const Color(0xFF4E5A86), top: const Color(0xFF5AB0FF), topDark: const Color(0xFF2A5FC2), accent: const Color(0xFF64D2FF), iris: const Color(0xFF3F7FE0)),
        AvatarKind.neutral => _Look(light: _skin.$1, base: _skin.$2, shade: _skin.$3, hairDark: const Color(0xFF4A2C1C), hairLight: const Color(0xFFA0683E), top: const Color(0xFF5AD6B4), topDark: const Color(0xFF248C70), accent: const Color(0xFF30D158), iris: const Color(0xFF2FA383)),
        AvatarKind.cat => const _Look(light: Color(0xFFFFE2BE), base: Color(0xFFFFB066), shade: Color(0xFFD9822F), top: Color(0xFFBF8CFF), topDark: Color(0xFF7A4FD0), accent: Color(0xFFBF5AF2), iris: Color(0xFF3FAE5A)),
        AvatarKind.dog => const _Look(light: Color(0xFFFFF6E8), base: Color(0xFFF6D9B0), shade: Color(0xFFCFA06C), hairDark: Color(0xFF7A4A26), hairLight: Color(0xFFC0844E), top: Color(0xFFFF7A6A), topDark: Color(0xFFC8463A), accent: Color(0xFFFF9F0A)),
        AvatarKind.rabbit => const _Look(light: Color(0xFFFFFFFF), base: Color(0xFFF1ECF7), shade: Color(0xFFC9C0D9), top: Color(0xFF7FD8FF), topDark: Color(0xFF3A9AD0), accent: Color(0xFF64D2FF), iris: Color(0xFFE0507A)),
        AvatarKind.bear => const _Look(light: Color(0xFFD49A66), base: Color(0xFFA86B3C), shade: Color(0xFF6E4220), top: Color(0xFFFFD45A), topDark: Color(0xFFD49A1A), accent: Color(0xFFFFD60A), inner: Color(0xFFE2B98C)),
      };
}

class _AvatarPainter extends CustomPainter {
  _AvatarPainter({required this.t, required this.kind, required this.headOnly, required this.animated}) : look = _Look.of(kind);
  final double t;
  final AvatarKind kind;
  final bool headOnly;
  final bool animated;
  final _Look look;

  /// The head-only view: a little higher for the rabbit's ears.
  Offset get _headCentre => kind == AvatarKind.rabbit ? const Offset(100, 80) : const Offset(100, 92);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    // Drawn in a 200 x 200 space; the head-only version shows its middle.
    if (headOnly) {
      final c = _headCentre;
      canvas.scale(size.width / 124);
      canvas.translate(62 - c.dx, 62 - c.dy);
    } else {
      canvas.scale(size.width / 200);
    }
    final clip = headOnly ? (Path()..addOval(Rect.fromCircle(center: _headCentre, radius: 62))) : (Path()..addOval(const Rect.fromLTWH(0, 0, 200, 200)));
    canvas.clipPath(clip);
    _background(canvas);

    // Singing: the beat, the head's bob and tilt, the mouth and the blinks.
    final beat = 2 * math.pi * t / 1.2;
    final bob = animated ? 2.6 * math.sin(beat) : 0.0;
    final tilt = animated ? 0.07 * math.sin(beat / 2) : 0.0;
    final sway = animated ? 1.6 * math.sin(beat / 2 + 0.6) : 0.0;
    final phrase = t % 4.0; // sings for 3.4 s, then breathes
    final singing = !animated || phrase < 3.4;
    final mouth = singing ? (0.35 + 0.65 * (math.sin(2 * math.pi * t * 2.2).abs()) * (0.65 + 0.35 * math.sin(2 * math.pi * t * 0.7))) : 0.12;
    final eyes = animated && (t % 3.2) < 0.13 ? 0.12 : 1.0;

    final longHair = kind == AvatarKind.female;
    if (!headOnly) {
      canvas.save();
      canvas.translate(sway, 0);
      if (longHair) _backHair(canvas, bob, tilt);
      _body(canvas);
      canvas.restore();
    } else if (longHair) {
      _backHair(canvas, 0, 0);
    }

    // The head turns about the neck.
    canvas.save();
    canvas.translate(sway, bob);
    canvas.translate(100, 140);
    canvas.rotate(tilt);
    canvas.translate(-100, -140);
    _head(canvas, mouth, eyes);
    canvas.restore();

    if (!headOnly) {
      canvas.save();
      canvas.translate(sway, bob * 0.5);
      _microphone(canvas);
      canvas.restore();
      if (animated) _notes(canvas);
    }
    canvas.restore();

    // A ring of light round the badge.
    final r = size.width / 2;
    canvas.drawCircle(
      Offset(r, r),
      r - 1.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = headOnly ? 1.5 : 3
        ..shader = SweepGradient(colors: [look.accent, look.top, const Color(0xFFBF5AF2), look.accent]).createShader(Rect.fromCircle(center: Offset(r, r), radius: r)),
    );
  }

  void _background(Canvas canvas) {
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 200, 200),
      Paint()
        ..shader = const RadialGradient(center: Alignment(0, -0.35), radius: 0.9, colors: [Color(0xFF5B2E86), Color(0xFF2A1646), Color(0xFF140B22)], stops: [0, 0.55, 1])
            .createShader(const Rect.fromLTWH(0, 0, 200, 200)),
    );
    // A stage light from above.
    final beam = Path()
      ..moveTo(84, 0)
      ..lineTo(116, 0)
      ..lineTo(170, 200)
      ..lineTo(30, 200)
      ..close();
    canvas.drawPath(
      beam,
      Paint()
        ..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.white.withValues(alpha: 0.13), Colors.white.withValues(alpha: 0)])
            .createShader(const Rect.fromLTWH(30, 0, 140, 200)),
    );
  }

  Paint _shaded(Rect r, {Alignment light = const Alignment(-0.35, -0.45)}) =>
      Paint()..shader = RadialGradient(center: light, radius: 0.95, colors: [look.light, look.base, look.shade], stops: const [0, 0.6, 1]).createShader(r);

  Paint get _hairPaint => Paint()..shader = LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [look.hairLight, look.hairDark]).createShader(const Rect.fromLTWH(48, 38, 104, 140));

  void _backHair(Canvas canvas, double bob, double tilt) {
    canvas.save();
    canvas.translate(0, bob * 0.6);
    canvas.translate(100, 140);
    canvas.rotate(tilt * 0.6);
    canvas.translate(-100, -140);
    final hair = Path()
      ..moveTo(52, 92)
      ..quadraticBezierTo(50, 40, 100, 38)
      ..quadraticBezierTo(150, 40, 148, 92)
      ..quadraticBezierTo(152, 150, 140, 168)
      ..quadraticBezierTo(120, 176, 100, 172)
      ..quadraticBezierTo(80, 176, 60, 168)
      ..quadraticBezierTo(48, 150, 52, 92)
      ..close();
    canvas.drawPath(hair, _hairPaint);
    canvas.restore();
  }

  void _body(Canvas canvas) {
    // Chibi proportions: the shoulders sit right under the chin, so only a
    // little neck shows.
    canvas.save();
    canvas.translate(0, -8);
    _bodyShape(canvas);
    canvas.restore();
  }

  void _bodyShape(Canvas canvas) {
    // Neck (a little wider for the animals' furry ones).
    final neck = kind.human ? const Rect.fromLTWH(89, 132, 22, 22) : const Rect.fromLTWH(85, 130, 30, 24);
    canvas.drawRRect(
      RRect.fromRectAndRadius(neck, const Radius.circular(9)),
      Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [look.shade, look.base]).createShader(neck),
    );
    final top = Path()
      ..moveTo(34, 205)
      ..quadraticBezierTo(36, 160, 74, 150)
      ..quadraticBezierTo(100, 162, 126, 150)
      ..quadraticBezierTo(164, 160, 166, 205)
      ..close();
    canvas.drawPath(
      top,
      Paint()..shader = RadialGradient(center: const Alignment(-0.3, -0.6), radius: 1.1, colors: [look.top, look.topDark]).createShader(const Rect.fromLTWH(34, 148, 132, 58)),
    );
    // Collar.
    final collar = Path()
      ..moveTo(84, 151)
      ..quadraticBezierTo(100, 172, 116, 151)
      ..quadraticBezierTo(100, 162, 84, 151)
      ..close();
    canvas.drawPath(collar, Paint()..color = Colors.white.withValues(alpha: 0.85));
    // The puppy's name tag.
    if (kind == AvatarKind.dog) {
      const tag = Offset(100, 165);
      canvas.drawCircle(tag, 5.5, Paint()..shader = const RadialGradient(center: Alignment(-0.4, -0.4), colors: [Color(0xFFFFF3A6), Color(0xFFF9D84A), Color(0xFFC98A1A)]).createShader(Rect.fromCircle(center: tag, radius: 5.5)));
      canvas.drawCircle(tag + const Offset(-1.6, -1.8), 1.4, Paint()..color = Colors.white.withValues(alpha: 0.8));
    }
  }

  void _head(Canvas canvas, double mouth, double eyes) {
    const c = Offset(100, 92);
    // Shadow under the chin.
    canvas.drawOval(Rect.fromCenter(center: const Offset(100, 134), width: 56, height: 12), Paint()..color = Colors.black.withValues(alpha: 0.18));

    // What sits behind the face.
    switch (kind) {
      case AvatarKind.female || AvatarKind.male || AvatarKind.neutral:
        for (final x in [56.0, 144.0]) {
          canvas.drawCircle(Offset(x, 96), 9, Paint()..color = look.shade);
          canvas.drawCircle(Offset(x, 96), 5, Paint()..color = look.base);
        }
      case AvatarKind.cat:
        for (final s in [-1.0, 1.0]) {
          final ear = Path()
            ..moveTo(100 + s * 18, 54)
            ..lineTo(100 + s * 40, 34)
            ..lineTo(100 + s * 44, 74)
            ..close();
          canvas.drawPath(ear, _shaded(Rect.fromLTWH(s < 0 ? 52 : 116, 30, 34, 48)));
          final inner = Path()
            ..moveTo(100 + s * 24, 58)
            ..lineTo(100 + s * 38, 44)
            ..lineTo(100 + s * 40, 68)
            ..close();
          canvas.drawPath(inner, Paint()..color = look.inner);
        }
      case AvatarKind.rabbit:
        for (final s in [-1.0, 1.0]) {
          canvas.save();
          canvas.translate(100 + s * 18, 58);
          canvas.rotate(s * 0.18);
          final ear = RRect.fromRectAndRadius(const Rect.fromLTWH(-10, -50, 20, 56), const Radius.circular(10));
          canvas.drawRRect(ear, _shaded(ear.outerRect));
          canvas.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(-5, -43, 10, 42), const Radius.circular(5)), Paint()..color = look.inner);
          canvas.restore();
        }
      case AvatarKind.bear:
        for (final x in [64.0, 136.0]) {
          canvas.drawCircle(Offset(x, 56), 15, _shaded(Rect.fromCircle(center: Offset(x, 56), radius: 15)));
          canvas.drawCircle(Offset(x, 56), 8, Paint()..color = look.inner);
        }
      case AvatarKind.dog:
        break; // its ears hang over the face, below
    }

    // Face, lit from the top left; a little wider at the cheeks.
    final face = Rect.fromCenter(center: c + const Offset(0, 1), width: 94, height: 90);
    canvas.drawOval(face, _shaded(face));

    // Muzzle and markings.
    final muzzle = kind == AvatarKind.dog || kind == AvatarKind.bear;
    if (kind == AvatarKind.bear) {
      canvas.drawOval(Rect.fromCenter(center: const Offset(100, 114), width: 40, height: 26), Paint()..color = look.inner);
    }
    if (kind == AvatarKind.dog) {
      canvas.drawOval(Rect.fromCenter(center: const Offset(100, 113), width: 32, height: 22), Paint()..color = look.light);
      // A caramel patch round one eye.
      canvas.drawOval(Rect.fromCenter(center: const Offset(118, 96), width: 22, height: 22), Paint()..color = look.hairLight.withValues(alpha: 0.7));
    }
    if (kind == AvatarKind.cat) {
      final stripe = Paint()
        ..color = look.shade
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(const Offset(100, 52), const Offset(100, 62), stripe);
      canvas.drawLine(const Offset(91, 54), const Offset(93, 62), stripe);
      canvas.drawLine(const Offset(109, 54), const Offset(107, 62), stripe);
    }

    // Blush: soft pink with the little slanted lines of anime cheeks.
    for (final x in [73.0, 127.0]) {
      canvas.drawOval(Rect.fromCenter(center: Offset(x, 110), width: 18, height: 10), Paint()..color = const Color(0xFFFF6F91).withValues(alpha: 0.35));
      final hatch = Paint()
        ..color = const Color(0xFFFF4F7E).withValues(alpha: 0.55)
        ..strokeWidth = 1.1
        ..strokeCap = StrokeCap.round;
      for (var i = -1; i <= 1; i++) {
        canvas.drawLine(Offset(x + i * 4.2 + 1.4, 107.6), Offset(x + i * 4.2 - 1.4, 112.4), hatch);
      }
    }

    // Big anime eyes: dark at the top fading to the look's colour, a thick
    // upper lash line, two catch lights. A blink is a happy closed arc.
    for (final (i, x) in [83.0, 117.0].indexed) {
      const y = 97.0;
      if (eyes < 0.5) {
        canvas.drawArc(
          Rect.fromCenter(center: Offset(x, y + 2), width: 14, height: 9),
          math.pi * 1.1,
          math.pi * 0.8,
          false,
          Paint()
            ..color = const Color(0xFF2A1B2E)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.4
            ..strokeCap = StrokeCap.round,
        );
        continue;
      }
      final eye = Rect.fromCenter(center: Offset(x, y), width: 13, height: 18);
      canvas.drawOval(eye, Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [const Color(0xFF241628), Color.lerp(const Color(0xFF241628), look.iris, 0.55)!, look.iris], stops: const [0, 0.45, 1]).createShader(eye));
      // The pupil's soft glow at the bottom.
      canvas.drawOval(Rect.fromCenter(center: Offset(x, y + 5), width: 7, height: 4), Paint()..color = Colors.white.withValues(alpha: 0.22));
      // Upper lash line, a flick at the outer corner.
      final lash = Paint()
        ..color = const Color(0xFF1A0F1E)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(Rect.fromCenter(center: Offset(x, y + 0.5), width: 15, height: 19), math.pi * 1.08, math.pi * 0.84, false, lash);
      final out = i == 0 ? -1.0 : 1.0;
      if (kind == AvatarKind.female) {
        canvas.drawLine(Offset(x + out * 6.6, y - 4.5), Offset(x + out * 9.4, y - 7), lash..strokeWidth = 1.8);
      }
      canvas.drawOval(Rect.fromCenter(center: Offset(x - 2.4, y - 3.6), width: 5.2, height: 6.2), Paint()..color = Colors.white);
      canvas.drawCircle(Offset(x + 2.6, y + 3.8), 1.5, Paint()..color = Colors.white.withValues(alpha: 0.9));
    }

    // Brows (people): thin and high, raised as if mid-note.
    if (kind.human) {
      final brow = Paint()
        ..color = look.hairDark
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(Rect.fromCenter(center: const Offset(83, 83), width: 12, height: 6), math.pi * 1.15, math.pi * 0.7, false, brow);
      canvas.drawArc(Rect.fromCenter(center: const Offset(117, 83), width: 12, height: 6), math.pi * 1.15, math.pi * 0.7, false, brow);
    }

    // Nose.
    switch (kind) {
      case AvatarKind.female || AvatarKind.male || AvatarKind.neutral:
        // Just a dot of shade.
        canvas.drawCircle(const Offset(100, 108), 1.3, Paint()..color = look.shade);
      case AvatarKind.cat || AvatarKind.rabbit:
        final nose = Path()
          ..moveTo(96, 106)
          ..lineTo(104, 106)
          ..lineTo(100, 110)
          ..close();
        canvas.drawPath(nose, Paint()..color = const Color(0xFFFF7A9A));
      case AvatarKind.dog || AvatarKind.bear:
        canvas.drawOval(Rect.fromCenter(center: const Offset(100, 107), width: 12, height: 8), Paint()..color = const Color(0xFF2A1B22));
        canvas.drawOval(Rect.fromCenter(center: const Offset(97.5, 105.3), width: 3.6, height: 2.2), Paint()..color = Colors.white.withValues(alpha: 0.6));
    }

    // Whiskers.
    if (kind == AvatarKind.cat || kind == AvatarKind.rabbit) {
      final w = Paint()
        ..color = const Color(0xFF6B4A3A).withValues(alpha: 0.55)
        ..strokeWidth = 1.2
        ..strokeCap = StrokeCap.round;
      for (final s in [-1.0, 1.0]) {
        // Out past the blush, to the edge of the face.
        canvas.drawLine(Offset(100 + s * 34, 112), Offset(100 + s * 52, 108), w);
        canvas.drawLine(Offset(100 + s * 34, 115), Offset(100 + s * 52, 118), w);
      }
    }

    // The singing mouth.
    final my = muzzle ? 119.0 : 117.0;
    final m = Rect.fromCenter(center: Offset(100, my + mouth * 1.6), width: 9 + 5 * mouth, height: 2.6 + 10 * mouth);
    canvas.drawOval(m, Paint()..color = const Color(0xFF7A1F3A));
    if (mouth > 0.3) {
      canvas.save();
      canvas.clipPath(Path()..addOval(m));
      canvas.drawRect(Rect.fromLTWH(m.left, m.top, m.width, 2.4), Paint()..color = Colors.white);
      canvas.drawOval(Rect.fromCenter(center: Offset(100, m.bottom - 2), width: m.width * 0.7, height: m.height * 0.45), Paint()..color = const Color(0xFFFF7A8A));
      canvas.restore();
    }

    // The puppy's floppy ears: from the top of the head, hanging outwards.
    if (kind == AvatarKind.dog) {
      for (final s in [-1.0, 1.0]) {
        canvas.save();
        canvas.translate(100 + s * 36, 58);
        // Clockwise turns the bottom left: the left ear (s < 0) turns
        // clockwise, the right one the other way, so both hang outwards.
        canvas.rotate(-s * 0.5);
        final ear = Rect.fromCenter(center: const Offset(0, 20), width: 26, height: 42);
        canvas.drawOval(ear, Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [look.hairLight, look.hairDark]).createShader(ear));
        canvas.drawOval(Rect.fromCenter(center: const Offset(0, 22), width: 12, height: 26), Paint()..color = Colors.white.withValues(alpha: 0.12));
        canvas.restore();
      }
    }

    // Hair (people).
    if (kind.human) _frontHair(canvas);

    // A soft highlight on the top of the head, for roundness.
    canvas.drawOval(Rect.fromCenter(center: const Offset(84, 60), width: 30, height: 12), Paint()..color = Colors.white.withValues(alpha: 0.18));
  }

  void _frontHair(Canvas canvas) {
    final paint = _hairPaint;
    switch (kind) {
      case AvatarKind.female:
        // Swept bangs and locks framing the face.
        final bangs = Path()
          ..moveTo(54, 96)
          ..quadraticBezierTo(50, 46, 100, 44)
          ..quadraticBezierTo(150, 46, 146, 96)
          ..quadraticBezierTo(138, 72, 118, 66)
          ..quadraticBezierTo(112, 80, 96, 82)
          ..quadraticBezierTo(102, 72, 98, 66)
          ..quadraticBezierTo(76, 74, 66, 92)
          ..quadraticBezierTo(64, 108, 66, 132)
          ..quadraticBezierTo(54, 118, 54, 96)
          ..close();
        canvas.drawPath(bangs, paint);
        final right = Path()
          ..moveTo(146, 96)
          ..quadraticBezierTo(146, 118, 136, 132)
          ..quadraticBezierTo(138, 110, 134, 90)
          ..close();
        canvas.drawPath(right, paint);
        _star(canvas, const Offset(130, 62), 7, look.accent);
      case AvatarKind.male:
        // Short hair with a spiky fringe.
        final hair = Path()
          ..moveTo(55, 90)
          ..quadraticBezierTo(48, 44, 100, 42)
          ..quadraticBezierTo(152, 44, 145, 90)
          ..lineTo(138, 74)
          ..lineTo(130, 84)
          ..lineTo(122, 68)
          ..lineTo(110, 78)
          ..lineTo(100, 64)
          ..lineTo(88, 76)
          ..lineTo(78, 66)
          ..lineTo(70, 82)
          ..lineTo(62, 72)
          ..close();
        canvas.drawPath(hair, paint);
      case AvatarKind.neutral:
        // A chin-length bob with a side part.
        final bob = Path()
          ..moveTo(52, 118)
          ..quadraticBezierTo(46, 46, 100, 42)
          ..quadraticBezierTo(154, 46, 148, 118)
          ..quadraticBezierTo(146, 126, 138, 124)
          ..quadraticBezierTo(142, 92, 130, 72)
          ..quadraticBezierTo(110, 80, 84, 70)
          ..quadraticBezierTo(64, 84, 62, 124)
          ..quadraticBezierTo(54, 126, 52, 118)
          ..close();
        canvas.drawPath(bob, paint);
      default:
        return;
    }
    // A shine across the hair.
    canvas.drawArc(
      Rect.fromCenter(center: const Offset(98, 64), width: 60, height: 30),
      math.pi * 1.1,
      math.pi * 0.45,
      false,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.28)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
  }

  void _microphone(Canvas canvas) {
    // The handle, from the hand up towards the chin.
    final handle = Path()
      ..moveTo(128, 124)
      ..lineTo(134, 121)
      ..lineTo(147, 170)
      ..lineTo(139, 173)
      ..close();
    canvas.drawPath(handle, Paint()..shader = const LinearGradient(colors: [Color(0xFF2C2C34), Color(0xFF6A6A78), Color(0xFF2C2C34)]).createShader(const Rect.fromLTWH(128, 120, 20, 54)));
    // The hand, or paw.
    canvas.drawCircle(const Offset(142, 158), 11, _shaded(Rect.fromCircle(center: const Offset(142, 158), radius: 11), light: const Alignment(-0.4, -0.4)));
    // The grille: a metal ball with a mesh and a glint.
    const head = Offset(129, 117);
    canvas.drawCircle(head, 10, Paint()..shader = const RadialGradient(center: Alignment(-0.4, -0.5), colors: [Color(0xFFF2F2F7), Color(0xFF9A9AAA), Color(0xFF4A4A58)], stops: [0, 0.55, 1]).createShader(Rect.fromCircle(center: head, radius: 10)));
    final mesh = Paint()
      ..color = Colors.black.withValues(alpha: 0.22)
      ..strokeWidth = 0.8;
    for (var d = -6.0; d <= 6; d += 3) {
      canvas.drawLine(head + Offset(d, -8), head + Offset(d, 8), mesh);
      canvas.drawLine(head + Offset(-8, d), head + Offset(8, d), mesh);
    }
    canvas.drawCircle(head + const Offset(-3.5, -4), 2.4, Paint()..color = Colors.white.withValues(alpha: 0.9));
  }

  void _notes(Canvas canvas) {
    const colors = [Color(0xFFFFD60A), Color(0xFFFF4FA3), Color(0xFF64D2FF)];
    for (var i = 0; i < 3; i++) {
      final p = ((t + i * 0.9) % 2.7) / 2.7;
      final pos = Offset(148 + 26 * p + 5 * math.sin(p * 6 + i), 108 - 78 * p);
      final a = (p < 0.15 ? p / 0.15 : 1 - (p - 0.15) / 0.85).clamp(0.0, 1.0);
      _note(canvas, pos, 0.8 + 0.3 * math.sin(i + p * 3), colors[i].withValues(alpha: a));
    }
  }

  void _note(Canvas canvas, Offset at, double scale, Color color) {
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.scale(scale);
    canvas.rotate(-0.3);
    final paint = Paint()..color = color;
    canvas.drawOval(Rect.fromCenter(center: Offset.zero, width: 9, height: 6.5), paint);
    canvas.drawRect(const Rect.fromLTWH(3, -16, 1.8, 16), paint);
    final flag = Path()
      ..moveTo(4.8, -16)
      ..quadraticBezierTo(12, -12, 9, -5)
      ..quadraticBezierTo(10, -10, 4.8, -11)
      ..close();
    canvas.drawPath(flag, paint);
    canvas.restore();
  }

  void _star(Canvas canvas, Offset c, double r, Color color) {
    final path = Path();
    for (var i = 0; i < 10; i++) {
      final rr = i.isEven ? r : r * 0.45;
      final a = -math.pi / 2 + i * math.pi / 5;
      final p = c + Offset(rr * math.cos(a), rr * math.sin(a));
      i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8,
    );
  }

  @override
  bool shouldRepaint(_AvatarPainter old) => old.t != t || old.kind != kind || old.headOnly != headOnly;
}
