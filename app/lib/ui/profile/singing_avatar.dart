// The profile's cartoon singer, mascot style: a thick plum outline, flat
// colour, a wide bean of a head with dot eyes and blush, the microphone held
// in both hands under the chin. The head bobs to the beat, the mouth follows
// a sung line with pauses, the eyes blink, tails wag and notes float up.
// Three people (female, male, neutral) and four small animals (cat, dog,
// rabbit, bear), each with its own colours. [headOnly] draws just the head,
// still, for the sidebar button and the look picker.
//
// The same art as assets/avatars (drawn there as SVG and PNG): the shapes
// below are those SVG paths, in the same 200 x 200 space.
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
  double _t = 0.8;

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

const _ink = Color(0xFF3B2140);
const _skin = Color(0xFFFFE3CF);
const _skinShade = Color(0xFFF6C5AB);
const _pink = Color(0xFFFF9DB0);

/// Colours of a look: skin or fur, hair (people) or markings (animals), the
/// top, the eyes' glint of colour, the accent and the second note.
class _Palette {
  const _Palette({
    required this.body,
    required this.top,
    required this.topDark,
    required this.iris,
    required this.accent,
    required this.note,
    this.hair = _ink,
    this.hairDark = _ink,
    this.hairLight = _ink,
    this.furDark = _ink,
    this.furLight = _ink,
    this.blush = _pink,
  });
  final Color body, top, topDark, iris, accent, note, hair, hairDark, hairLight, furDark, furLight, blush;

  static const _blue = Color(0xFF64D2FF);
  static const _rose = Color(0xFFFF4FA3);
  static const _warmBlush = Color(0xFFFF8FA3);

  static _Palette of(AvatarKind k) => switch (k) {
        AvatarKind.female => const _Palette(body: _skin, hair: Color(0xFF7A428A), hairDark: Color(0xFF5A2E69), hairLight: Color(0xFFA064B0), top: Color(0xFFFF7AB8), topDark: Color(0xFFE0559A), iris: Color(0xFFC77BE0), accent: Color(0xFFFFD60A), note: _blue),
        AvatarKind.male => const _Palette(body: _skin, hair: Color(0xFF3D4877), hairDark: Color(0xFF272E50), hairLight: Color(0xFF6474B0), top: Color(0xFF5AB0FF), topDark: Color(0xFF3A8CE6), iris: Color(0xFF6FB0FF), accent: _blue, note: _blue),
        AvatarKind.neutral => const _Palette(body: _skin, hair: Color(0xFF94592F), hairDark: Color(0xFF6E4022), hairLight: Color(0xFFBC8250), top: Color(0xFF5AD6B4), topDark: Color(0xFF36B692), iris: Color(0xFF4CCBA6), accent: Color(0xFF30D158), note: _rose),
        AvatarKind.cat => const _Palette(body: Color(0xFFFFB36B), furDark: Color(0xFFEE8F3A), furLight: Color(0xFFFFE4C4), top: Color(0xFFB88CFF), topDark: Color(0xFF9366E8), iris: Color(0xFF5FCB7A), accent: Color(0xFFBF5AF2), note: _rose, blush: _warmBlush),
        AvatarKind.dog => const _Palette(body: Color(0xFFFBE3C0), furDark: Color(0xFFB97A45), furLight: Color(0xFFFFF6E8), top: Color(0xFFFF7A6A), topDark: Color(0xFFE0554A), iris: Color(0xFFC98A52), accent: Color(0xFFFF9F0A), note: _blue),
        AvatarKind.rabbit => const _Palette(body: Color(0xFFF8F4FC), furDark: Color(0xFFDDD3EC), furLight: Color(0xFFFFFFFF), top: Color(0xFF7FD8FF), topDark: Color(0xFF4FB8E8), iris: Color(0xFFF0668E), accent: _blue, note: _rose),
        AvatarKind.bear => const _Palette(body: Color(0xFFB87A48), furDark: Color(0xFF8E5A30), furLight: Color(0xFFEBC79C), top: Color(0xFFFFD45A), topDark: Color(0xFFE8B030), iris: Color(0xFFD69A60), accent: Color(0xFFFFD60A), note: _blue, blush: _warmBlush),
      };
}

