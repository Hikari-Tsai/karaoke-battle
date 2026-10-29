// Rank colours and the small rank chip shared by the results and library screens.
import 'package:flutter/material.dart';

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

class RankChip extends StatelessWidget {
  const RankChip({super.key, required this.rank, this.fontSize = 14});
  final String? rank;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: fontSize * 0.6, vertical: fontSize * 0.2),
      decoration: BoxDecoration(color: rankColor(rank), borderRadius: BorderRadius.circular(6)),
      child: Text(rank ?? '—', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w800, fontSize: fontSize)),
    );
  }
}
