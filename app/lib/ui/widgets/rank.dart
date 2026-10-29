// Rank colours and the small rank chip shared by the results and library screens.
import 'package:flutter/material.dart';

Color rankColor(String? rank) => switch (rank) {
      'SSS' || 'SS' => const Color(0xFFFFD60A),
      'S' => const Color(0xFFFF9F0A),
      'A' => const Color(0xFF4CD964),
      'B' => const Color(0xFF5AC8FA),
      'C' => const Color(0xFFB0B8C4),
      _ => const Color(0xFF8E8E93),
    };

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