/// SVG path data (absolute M, L, C, Q and Z only) as a [Path].
Path _svg(String d) {
  final path = Path();
  final tokens = RegExp(r'[MLCQZ]|-?\d*\.?\d+').allMatches(d).map((m) => m[0]!).toList();
  var i = 0;
  var cmd = '';
  double n() => double.parse(tokens[i++]);
  while (i < tokens.length) {
    final token = tokens[i];
    if (token.length == 1 && 'MLCQZ'.contains(token)) {
      cmd = token;
      i++;
      if (cmd == 'Z') path.close();
      continue;
    }
    switch (cmd) {
      case 'M':
        path.moveTo(n(), n());
        cmd = 'L';
      case 'L':
        path.lineTo(n(), n());
      case 'C':
        path.cubicTo(n(), n(), n(), n(), n(), n());
      case 'Q':
        path.quadraticBezierTo(n(), n(), n(), n());
      default:
        i++;
    }
  }
  return path;
}

// The shapes. Those of one side (an ear, a collar flap) are the right-hand
// one; the left is its mirror image about x = 100.
final _head = _svg('M100,33 C142,33 160,56 160,86 C160,118 136,135 100,135 C64,135 40,118 40,86 C40,56 58,33 100,33 Z');

final _femaleBack = _svg(
    'M100,16 C146,16 170,48 168,92 C167,118 174,138 180,154 C183,164 170,172 160,166 C155,175 140,174 137,164 L63,164 C60,174 45,175 40,166 C30,172 17,164 20,154 C26,138 33,118 32,92 C30,48 54,16 100,16 Z');
final _femaleBackShort = _svg(
    'M100,16 C146,16 170,48 168,92 C167,110 171,124 175,136 C178,146 166,153 157,147 C153,156 140,155 138,146 L62,146 C60,155 47,156 43,147 C34,153 22,146 25,136 C29,124 33,110 32,92 C30,48 54,16 100,16 Z');
final _femaleFringe = _svg('M33,98 C28,46 54,16 100,16 C146,16 172,46 167,98 C167,108 162,116 155,122 C155,102 151,84 143,71 '
    'C134,80 119,84 104,82 C108,76 109,70 108,63 C96,76 75,84 57,82 C50,93 46,106 45,122 C38,116 33,108 33,98 Z');
final _femaleShine = _svg('M56,40 C68,28 92,22 112,24 C96,30 78,36 64,50 C60,52 54,46 56,40 Z');
final _maleFringe = _svg('M34,98 C27,46 54,15 100,15 C146,15 173,46 166,98 L158,108 C157,96 154,86 150,77 '
    'C148,81 144,84 139,86 C138,79 135,72 130,66 C128,74 123,80 116,84 C114,77 111,70 106,63 '
    'C104,73 99,80 91,84 C89,77 85,70 80,65 C78,73 73,81 65,86 C63,81 60,77 56,73 C50,84 45,96 42,108 Z');
final _maleTuft = _svg('M95,18 C96,9 105,3 116,4 C110,8 108,13 110,18 Z');
final _maleShine = _svg('M54,42 C66,29 88,22 108,24 C94,30 76,36 62,50 C58,52 52,48 54,42 Z');
final _neutralBack = _svg('M100,16 C146,16 172,46 170,96 C170,116 166,132 158,142 L42,142 C34,132 30,116 30,96 C28,46 54,16 100,16 Z');
final _neutralFringe = _svg('M30,100 C26,46 54,16 100,16 C146,16 174,46 170,100 C170,116 166,130 158,142 C158,116 154,92 146,74 '
    'C126,84 96,82 78,63 C72,75 60,82 50,84 C46,98 43,118 42,142 C34,130 30,116 30,100 Z');
final _neutralShine = _svg('M112,24 C128,26 142,34 150,48 C152,54 146,58 142,54 C134,42 124,34 110,30 Z');

final _catEar = _svg('M152,56 C154,36 152,22 146,12 C132,16 118,26 112,42 Z');
final _catEarInner = _svg('M144,46 C146,36 145,28 142,22 C134,25 126,32 122,42 Z');
final _catStripes = _svg('M100,30 L100,52 M84,32 L86,48 M116,32 L114,48');
final _catCheekStripes = _svg('M40,84 L52,86 M40,96 L50,96 M160,84 L148,86 M160,96 L150,96');
final _catTail = _svg('M130,192 C162,196 178,172 164,150');
final _catTailStripes = _svg('M171,160 L160,157 M173,170 L162,170');
final _whiskers = _svg('M48,108 L27,103 M48,115 L28,119 M152,108 L173,103 M152,115 L172,119');
final _dogEar = _svg('M142,40 C160,32 182,48 183,78 C184,100 174,118 160,118 C148,118 145,102 145,86 C145,70 141,56 134,46 Z');
final _dogEarShine = _svg('M162,56 C170,66 172,82 168,98');
final _dogTuft = _svg('M91,36 C91,29 97,26 100,30 C103,25 110,28 109,36');
final _dogTail = _svg('M134,188 C150,186 160,176 160,164');
final _rabbitEar = _svg('M-13,6 C-17,-18 -13,-44 0,-56 C13,-44 17,-18 13,6 Z');
final _rabbitEarInner = _svg('M-6,-2 C-8.6,-18 -6,-34 0,-44 C6,-34 8.6,-18 6,-2 Z');
final _rabbitBow = _svg('M133,42 C119,30 117,50 133,42 C147,29 151,48 133,42 Z');

