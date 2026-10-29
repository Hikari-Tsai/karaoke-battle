// Scoring rules for singers: plain-language tips per sub-score, the rank
// table, practical hints and a link to the full algorithm document.
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/update_checker.dart';
import '../../state/i18n.dart';
import '../widgets/rank.dart';
import '../widgets/brand.dart';

class RulesScreen extends StatelessWidget {
  const RulesScreen({super.key});

  /// The scoring document in the current UI language
  /// (docs/SCORING.md is Traditional Chinese, .en / .ja are translations).
  static String scoringDocUrl([String? lang]) {
    final file = switch (lang ?? I18n.lang) {
      'en' => 'SCORING.en.md',
      'ja' => 'SCORING.ja.md',
      _ => 'SCORING.md',
    };
    return '${UpdateChecker.repoUrl}/blob/main/docs/$file';
  }

  // (i18n key suffix, weight %, icon)
  static const _items = <(String, int, IconData)>[
    ('pitch', 40, Icons.music_note),
    ('rhythm', 20, Icons.timer_outlined),
    ('stability', 10, Icons.horizontal_rule),
    ('vibrato', 10, Icons.waves),
    ('expression', 10, Icons.volume_up_outlined),
    ('longTone', 10, Icons.straighten),
  ];

  static const _ranks = <(String, String)>[
    ('SSS', '≥ 97'),
    ('SS', '≥ 92'),
    ('S', '≥ 85'),
    ('A', '≥ 75'),
    ('B', '≥ 60'),
    ('C', '≥ 40'),
    ('D', '< 40'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Scaffold(
      appBar: AppBar(title: BrandedTitle(tr('rules.title'))),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          // --- ranks --------------------------------------------------------------
          Text(tr('rules.ranks'), style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final r in _ranks)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: rankColor(r.$1).withValues(alpha: 0.15),
                    border: Border.all(color: rankColor(r.$1).withValues(alpha: 0.7)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    RankChip(rank: r.$1),
                    const SizedBox(width: 8),
                    Text(r.$2, style: theme.textTheme.titleMedium?.copyWith(color: rankColor(r.$1), fontWeight: FontWeight.w700)),
                  ]),
                ),
            ],
          ),
          const SizedBox(height: 20),

          Text(tr('rules.intro'), style: theme.textTheme.bodyLarge),
          const SizedBox(height: 20),

          // --- six sub-scores --------------------------------------------------
          Text(tr('rules.howToScore'), style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          for (final it in _items)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: CircleAvatar(backgroundColor: cs.primaryContainer, child: Icon(it.$3, color: cs.onPrimaryContainer)),
                title: Row(children: [
                  Text(tr('results.${it.$1}'), style: theme.textTheme.titleMedium),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(color: cs.secondaryContainer, borderRadius: BorderRadius.circular(4)),
                    child: Text('${it.$2}%', style: theme.textTheme.labelSmall?.copyWith(color: cs.onSecondaryContainer)),
                  ),
                ]),
                subtitle: Padding(padding: const EdgeInsets.only(top: 4), child: Text(tr('rules.${it.$1}'))),
              ),
            ),
          const SizedBox(height: 12),

          // --- the three forgiving rules ------------------------------------------
          Card(
            color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr('rules.forgivingTitle'), style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  _Bullet(text: tr('rules.octave')),
                  _Bullet(text: tr('rules.transpose')),
                  _Bullet(text: tr('rules.slides')),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // --- practical tips -------------------------------------------------------
          Text(tr('rules.tips'), style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          _Bullet(text: tr('rules.tipHeadphones')),
          _Bullet(text: tr('rules.tipMic')),
          _Bullet(text: tr('rules.tipPreview')),
          _Bullet(text: tr('rules.tipSilence')),
          _Bullet(text: tr('rules.tipKey')),
          const SizedBox(height: 24),

          // --- full algorithm -----------------------------------------------------------
          Row(children: [
            FilledButton.tonalIcon(
              onPressed: () => launchUrl(Uri.parse(scoringDocUrl())),
              icon: const Icon(Icons.menu_book),
              label: Text(tr('rules.fullDoc')),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(tr('rules.fullDocHint'), style: theme.textTheme.bodySmall)),
          ]),
        ],
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(padding: EdgeInsets.only(top: 7, right: 10), child: Icon(Icons.circle, size: 7)),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
