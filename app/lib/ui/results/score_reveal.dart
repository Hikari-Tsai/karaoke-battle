// The score reveal after a take: the total rolls up on slot-machine reels,
// the rank stamps down, and a new personal best gets a full-screen party
// with a cheering crowd. The sounds are synthesized by tools/sfx/make_sfx.py.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../state/i18n.dart';
import '../widgets/rank.dart';

/// How long the reels spin (roll.mp3 is timed to this).
const kRevealRoll = Duration(milliseconds: 3200);

/// Exponent of the reels' slow-down (ROLL_EASE in make_sfx.py).
const kRevealEase = 2.2;

/// Fast at first, then slowing to a stop: 1 - (1 - t)^[power].
class SlotCurve extends Curve {
  const SlotCurve([this.power = kRevealEase]);
  final double power;

  @override
  double transformInternal(double t) => 1 - math.pow(1 - t, power).toDouble();

  /// Rate of change at [t] (d/dt of [transform]).
  double slope(double t) => power * math.pow(1 - t.clamp(0.0, 1.0), power - 1).toDouble();
}

/// The results sounds. Silent when turned off or under `flutter test`.
class ResultSfx {
  ResultSfx({required this.enabled});
  final bool enabled;

  static const names = ['roll', 'ding', 'celebrate'];
  static bool get _supported => !Platform.environment.containsKey('FLUTTER_TEST');

  final _players = <String, Player>{};
  Future<void>? _loading;
  bool _disposed = false;

  /// Opens every sound paused, so each starts on time when played.
  Future<void> preload() => _loading ??= _preload();

  Future<void> _preload() async {
    if (!enabled || !_supported) return;
    for (final name in names) {
      try {
        final player = Player();
        if (_disposed) {
          await player.dispose();
          return;
        }
        _players[name] = player;
        await player.open(Media('asset:///assets/sfx/$name.mp3'), play: false);
      } catch (_) {
        // No sound is better than no results.
      }
    }
  }

  Future<void> play(String name) async {
    final p = _players[name];
    if (p == null || _disposed) return;
    try {
      await p.seek(Duration.zero);
      await p.play();
    } catch (_) {}
  }

  Future<void> stop(String name) async {
    final p = _players[name];
    if (p == null || _disposed) return;
    try {
      await p.pause();
    } catch (_) {}
  }

  void dispose() {
    _disposed = true;
    for (final p in _players.values) {
      p.dispose();
    }
    _players.clear();
  }
}

/// [value] on odometer reels with one decimal ("085.3" spins like a slot
/// machine: the tenths whirl, the higher reels turn over as they carry).
class RollingNumber extends StatelessWidget {
  const RollingNumber({super.key, required this.value, required this.intDigits, required this.style, this.tenthsPerFrame = 0});
  final double value;

  /// Reels before the decimal point (leading ones show 0).
  final int intDigits;
  final TextStyle style;

  /// How fast the tenths reel turns, for motion blur.
  final double tenthsPerFrame;

  /// Reel position (0..10) of the digit worth 10^[place] tenths.
  static double reel(double tenths, int place) {
    if (place == 0) return tenths % 10;
    final base = (tenths / math.pow(10, place)).floor() % 10;
    // Turn over together with the reel below as it rolls from 9 to 0.
    final below = reel(tenths, place - 1);
    return base + math.max(0.0, below - 9);
  }

  /// Which digits a reel shows, top to bottom, at [pos].
  static (int, int, double) visible(double pos) {
    final low = pos.floor();
    return (low % 10, (low + 1) % 10, pos - low);
  }

  @override
  Widget build(BuildContext context) {
    final s = style.copyWith(fontFeatures: const [ui.FontFeature.tabularFigures()]);
    var w = 0.0, h = 0.0, baseline = 0.0;
    for (var d = 0; d < 10; d++) {
      final tp = TextPainter(text: TextSpan(text: '$d', style: s), textDirection: TextDirection.ltr)..layout();
      w = math.max(w, tp.width);
      h = math.max(h, tp.height);
      baseline = tp.computeDistanceToActualBaseline(TextBaseline.alphabetic);
      tp.dispose();
    }
    // Only the band the digits are drawn in shows, and the digits sit close
    // together on the reel, so a turning reel looks like a slot window rather
    // than two digits a whole line apart.
    final size = s.fontSize ?? 14;
    final band = Rect.fromLTRB(0, baseline - size * 0.78, w, baseline + size * 0.06);
    final pitch = band.height * 1.12;
    var tenths = value * 10;
    if ((tenths - tenths.round()).abs() < 1e-6) tenths = tenths.roundToDouble();
    Widget reelAt(int place) {
      final (top, next, frac) = visible(reel(tenths, place));
      final speed = tenthsPerFrame / math.pow(10, place);
      final blur = ((speed - 0.15) * 6).clamp(0.0, 6.0);
      Widget digits = SizedBox(
        width: w,
        height: h,
        child: Stack(clipBehavior: Clip.none, children: [
          Positioned(left: 0, right: 0, top: -frac * pitch, child: Text('$top', style: s, textAlign: TextAlign.center)),
          if (frac > 0) Positioned(left: 0, right: 0, top: (1 - frac) * pitch, child: Text('$next', style: s, textAlign: TextAlign.center)),
        ]),
      );
      if (blur > 0.2) {
        digits = ImageFiltered(imageFilter: ui.ImageFilter.blur(sigmaX: 0, sigmaY: blur), child: digits);
      }
      return ClipRect(clipper: _BandClipper(band), child: digits);
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var place = intDigits; place >= 1; place--) reelAt(place),
        Text('.', style: s),
        reelAt(0),
      ],
    );
  }
}

