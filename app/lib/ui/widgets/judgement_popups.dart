// Rhythm-game style judgement pop-ups for replays, after maimai DX and
// CHUNITHM:
//
// * Position: on the judgement line (the playhead) just above the judged
//   note's row, like CHUNITHM's judgements over the lane at the line and
//   maimai's at the sensor that was hit.
// * Tier: the worse of the note's timing judgement (onset, from the rhythm
//   sub-score) and a pitch tier from its median deviation, so an off-key
//   note cannot show PERFECT. Display only; the scores are unchanged.
// * Type: heavy italic capitals with a gradient fill, a dark outline and a
//   glow in the tier colour (maimai: PERFECT yellow-orange, GREAT pink,
//   GOOD green, MISS grey). Small tags underneath say why a note lost
//   points: FAST (blue) / LATE (red) when the timing was GREAT or GOOD, as
//   maimai's FAST/LATE display does, and HIGH (orange) / LOW (violet) when
//   the pitch was off by more than [JudgementMark.pitchTagCents].
// * Motion: pops in large and settles with a small overshoot (~110 ms),
//   holds, then drifts up while fading (gone after 0.45 s). MISS does not
//   pop: it appears flat and sinks while fading.
//
// Timing follows the track position, so pausing or seeking freezes or
// rewinds the pop-ups with the replay.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

const _tiers = ['perfect', 'great', 'good', 'miss'];

/// Pitch tier of a note from its median deviation in cents.
String pitchTier(double cents) {
  final c = cents.abs();
  if (c <= JudgementMark.pitchPerfectCents) return 'perfect';
  if (c <= JudgementMark.pitchGreatCents) return 'great';
  if (c <= JudgementMark.pitchGoodCents) return 'good';
  return 'miss';
}

/// The lower of two tiers.
String worseTier(String a, String b) {
  final i = _tiers.indexOf(a), j = _tiers.indexOf(b);
  return _tiers[math.max(i < 0 ? 3 : i, j < 0 ? 3 : j)];
}

/// One judged note: when it starts, its tier, where it sits and the tags
/// shown under it (null = no tag).
class JudgementMark {
  const JudgementMark({required this.time, required this.tier, required this.midi, this.fast, this.high});

  /// Combines the timing judgement of a note's onset with its pitch:
  /// [onsetErrorMs] is sung minus expected (negative = early), [cents] the
  /// note's median deviation (positive = sharp; null = nothing sung).
  factory JudgementMark.forNote({
    required double time,
    required double midi,
    required String timing,
    double? onsetErrorMs,
    double? cents,
  }) {
    final timed = (timing == 'great' || timing == 'good') && onsetErrorMs != null && onsetErrorMs != 0;
    final offKey = cents != null && cents.abs() > pitchTagCents;
    return JudgementMark(
      time: time,
      midi: midi,
      tier: cents == null ? timing : worseTier(timing, pitchTier(cents)),
      fast: timed ? onsetErrorMs < 0 : null,
      high: offKey ? cents > 0 : null,
    );
  }

  /// Pitch tiers (median deviation, cents). GOOD ends at the engine's
  /// in-tune tolerance (half a semitone).
  static const pitchPerfectCents = 15.0, pitchGreatCents = 30.0, pitchGoodCents = 50.0;

  /// HIGH / LOW is shown beyond this deviation.
  static const pitchTagCents = 20.0;

  final double time;
  final String tier; // perfect | great | good | miss
  final double midi; // as drawn (key shift included)
  final bool? fast; // FAST (true) / LATE (false)
  final bool? high; // HIGH (true) / LOW (false)
}

class JudgementStyle {
  const JudgementStyle(this.label, this.colors, this.glow);
  final String label;
  final List<Color> colors; // gradient, top to bottom
  final Color glow;

  static JudgementStyle of(String tier) => switch (tier) {
        'perfect' => const JudgementStyle('PERFECT', [Color(0xFFFFF7B8), Color(0xFFFFCC1A), Color(0xFFFF8A00)], Color(0xFFFFB300)),
        'great' => const JudgementStyle('GREAT', [Color(0xFFFFD6EE), Color(0xFFFF5CAD), Color(0xFFD81B7A)], Color(0xFFFF4FA3)),
        'good' => const JudgementStyle('GOOD', [Color(0xFFD9FFE0), Color(0xFF3DDB64), Color(0xFF13A044)], Color(0xFF30D158)),
        _ => const JudgementStyle('MISS', [Color(0xFFEDEDF2), Color(0xFF9A9AA2), Color(0xFF66666E)], Color(0xFF3A3A40)),
      };
}