final _hood = _svg('M63,148 C63,130 137,130 137,148 C126,156 74,156 63,148 Z');
final _body = _svg('M74,128 L126,128 L128,138 C136,160 140,182 142,206 L58,206 C60,182 64,160 72,138 Z');
final _bodyShade = _svg('M124,150 C130,168 134,186 136,206 L142,206 C140,182 136,160 128,138 Z');
final _collarFlap = _svg('M128,139 L104,139 C106,149 118,152 127,146 Z');
final _neckBand = _svg('M73,137 L127,137 L129,146 C110,150 90,150 71,146 Z');
final _dogCollar = _svg('M73,137 L127,137 L128.6,144 C110,148 90,148 71.4,144 Z');
final _scarfTail = _svg('M124,143 L135,158 L121,157 Z');
final _sleeveLeft = _svg('M74,150 Q70,163 87,162');
final _sleeveRight = _svg('M126,148 Q130,161 112,160');
final _micMesh = _svg('M93,130 Q100,126 107,130 M92.4,135.6 Q100,132 107.6,135.6');
final _note = _svg('M1.2,-17 L1.2,-0.5 C1.2,3.4 -7,4.4 -7.6,0.6 C-8,-2.6 -3.6,-4 -1.2,-2.6 L-1.2,-20 C5,-19 9,-15 7.4,-8 C6.6,-12 4.6,-14.6 1.2,-15.4 Z');

// The motif on each top, about (0, 0).
final _heart = _svg('M0,5 C-9,-1 -5,-8 0,-3 C5,-8 9,-1 0,5 Z');
final _bolt = _svg('M2,-9 L-5,1 L-0.5,1 L-2.5,9 L5,-2 L0.5,-2 Z');
final _carrot = _svg('M-3.6,-4 L3.6,-4 L0,9 Z');
final _carrotLeaves = _svg('M0,-5 L-3,-10 M0,-5 L0,-11 M0,-5 L3,-10');
final _drop = _svg('M0,-8 C3,-3 6,0 6,3 C6,8 -6,8 -6,3 C-6,0 -3,-3 0,-8 Z');

Path _star(Offset c, double r) {
  final path = Path();
  for (var i = 0; i < 10; i++) {
    final rr = i.isEven ? r : r * 0.5;
    final a = -math.pi / 2 + i * math.pi / 5;
    final p = c + Offset(rr * math.cos(a), rr * math.sin(a));
    i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
  }
  return path..close();
}

Path _sparkle(Offset c, double r) {
  final s = r * 0.22;
  return Path()
    ..moveTo(c.dx, c.dy - r)
    ..quadraticBezierTo(c.dx + s, c.dy - s, c.dx + r, c.dy)
    ..quadraticBezierTo(c.dx + s, c.dy + s, c.dx, c.dy + r)
    ..quadraticBezierTo(c.dx - s, c.dy + s, c.dx - r, c.dy)
    ..quadraticBezierTo(c.dx - s, c.dy - s, c.dx, c.dy - r)
    ..close();
}

class _AvatarPainter extends CustomPainter {
  _AvatarPainter({required this.t, required this.kind, required this.headOnly, required this.animated}) : look = _Palette.of(kind);
  final double t;
  final AvatarKind kind;
  final bool headOnly;
  final bool animated;
  final _Palette look;

  /// The square shown, in the 200 x 200 space: its centre and half its side.
  /// The head-only view is cropped close, a little higher for long ears.
  (Offset, double) get _frame {
    if (!headOnly) return (const Offset(100, 100), 100);
    return switch (kind) {
      AvatarKind.rabbit => (const Offset(100, 68), 78),
      AvatarKind.cat || AvatarKind.bear => (const Offset(100, 82), 72),
      _ => (const Offset(100, 84), 72),
    };
  }

  Paint _fill(Color c) => Paint()..color = c;

  Paint _line([double w = 3.4, Color c = _ink]) => Paint()
    ..color = c
    ..style = PaintingStyle.stroke
    ..strokeWidth = w
    ..strokeJoin = StrokeJoin.round
    ..strokeCap = StrokeCap.round;