class _BandClipper extends CustomClipper<Rect> {
  const _BandClipper(this.band);
  final Rect band;

  @override
  Rect getClip(Size size) => Rect.fromLTRB(-2, band.top - 2, size.width + 2, band.bottom + 2);

  @override
  bool shouldReclip(_BandClipper old) => old.band != band;
}

/// Full-screen party for a new personal best: fireworks, confetti, light
/// rays and the new score slammed into the middle. Tap to finish early.
class CelebrationOverlay extends StatefulWidget {
  const CelebrationOverlay({super.key, required this.score, required this.previousBest, required this.onDone});
  final double score;
  final double previousBest;
  final VoidCallback onDone;

  static const duration = Duration(milliseconds: 5200);

  @override
  State<CelebrationOverlay> createState() => _CelebrationOverlayState();
}

class _CelebrationOverlayState extends State<CelebrationOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: CelebrationOverlay.duration)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) _finish();
    })
    ..forward();
  final _scene = _PartyScene(math.Random(20260611));
  bool _done = false;

  void _finish() {
    if (_done) return;
    _done = true;
    widget.onDone();
  }

  /// Taps after the first second skip to the fade-out.
  void _skip() {
    if (_c.value * CelebrationOverlay.duration.inMilliseconds < 900) return;
    _finish();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final diff = widget.score - widget.previousBest;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _skip,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value * CelebrationOverlay.duration.inMilliseconds / 1000;
          final fade = (math.min(t / 0.25, 1.0) * math.min((CelebrationOverlay.duration.inMilliseconds / 1000 - t) / 0.6, 1.0)).clamp(0.0, 1.0);
          // The title slams in, overshooting, then breathes.
          final slam = Curves.elasticOut.transform((t / 0.9).clamp(0.0, 1.0));
          final breathe = 1 + 0.03 * math.sin(t * 5);
          final sub = Curves.easeOut.transform(((t - 0.55) / 0.5).clamp(0.0, 1.0));
          return Opacity(
            opacity: fade,
            child: Material(
              type: MaterialType.transparency,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CustomPaint(painter: _PartyPainter(_scene, t)),
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Transform.translate(
                          offset: Offset(0, -12 * math.sin(t * 4).abs()),
                          child: Transform.scale(
                            scale: 0.4 + 0.6 * slam,
                            child: const Icon(
                              Icons.emoji_events,
                              size: 110,
                              color: trophyColor,
                              shadows: [Shadow(color: Color(0xAAFFC400), blurRadius: 40)],
                            ),
                          ),
                        ),
                        Transform.scale(
                          scale: (0.2 + 0.8 * slam) * breathe,
                          child: ShaderMask(
                            shaderCallback: (r) => LinearGradient(
                              colors: const [Color(0xFFFFF3B0), Color(0xFFFFC400), Color(0xFFFF8A00), Color(0xFFFFF3B0)],
                              stops: const [0, 0.4, 0.7, 1],
                              transform: GradientRotation(t * 1.5),
                            ).createShader(r),
                            child: Text(
                              tr('celebrate.title'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 92,
                                fontWeight: FontWeight.w900,
                                color: Colors.white,
                                letterSpacing: 2,
                                shadows: [
                                  Shadow(color: Color(0xCCFF8A00), blurRadius: 30),
                                  Shadow(color: Colors.black54, offset: Offset(0, 6), blurRadius: 12),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Opacity(
                          opacity: sub,
                          child: Transform.translate(
                            offset: Offset(0, 20 * (1 - sub)),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  tr('celebrate.beat', {'prev': widget.previousBest.toStringAsFixed(1), 'score': widget.score.toStringAsFixed(1)}),
                                  style: const TextStyle(
                                    fontSize: 34,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.white,
                                    shadows: [Shadow(color: Colors.black87, blurRadius: 10)],
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: trophyColor,
                                    borderRadius: BorderRadius.circular(30),
                                    boxShadow: const [BoxShadow(color: Color(0x88FFC400), blurRadius: 24)],
                                  ),
                                  child: Text(
                                    '+${diff.toStringAsFixed(1)}',
                                    style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: Colors.black),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 28,
                    child: Opacity(
                      opacity: (sub * 0.7).clamp(0.0, 1.0),
                      child: Text(
                        tr('celebrate.skip'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70, fontSize: 14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Burst {
  _Burst(this.at, this.x, this.y, this.color, this.speeds, this.angles);
  final double at, x, y; // seconds; x, y as fractions of the screen
  final Color color;
  final List<double> speeds, angles;
}

class _Confetto {
  _Confetto(this.at, this.x, this.fall, this.sway, this.phase, this.spin, this.size, this.color);
  final double at, x, fall, sway, phase, spin, size;
  final Color color;
}

/// The random layout of one party, fixed up front so every frame agrees.
class _PartyScene {
  _PartyScene(math.Random r) {
    const palette = [Color(0xFFFFD60A), Color(0xFFFF4FA3), Color(0xFF30D158), Color(0xFF64D2FF), Color(0xFFBF5AF2), Color(0xFFFF9F0A), Colors.white];
    const times = [0.05, 0.35, 0.7, 1.1, 1.5, 1.95, 2.4, 2.9, 3.4];
    for (var i = 0; i < times.length; i++) {
      final n = 64;
      bursts.add(
        _Burst(
          times[i],
          0.12 + r.nextDouble() * 0.76,
          0.12 + r.nextDouble() * 0.4,
          palette[r.nextInt(palette.length)],
          [for (var k = 0; k < n; k++) 160 + r.nextDouble() * 220],
          [for (var k = 0; k < n; k++) 2 * math.pi * k / n + r.nextDouble() * 0.1],
        ),
      );
    }
    for (var i = 0; i < 240; i++) {
      confetti.add(
        _Confetto(
          r.nextDouble() * 2.8,
          r.nextDouble(),
          180 + r.nextDouble() * 220,
          20 + r.nextDouble() * 50,
          r.nextDouble() * 2 * math.pi,
          4 + r.nextDouble() * 8,
          6 + r.nextDouble() * 8,
          palette[r.nextInt(palette.length)],
        ),
      );
    }
  }

  final bursts = <_Burst>[];
  final confetti = <_Confetto>[];
}

class _PartyPainter extends CustomPainter {
  _PartyPainter(this.scene, this.t);
  final _PartyScene scene;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    // Dim the results behind, with a warm glow in the middle.
    canvas.drawRect(Offset.zero & size, Paint()..shader = ui.Gradient.radial(center, size.longestSide * 0.7, [const Color(0x99402A00), const Color(0xE6060410)]));
    // Slowly turning light rays.
    final rays = Paint()..color = const Color(0x17FFD60A);
    final r = size.longestSide;
    for (var i = 0; i < 14; i++) {
      final a = t * 0.35 + i * 2 * math.pi / 14;
      final path = Path()
        ..moveTo(center.dx, center.dy)
        ..lineTo(center.dx + r * math.cos(a - 0.09), center.dy + r * math.sin(a - 0.09))
        ..lineTo(center.dx + r * math.cos(a + 0.09), center.dy + r * math.sin(a + 0.09))
        ..close();
      canvas.drawPath(path, rays);
    }
    // Fireworks: sparks fly out, droop under gravity and fade.
    const life = 1.5, gravity = 260.0;
    final spark = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 3;
    for (final b in scene.bursts) {
      final age = t - b.at;
      if (age < 0 || age > life) continue;
      final o = Offset(b.x * size.width, b.y * size.height);
      final fade = 1 - age / life;
      final drag = (1 - math.exp(-age * 2.2)) / 2.2; // slowing outward travel
      for (var k = 0; k < b.speeds.length; k++) {
        final dir = Offset(math.cos(b.angles[k]), math.sin(b.angles[k]));
        final p = o + dir * (b.speeds[k] * drag) + Offset(0, 0.5 * gravity * age * age);
        final tail = o + dir * (b.speeds[k] * drag * 0.82) + Offset(0, 0.5 * gravity * age * age * 0.9);
        spark.color = b.color.withValues(alpha: fade);
        canvas.drawLine(tail, p, spark);
      }
      if (age < 0.15) {
        canvas.drawCircle(o, 40 * (1 - age / 0.15), Paint()..color = Colors.white.withValues(alpha: 0.8 * (1 - age / 0.15)));
      }
    }
    // Confetti: flutters down, swaying and flipping.
    final paper = Paint();
    for (final c in scene.confetti) {
      final age = t - c.at;
      if (age < 0) continue;
      final y = -20 + c.fall * age;
      if (y > size.height + 20) continue;
      final x = c.x * size.width + c.sway * math.sin(c.phase + age * 3);
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(c.phase + age * c.spin * 0.5);
      canvas.scale(1, math.cos(c.phase + age * c.spin).abs() * 0.8 + 0.2);
      paper.color = c.color;
      canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: c.size, height: c.size * 0.55), paper);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_PartyPainter old) => old.t != t;
}
