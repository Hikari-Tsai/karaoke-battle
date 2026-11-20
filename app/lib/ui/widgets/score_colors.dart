// One colour per sub-score, the same everywhere it is shown: the scoring
// rules, the results card's bars and the share / replay cards.
import 'package:flutter/material.dart';

/// [key] in either spelling ('longTone' or 'long_tone').
Color subScoreColor(String key) => switch (key) {
      'pitch' => const Color(0xFFBF5AF2), // violet
      'rhythm' => const Color(0xFFFF4FA3), // pink
      'stability' => const Color(0xFF64D2FF), // blue
      'vibrato' => const Color(0xFF30D158), // green
      'expression' => const Color(0xFFFF9F0A), // orange
      'longTone' || 'long_tone' => const Color(0xFFF9D84A), // yellow
      _ => const Color(0xFF9A9FA8),
    };