/// Animation state of a pop-up [age] seconds after its note.
@visibleForTesting
({double scale, double opacity, double dy}) judgementMotion(double age, {required bool miss}) {
  const life = JudgementLayer.life;
  if (age < 0 || age > life) return (scale: 1, opacity: 0, dy: 0);
  if (miss) {
    final fade = age < 0.25 ? 1.0 : 1 - (age - 0.25) / (life - 0.25);
    return (scale: 1, opacity: fade.clamp(0.0, 1.0), dy: 10 * age / life);
  }
  double scale;
  if (age < 0.06) {
    scale = 1.45 - 0.5 * Curves.easeOut.transform(age / 0.06); // 1.45 -> 0.95
  } else if (age < 0.11) {
    scale = 0.95 + 0.05 * Curves.easeOut.transform((age - 0.06) / 0.05); // -> 1.0
  } else {
    scale = 1 + 0.05 * math.max(0, (age - 0.3) / (life - 0.3)); // slight grow while fading
  }
  final opacity = age < 0.04 ? age / 0.04 : (age < 0.3 ? 1.0 : 1 - (age - 0.3) / (life - 0.3));
  final dy = -(age < 0.3 ? 4 * age / 0.3 : 4 + 10 * (age - 0.3) / (life - 0.3));
  return (scale: scale, opacity: opacity.clamp(0.0, 1.0), dy: dy);
}

/// Draws every pop-up still alive at the current position, placed with the
/// same mapping as PianoRollView.
class JudgementLayer extends StatelessWidget {
  const JudgementLayer({
    super.key,
    required this.position,
    required this.marks,
    required this.minMidi,
    required this.maxMidi,
    this.windowSeconds = 8,
    this.playheadFraction = 0.3,
    this.gutter = 46,
  });

  /// Seconds a pop-up stays on screen.
  static const life = 0.45;

  final ValueListenable<double> position;
  final List<JudgementMark> marks; // sorted by time
  final double minMidi, maxMidi;
  final double windowSeconds, playheadFraction, gutter;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth, h = c.maxHeight;
      final rows = (maxMidi - minMidi) + 1;
      final rowH = h / rows;
      final x = gutter + playheadFraction * (w - gutter);
      return ValueListenableBuilder<double>(
        valueListenable: position,
        builder: (context, t, _) {
          // First mark that may still be visible.
          var lo = 0, hi = marks.length;
          while (lo < hi) {
            final m = (lo + hi) >> 1;
            if (marks[m].time < t - life) {
              lo = m + 1;
            } else {
              hi = m;
            }
          }
          final children = <Widget>[];
          for (var i = lo; i < marks.length && marks[i].time <= t; i++) {
            final mk = marks[i];
            final mo = judgementMotion(t - mk.time, miss: mk.tier == 'miss');
            if (mo.opacity <= 0) continue;
            final noteTop = h - ((mk.midi - minMidi + 0.5) / rows) * h - rowH / 2;
            final y = (noteTop - 6 + mo.dy).clamp(30.0, h - 8);
            children.add(Positioned(
              left: x - 110,
              width: 220,
              top: y - 44,
              height: 44,
              child: Opacity(
                opacity: mo.opacity,
                child: Transform.scale(
                  scale: mo.scale,
                  alignment: Alignment.bottomCenter,
                  child: JudgementText(tier: mk.tier, fast: mk.fast, high: mk.high),
                ),
              ),
            ));
          }
          return Stack(clipBehavior: Clip.none, children: children);
        },
      );
    });
  }
}

/// The judgement word (gradient, outline, glow) with its FAST/LATE and
/// HIGH/LOW tags.
class JudgementText extends StatelessWidget {
  const JudgementText({super.key, required this.tier, this.fast, this.high, this.fontSize = 26});
  final String tier;
  final bool? fast;
  final bool? high;
  final double fontSize;

  static TextStyle _base(double size) => TextStyle(
        fontSize: size,
        fontWeight: FontWeight.w900,
        fontStyle: FontStyle.italic,
        letterSpacing: size * 0.06,
        height: 1.0,
      );

  @override
  Widget build(BuildContext context) {
    final st = JudgementStyle.of(tier);
    final base = _base(fontSize);
    final word = Stack(children: [
      // Dark outline with a glow in the tier colour.
      Text(st.label,
          style: base.copyWith(
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = fontSize * 0.2
              ..strokeJoin = StrokeJoin.round
              ..color = const Color(0xFF1A1033),
            shadows: [Shadow(color: st.glow.withValues(alpha: 0.85), blurRadius: fontSize * 0.55)],
          )),
      // Gradient fill.
      ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (r) => LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: st.colors,
          stops: const [0.0, 0.55, 1.0],
        ).createShader(r),
        child: Text(st.label, style: base.copyWith(color: Colors.white)),
      ),
    ]);
    final tags = [
      if (fast != null) (fast! ? 'FAST' : 'LATE', fast! ? const Color(0xFF3FA9FF) : const Color(0xFFFF4D4D)),
      if (high != null) (high! ? 'HIGH' : 'LOW', high! ? const Color(0xFFFF9F2E) : const Color(0xFFB58CFF)),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        word,
        if (tags.isNotEmpty)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var k = 0; k < tags.length; k++) ...[
                if (k > 0) SizedBox(width: fontSize * 0.3),
                Text(
                  tags[k].$1,
                  style: _base(fontSize * 0.42).copyWith(
                    color: tags[k].$2,
                    letterSpacing: fontSize * 0.08,
                    shadows: const [
                      Shadow(color: Color(0xFF1A1033), blurRadius: 2),
                      Shadow(color: Color(0xFF1A1033), offset: Offset(0, 1)),
                    ],
                  ),
                ),
              ],
            ],
          ),
      ],
    );
  }
}
