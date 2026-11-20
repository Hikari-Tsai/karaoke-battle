// Rank colours and the small rank chip shared by the results and library screens.
import 'package:flutter/material.dart';

import 'shine.dart';

/// One colour per rank: gold, violet, pink-red, orange, green, blue, grey.
Color rankColor(String? rank) => switch (rank) {
      'SSS' => const Color(0xFFFFD60A),
      'SS' => const Color(0xFFBF5AF2),
      'S' => const Color(0xFFFF375F),
      'A' => const Color(0xFFFF9F0A),
      'B' => const Color(0xFF30D158),
      'C' => const Color(0xFF64D2FF),
      _ => const Color(0xFF9A9FA8),
    };

/// The trophy colour for a song's best take (always gold).
const Color trophyColor = Color(0xFFFFC107);

/// S and above shine: 1 for S, 2 for SS, 3 for SSS, else 0.
int rankTier(String? rank) => switch (rank) { 'SSS' => 3, 'SS' => 2, 'S' => 1, _ => 0 };

class RankChip extends StatelessWidget {
  const RankChip({super.key, required this.rank, this.fontSize = 14, this.animated = true});
  final String? rank;
  final double fontSize;

  /// S and above glow, with a band of light sweeping across now and then
  /// (SSS the most often and brightest) and, when large, sparkles.
  final bool animated;

  // Per tier (S, SS, SSS): seconds between sweeps, band strength, glow.
  static const _period = [0.0, 4.6, 3.8, 3.0];
  static const _strength = [0.0, 0.45, 0.6, 0.85];
  static const _glow = [0.0, 0.35, 0.45, 0.6];

  @override
  Widget build(BuildContext context) {
    final tier = rankTier(rank);
    final color = rankColor(rank);
    final radius = BorderRadius.circular(6);
    final chip = Container(
      padding: EdgeInsets.symmetric(horizontal: fontSize * 0.6, vertical: fontSize * 0.2),
      decoration: BoxDecoration(
        color: tier == 3 ? null : color,
        // SSS in the website's gold.
        gradient: tier == 3
            ? const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFFFF3A6), Color(0xFFF9D84A), Color(0xFFF2A93B)], stops: [0, 0.45, 1])
            : null,
        borderRadius: radius,
      ),
      child: Text(rank ?? '—', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w800, fontSize: fontSize)),
    );
    if (tier == 0 || !animated) return chip;
    // SSS keeps its gold sparkles and white light; SS and S shine in their
    // own colour (a pale tint of it, with a glow of the colour itself).
    final light = tier == 3 ? Colors.white : Color.lerp(Colors.white, color, 0.35)!;
    final sparkle = tier == 3 ? const Color(0xFFFFF3A6) : Color.lerp(Colors.white, color, 0.45)!;
    final sparkleGlow = tier == 3 ? const Color(0xFFF9D84A) : color;
    return ShineTicker(builder: (context, t) {
      final pulse = t == null ? 0.5 : shinePulse(t, phase: tier * 0.21);
      final pos = t == null ? null : shineAt(t, period: _period[tier], delay: 0.15 * (3 - tier));
      final sparkles = t != null && fontSize >= 20;
      return Stack(clipBehavior: Clip.none, children: [
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            boxShadow: [BoxShadow(color: color.withValues(alpha: _glow[tier] * (0.5 + 0.5 * pulse)), blurRadius: fontSize * (0.6 + 0.6 * pulse))],
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: Stack(children: [
              chip,
              if (pos != null) Positioned.fill(child: ShineBand(position: pos, strength: _strength[tier], color: light)),
            ]),
          ),
        ),
        if (sparkles)
          for (final (dx, dy, size, phase) in _sparkles.take(tier))
            Positioned(
              left: null,
              right: dx * fontSize,
              top: dy * fontSize,
              child: Sparkle(
                size: size * fontSize,
                value: (shinePulse(t, period: 2.2, phase: phase) - 0.35).clamp(0.0, 1.0) / 0.65,
                color: sparkle,
                glow: sparkleGlow,
              ),
            ),
      ]);
    });
  }

  // (right, top, size, phase) as fractions of the font size, around the corners.
  static const _sparkles = [(-0.55, -0.5, 0.55, 0.0), (-0.35, 1.05, 0.4, 0.4), (2.4, -0.55, 0.45, 0.7)];
}