  /// A filled shape with the outline.
  void _shape(Canvas canvas, Path path, Color color, [double w = 3.4]) {
    canvas.drawPath(path, _fill(color));
    canvas.drawPath(path, _line(w));
  }

  /// A stubby arm or tail: a round-capped stroke with an outline.
  void _limb(Canvas canvas, Path path, Color color, [double w = 11]) {
    canvas.drawPath(path, _line(w + 6.8));
    canvas.drawPath(path, _line(w, color));
  }

  /// Draws the right-hand shapes, then their mirror image on the left.
  void _bothSides(Canvas canvas, void Function() draw) {
    draw();
    canvas.save();
    canvas.translate(200, 0);
    canvas.scale(-1, 1);
    draw();
    canvas.restore();
  }

  void _turn(Canvas canvas, Offset about, double angle) {
    canvas.translate(about.dx, about.dy);
    canvas.rotate(angle);
    canvas.translate(-about.dx, -about.dy);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final (centre, half) = _frame;
    canvas.save();
    canvas.scale(size.width / (2 * half));
    canvas.translate(half - centre.dx, half - centre.dy);
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: centre, radius: half)));
    _background(canvas, centre, half);

    // Singing: the beat, the head's bob and tilt, the mouth and the blinks.
    final beat = 2 * math.pi * t / 1.2;
    final bob = animated ? 2.4 * math.sin(beat) : 0.0;
    final tilt = animated ? 0.06 * math.sin(beat / 2) : 0.0;
    final sway = animated ? 1.6 * math.sin(beat / 2 + 0.6) : 0.0;
    final phrase = t % 4.0; // sings for 3.4 s, then breathes
    final singing = !animated || phrase < 3.4;
    final mouth = !animated ? 1.0 : (singing ? (0.35 + 0.65 * (math.sin(2 * math.pi * t * 2.2).abs()) * (0.65 + 0.35 * math.sin(2 * math.pi * t * 0.7))) : 0.08);
    final blink = animated && (t % 3.2) < 0.13;
    const neck = Offset(100, 136);

    canvas.save();
    // The rabbit stands a little lower, to make room for its ears.
    if (!headOnly && kind == AvatarKind.rabbit) canvas.translate(0, 14);

    if (!headOnly) {
      canvas.save();
      canvas.translate(sway, 0);
      if (kind == AvatarKind.female) {
        // Long hair follows the head, lagging a little.
        canvas.save();
        canvas.translate(0, bob * 0.6);
        _turn(canvas, neck, tilt * 0.6);
        _shape(canvas, _femaleBack, look.hairDark);
        canvas.restore();
      }
      _tail(canvas, beat);
      _torso(canvas);
      canvas.restore();
    }

    // The head turns about the neck.
    canvas.save();
    canvas.translate(sway, bob);
    _turn(canvas, neck, tilt);
    _headAndFace(canvas, mouth, blink, beat);
    canvas.restore();

    if (!headOnly) {
      canvas.save();
      canvas.translate(sway, bob * 0.5);
      _microphone(canvas);
      canvas.restore();
    }
    canvas.restore();

    if (!headOnly) _notes(canvas);
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

  /// The stage: purple light from above, a beam, a few twinkles.
  void _background(Canvas canvas, Offset c, double half) {
    final rect = Rect.fromCircle(center: c, radius: half);
    canvas.drawRect(
      rect,
      Paint()..shader = const RadialGradient(center: Alignment(0, -0.55), radius: 0.625, colors: [Color(0xFF6A3796), Color(0xFF2A1646), Color(0xFF140B22)], stops: [0, 0.55, 1]).createShader(rect),
    );
    final beam = Path()
      ..moveTo(c.dx - half * 0.18, rect.top)
      ..lineTo(c.dx + half * 0.18, rect.top)
      ..lineTo(c.dx + half * 0.76, rect.bottom)
      ..lineTo(c.dx - half * 0.76, rect.bottom)
      ..close();
    canvas.drawPath(
      beam,
      Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.white.withValues(alpha: 0.18), Colors.white.withValues(alpha: 0)]).createShader(rect),
    );
    if (headOnly) return;
    const stars = [(Offset(30, 112), 3.4, 0.6), (Offset(172, 126), 3.0, 0.5), (Offset(40, 36), 2.4, 0.5), (Offset(164, 26), 2.2, 0.45)];
    for (final (i, (at, r, alpha)) in stars.indexed) {
      final twinkle = animated ? 0.55 + 0.45 * math.sin(t * 2.4 + i * 1.7) : 1.0;
      canvas.drawPath(_sparkle(at, r), _fill(Colors.white.withValues(alpha: alpha * twinkle)));
    }
  }

  void _tail(Canvas canvas, double beat) {
    if (kind != AvatarKind.cat && kind != AvatarKind.dog) return;
    canvas.save();
    if (kind == AvatarKind.cat) {
      if (animated) _turn(canvas, const Offset(130, 192), 0.09 * math.sin(beat / 2));
      _limb(canvas, _catTail, look.body);
      canvas.drawPath(_catTailStripes, _line(4, look.furDark));
    } else {
      // A happy dog wags fast.
      if (animated) _turn(canvas, const Offset(134, 188), 0.16 * math.sin(beat * 2));
      _limb(canvas, _dogTail, look.furDark, 10);
    }
    canvas.restore();
  }

  void _torso(Canvas canvas) {
    final hooded = kind == AvatarKind.male || kind == AvatarKind.cat;
    if (hooded) _shape(canvas, _hood, look.topDark);
    canvas.drawPath(_body, _fill(look.top));
    canvas.drawPath(_bodyShade, _fill(look.topDark));
    canvas.drawPath(_body, _line());

    // Collars.
    switch (kind) {
      case AvatarKind.female || AvatarKind.rabbit:
        _bothSides(canvas, () => _shape(canvas, _collarFlap, Colors.white, 2.6));
      case AvatarKind.neutral:
        _shape(canvas, _neckBand, const Color(0xFFA8EDD8), 2.6);
      case AvatarKind.male || AvatarKind.cat:
        final string = _line(3, Colors.white);
        canvas.drawLine(const Offset(86, 140), const Offset(85, 150), string);
        canvas.drawLine(const Offset(114, 140), const Offset(115, 150), string);
      case AvatarKind.dog:
        _shape(canvas, _dogCollar, const Color(0xFFE03C3C), 2.6);
      case AvatarKind.bear:
        _shape(canvas, _neckBand, const Color(0xFFE8504A), 2.6);
    }

    // A little motif on the top.
    final white = _fill(Colors.white.withValues(alpha: 0.9));
    canvas.save();
    canvas.translate(kind == AvatarKind.rabbit ? 80 : 79, kind == AvatarKind.rabbit ? 178 : 188);
    switch (kind) {
      case AvatarKind.female:
        canvas.drawPath(_heart, white);
      case AvatarKind.male:
        canvas.drawPath(_bolt, white);
      case AvatarKind.neutral:
        canvas.drawPath(_star(Offset.zero, 7), white);
      case AvatarKind.cat:
        canvas.drawOval(Rect.fromCenter(center: const Offset(0, 2), width: 10, height: 8), white);
        for (final toe in const [Offset(-5.4, -3.4), Offset(-1.9, -6.4), Offset(1.9, -6.4), Offset(5.4, -3.4)]) {
          canvas.drawCircle(toe, 1.9, white);
        }
      case AvatarKind.dog:
        canvas.rotate(-0.35);
        canvas.drawRect(const Rect.fromLTWH(-6, -1.8, 12, 3.6), white);
        for (final knob in const [Offset(-6.4, -2.2), Offset(-6.4, 2.2), Offset(6.4, -2.2), Offset(6.4, 2.2)]) {
          canvas.drawCircle(knob, 2.6, white);
        }
      case AvatarKind.rabbit:
        canvas.rotate(0.61);
        const orange = Color(0xFFFF9F0A);
        canvas.drawPath(_carrot, _fill(orange));
        canvas.drawPath(_carrot, _line(2, orange));
        canvas.drawPath(_carrotLeaves, _line(2.2, const Color(0xFF30D158)));
      case AvatarKind.bear:
        canvas.drawPath(_drop, _fill(const Color(0xFFFF9F0A)));
        canvas.drawCircle(const Offset(-2, 2.4), 1.6, _fill(Colors.white.withValues(alpha: 0.85)));
    }
    canvas.restore();

    // Sleeves.
    _limb(canvas, _sleeveLeft, look.top);
    _limb(canvas, _sleeveRight, look.top);

    // On the neck, beside the microphone.
    if (kind == AvatarKind.dog) {
      const tag = Offset(83, 150.4);
      canvas.drawCircle(tag, 6, _fill(const Color(0xFFFFD60A)));
      canvas.drawCircle(tag, 6, _line(2.4));
      canvas.drawCircle(tag + const Offset(-1.6, -1.6), 1.7, _fill(Colors.white.withValues(alpha: 0.9)));
    } else if (kind == AvatarKind.bear) {
      _shape(canvas, _scarfTail, const Color(0xFFE8504A), 2.6);
    }
  }

  void _headAndFace(Canvas canvas, double mouth, bool blink, double beat) {
    // What sits behind the face.
    switch (kind) {
      case AvatarKind.female:
        if (headOnly) _shape(canvas, _femaleBackShort, look.hairDark);
      case AvatarKind.neutral:
        _shape(canvas, _neutralBack, look.hairDark);
      case AvatarKind.cat:
        _bothSides(canvas, () {
          _shape(canvas, _catEar, look.body);
          canvas.drawPath(_catEarInner, _fill(_pink));
        });
      case AvatarKind.rabbit:
        for (final side in [-1.0, 1.0]) {
          canvas.save();
          canvas.translate(100 + side * 24, 46);
          canvas.rotate(side * (0.227 + (animated ? 0.05 * math.sin(beat) : 0)));
          _shape(canvas, _rabbitEar, look.body);
          canvas.drawPath(_rabbitEarInner, _fill(_pink));
          canvas.restore();
        }
      case AvatarKind.bear:
        for (final x in [56.0, 144.0]) {
          canvas.drawCircle(Offset(x, 44), 18, _fill(look.body));
          canvas.drawCircle(Offset(x, 44), 18, _line());
          canvas.drawCircle(Offset(x, 45), 9, _fill(look.furLight));
        }
      case AvatarKind.male || AvatarKind.dog:
        break;
    }

    // The head, with its markings kept inside it.
    canvas.drawPath(_head, _fill(look.body));
    canvas.save();
    canvas.clipPath(_head);
    switch (kind) {
      case AvatarKind.female || AvatarKind.male || AvatarKind.neutral:
        // The fringe's shadow on the forehead.
        canvas.translate(0, 6);
        canvas.drawPath(_fringe, _fill(_skinShade.withValues(alpha: 0.75)));
      case AvatarKind.cat:
        canvas.drawOval(Rect.fromCenter(center: const Offset(100, 122), width: 68, height: 48), _fill(look.furLight));
        canvas.drawPath(_catStripes, _line(6, look.furDark));
        canvas.drawPath(_catCheekStripes, _line(5, look.furDark));
      case AvatarKind.dog:
        // A caramel patch round one eye.
        canvas.drawOval(Rect.fromCenter(center: const Offset(129, 96), width: 38, height: 42), _fill(const Color(0xFFE0A870)));
        canvas.drawOval(Rect.fromCenter(center: const Offset(100, 120), width: 54, height: 42), _fill(look.furLight));
      case AvatarKind.bear:
        canvas.drawOval(Rect.fromCenter(center: const Offset(100, 120), width: 54, height: 42), _fill(look.furLight));
      case AvatarKind.rabbit:
        break;
    }
    canvas.restore();
    canvas.drawPath(_head, _line());

    // Hair, and what sits on top of the head.
    switch (kind) {
      case AvatarKind.female:
        _shape(canvas, _femaleFringe, look.hair);
        canvas.drawPath(_femaleShine, _fill(look.hairLight));
        _shape(canvas, _star(const Offset(141, 56), 10), look.accent, 2.6);
      case AvatarKind.male:
        _shape(canvas, _maleTuft, look.hair);
        _shape(canvas, _maleFringe, look.hair);
        canvas.drawPath(_maleShine, _fill(look.hairLight));
      case AvatarKind.neutral:
        _shape(canvas, _neutralFringe, look.hair);
        canvas.drawPath(_neutralShine, _fill(look.hairLight));
        canvas.save();
        _turn(canvas, const Offset(59.5, 74), -0.42);
        final pin = RRect.fromRectAndRadius(const Rect.fromLTWH(50, 71, 19, 6.4), const Radius.circular(3.2));
        canvas.drawRRect(pin, _fill(look.accent));
        canvas.drawRRect(pin, _line(2.4));
        canvas.restore();
      case AvatarKind.dog:
        _shape(canvas, _dogTuft, look.body);
      case AvatarKind.rabbit:
        // A bow at the foot of one ear.
        const bow = Color(0xFFFF7AB8);
        _shape(canvas, _rabbitBow, bow, 2.6);
        canvas.drawCircle(const Offset(133, 42), 3.6, _fill(const Color(0xFFFFB3D6)));
        canvas.drawCircle(const Offset(133, 42), 3.6, _line(2.2));
      case AvatarKind.cat || AvatarKind.bear:
        break;
    }

    // Blush.
    final (bx, by) = kind.human ? (42.0, 111.0) : (kind == AvatarKind.dog || kind == AvatarKind.bear ? (41.0, 113.0) : (40.0, 112.0));
    for (final side in [-1.0, 1.0]) {
      canvas.drawOval(Rect.fromCenter(center: Offset(100 + side * bx, by), width: 17, height: 10.8), _fill(look.blush.withValues(alpha: 0.85)));
    }

    // Eyes, nose and mouth.
    final eyeY = kind.human ? 100.0 : 98.0;
    _eye(canvas, Offset(74, eyeY), blink);
    _eye(canvas, Offset(126, eyeY), blink);
    switch (kind) {
      case AvatarKind.female || AvatarKind.male || AvatarKind.neutral:
        _mouth(canvas, 112, mouth);
      case AvatarKind.cat || AvatarKind.rabbit:
        _nose(canvas, const Offset(100, 103.6), 4.4, 5, const Color(0xFFFF7A9A));
        _mouth(canvas, 114, mouth, teeth: kind == AvatarKind.rabbit);
        canvas.drawPath(_whiskers, _line(2.2));
      case AvatarKind.dog || AvatarKind.bear:
        _nose(canvas, const Offset(100, 102), 7.6, 8.4, _ink);
        canvas.drawOval(Rect.fromCenter(center: const Offset(97.4, 103.6), width: 4.8, height: 2.6), _fill(Colors.white.withValues(alpha: 0.75)));
        _mouth(canvas, 116.4, mouth);
    }

    // The puppy's floppy ears, hanging over the sides of the head.
    if (kind == AvatarKind.dog) {
      for (final side in [1.0, -1.0]) {
        canvas.save();
        if (side < 0) {
          canvas.translate(200, 0);
          canvas.scale(-1, 1);
        }
        if (animated) _turn(canvas, const Offset(140, 42), 0.05 * math.sin(beat + 1));
        _shape(canvas, _dogEar, look.furDark);
        canvas.drawPath(_dogEarShine, _line(5, const Color(0xFFD49A62)));
        canvas.restore();
      }
    }
  }

  Path get _fringe => switch (kind) {
        AvatarKind.male => _maleFringe,
        AvatarKind.neutral => _neutralFringe,
        _ => _femaleFringe,
      };

  /// A dot eye with a glint of the look's colour; a blink is a happy arc.
  void _eye(Canvas canvas, Offset c, bool blink) {
    final (x, y) = (c.dx, c.dy);
    if (blink) {
      final arc = Path()
        ..moveTo(x - 6.5, y + 3)
        ..quadraticBezierTo(x, y - 5, x + 6.5, y + 3);
      canvas.drawPath(arc, _line(3));
      return;
    }
    canvas.drawOval(Rect.fromCenter(center: c, width: 13.2, height: 17.6), _fill(_ink));
    final iris = Path()
      ..moveTo(x - 5, y + 3.4)
      ..cubicTo(x - 3, y + 8, x + 3, y + 8, x + 5, y + 3.4)
      ..cubicTo(x + 2, y + 5.4, x - 2, y + 5.4, x - 5, y + 3.4)
      ..close();
    canvas.drawPath(iris, _fill(look.iris));
    canvas.drawCircle(Offset(x - 2, y - 3.4), 2.9, _fill(Colors.white));
    canvas.drawCircle(Offset(x + 2.4, y + 1.2), 1.2, _fill(Colors.white));
    if (kind == AvatarKind.female) {
      // Two lashes at the outer corner.
      final s = x < 100 ? -1.0 : 1.0;
      final lash = _line(2.2);
      canvas.drawLine(Offset(x + s * 6, y - 4.6), Offset(x + s * 10.4, y - 6.6), lash);
      canvas.drawLine(Offset(x + s * 6.6, y - 0.6), Offset(x + s * 11, y - 1), lash);
    }
  }

  /// A small rounded nose, [halfWidth] wide and [height] tall from [top].
  void _nose(Canvas canvas, Offset top, double halfWidth, double height, Color color) {
    final (x, y) = (top.dx, top.dy);
    final nose = Path()
      ..moveTo(x - halfWidth, y)
      ..quadraticBezierTo(x, y - halfWidth * 0.36, x + halfWidth, y)
      ..quadraticBezierTo(x + halfWidth * 0.84, y + height * 0.96, x, y + height)
      ..quadraticBezierTo(x - halfWidth * 0.84, y + height * 0.96, x - halfWidth, y)
      ..close();
    canvas.drawPath(nose, _fill(color));
    canvas.drawPath(nose, _line(2));
  }

  /// The singing mouth, [open] from 0 (closed) to 1 (wide), hanging from y.
  void _mouth(Canvas canvas, double y, double open, {bool teeth = false}) {
    final halfWidth = 7 + 2 * open;
    final bottom = y + 1.5 + 6.5 * open;
    final shape = Path()
      ..moveTo(100 - halfWidth, y - 4)
      ..quadraticBezierTo(100, y - 4 - 2 * open, 100 + halfWidth, y - 4)
      ..quadraticBezierTo(100 + halfWidth, bottom, 100, bottom)
      ..quadraticBezierTo(100 - halfWidth, bottom, 100 - halfWidth, y - 4)
      ..close();
    canvas.drawPath(shape, _fill(const Color(0xFFA82848)));
    canvas.save();
    canvas.clipPath(shape);
    if (open > 0.3) canvas.drawOval(Rect.fromCenter(center: Offset(100, bottom - 1), width: 12, height: 8), _fill(const Color(0xFFFF8FA3)));
    if (teeth) {
      // The rabbit's two front teeth.
      final pair = RRect.fromRectAndRadius(Rect.fromLTWH(95, y - 7, 10, 7.4), const Radius.circular(1.6));
      canvas.drawRRect(pair, _fill(Colors.white));
      canvas.drawRRect(pair, _line(1.6));
      canvas.drawLine(Offset(100, y - 5), Offset(100, y + 0.4), _line(1.4));
    }
    canvas.restore();
    canvas.drawPath(shape, _line(2.8));
  }

  /// Held in both hands, just under the chin.
  void _microphone(Canvas canvas) {
    canvas.save();
    _turn(canvas, const Offset(100, 150), -0.122);
    final handle = RRect.fromRectAndRadius(const Rect.fromLTWH(95.4, 140, 9.2, 40), const Radius.circular(3));
    canvas.drawRRect(handle, _fill(const Color(0xFF4A4658)));
    canvas.drawRRect(handle, _line());
    const band = Rect.fromLTWH(95.4, 146, 9.2, 5);
    canvas.drawRect(band, _fill(look.accent));
    canvas.drawRect(band, _line(2));
    // The grille.
    const ball = Offset(100, 133);
    canvas.drawCircle(ball, 10.5, _fill(const Color(0xFFC9C9D6)));
    canvas.drawCircle(ball, 10.5, _line());
    canvas.drawPath(_micMesh, _line(1.4, _ink.withValues(alpha: 0.45)));
    canvas.drawCircle(const Offset(96.4, 128.6), 2.4, _fill(Colors.white));
    canvas.restore();
    // The hands, or paws.
    for (final hand in const [Offset(89.5, 161), Offset(109.5, 159)]) {
      canvas.drawCircle(hand, 8.4, _fill(look.body));
      canvas.drawCircle(hand, 8.4, _line());
      canvas.drawCircle(hand + const Offset(-2.1, -2.4), 2.2, _fill(Colors.white.withValues(alpha: 0.7)));
    }
  }

  /// Notes floating up either side; still, two of them clear of the ears.
  void _notes(Canvas canvas) {
    const gold = Color(0xFFFFD60A);
    if (!animated) {
      final (first, second) = switch (kind) {
        AvatarKind.cat => ((const Offset(178, 90), 1.15), (const Offset(24, 92), 0.95)),
        AvatarKind.dog => ((const Offset(130, 30), 1.0), (const Offset(68, 28), 0.85)),
        AvatarKind.bear => ((const Offset(177, 68), 1.15), (const Offset(26, 74), 0.95)),
        _ => ((const Offset(170, 62), 1.2), (const Offset(28, 72), 0.95)),
      };
      _drawNote(canvas, first.$1, first.$2, -0.17, gold, 1);
      _drawNote(canvas, second.$1, second.$2, 0.21, look.note, 1);
      return;
    }
    final colors = [gold, look.note, const Color(0xFFFF4FA3)];
    for (var i = 0; i < 3; i++) {
      final p = ((t + i * 0.9) % 2.7) / 2.7;
      final side = i.isEven ? 1.0 : -1.0;
      final at = Offset(100 + side * (73 + 8 * p) + 3 * math.sin(p * 6 + i), 118 - 76 * p);
      final alpha = (p < 0.15 ? p / 0.15 : 1 - (p - 0.15) / 0.85).clamp(0.0, 1.0);
      _drawNote(canvas, at, 0.95 + 0.25 * math.sin(i + p * 3), side * -0.17 + 0.12 * math.sin(p * 5 + i), colors[i], alpha);
    }
  }

  void _drawNote(Canvas canvas, Offset at, double scale, double turn, Color color, double alpha) {
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.rotate(turn);
    canvas.scale(scale);
    canvas.drawPath(_note, _fill(color.withValues(alpha: alpha)));
    canvas.drawPath(_note, _line(1.6, _ink.withValues(alpha: alpha)));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_AvatarPainter old) => old.t != t || old.kind != kind || old.headOnly != headOnly;
}
