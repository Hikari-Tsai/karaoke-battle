// Circled-i icon placed after a setting's title; hovering shows a short
// explanation made of titled sections.
import 'package:flutter/material.dart';

class InfoTip extends StatelessWidget {
  const InfoTip({super.key, required this.sections, this.footer});

  /// (heading, body) pairs.
  final List<(String, String)> sections;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spans = <InlineSpan>[];
    for (var i = 0; i < sections.length; i++) {
      final (head, body) = sections[i];
      spans
        ..add(TextSpan(text: '$head\n', style: const TextStyle(fontWeight: FontWeight.w700)))
        ..add(TextSpan(text: body));
      if (i < sections.length - 1) spans.add(const TextSpan(text: '\n\n'));
    }
    if (footer != null) spans.add(TextSpan(text: '\n\n$footer', style: const TextStyle(fontStyle: FontStyle.italic)));
    return Tooltip(
      richMessage: TextSpan(children: spans),
      padding: const EdgeInsets.all(12),
      constraints: const BoxConstraints(maxWidth: 400),
      waitDuration: const Duration(milliseconds: 200),
      showDuration: const Duration(seconds: 25),
      child: MouseRegion(
        cursor: SystemMouseCursors.help,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Icon(Icons.info_outline, size: 18, color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}
