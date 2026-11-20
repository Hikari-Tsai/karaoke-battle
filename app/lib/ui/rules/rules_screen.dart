// Scoring rules for singers: the ranks, how each sub-score is earned and
// weighted, what is not penalised, the SSS demo songs, practical tips and a
// link to the full algorithm document. Sections rise into view as the page
// scrolls (and again each time the tab is opened).
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/update_checker.dart';
import '../../state/i18n.dart';
import '../widgets/brand.dart';
import '../widgets/rank.dart';
import '../widgets/reveal.dart';
import '../widgets/shine.dart';
import 'sss_demos.dart';

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

  // (i18n key suffix, weight %, icon, colour)
  static const _items = <(String, int, IconData, Color)>[
    ('pitch', 40, Icons.music_note, Color(0xFFBF5AF2)),
    ('rhythm', 20, Icons.timer_outlined, Color(0xFFFF4FA3)),
    ('stability', 10, Icons.horizontal_rule, Color(0xFF64D2FF)),
    ('vibrato', 10, Icons.waves, Color(0xFF30D158)),
    ('expression', 10, Icons.volume_up_outlined, Color(0xFFFF9F0A)),
    ('longTone', 10, Icons.straighten, Color(0xFFF9D84A)),
  ];

  static const _ranks = <(String, String)>[
    ('SSS', '≥ 98'),
    ('SS', '≥ 95'),
    ('S', '≥ 91'),
    ('A', '≥ 86'),
    ('B', '≥ 78'),
    ('C', '≥ 67'),
    ('D', '< 67'),
  ];

  static const _tips = <(String, IconData)>[
    ('tipHeadphones', Icons.headphones),
    ('tipMic', Icons.mic_none),
    ('tipPreview', Icons.visibility_outlined),
    ('tipSilence', Icons.graphic_eq),
    ('tipKey', Icons.tune),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: BrandedTitle(tr('rules.title'))),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 28),
        children: [
          const _Page(child: FadeSlideIn(child: _Hero())),
          // --- ranks --------------------------------------------------------------
          _Page(child: _Section(icon: Icons.military_tech_outlined, title: tr('rules.ranks'), child: const _RankLadder())),
          // --- six sub-scores and their weights -----------------------------------
          _Page(child: _Section(icon: Icons.tune, title: tr('rules.howToScore'), child: const _ScoreItems())),
          // --- what is not penalised ---------------------------------------------
          const _Page(child: FadeSlideIn(child: _Forgiving())),
          // --- SSS demo songs (as on the website), downloadable as replays --------
          _Page(
            child: _Section(
              icon: Icons.emoji_events_outlined,
              title: tr('demo.title'),
              subtitle: tr('demo.lead'),
              child: const SssDemos(),
            ),
          ),
          // --- practical tips -------------------------------------------------------
          _Page(child: _Section(icon: Icons.lightbulb_outline, title: tr('rules.tips'), child: const _Tips())),
          // --- full algorithm -----------------------------------------------------------
          const _Page(child: FadeSlideIn(child: _FullDoc())),
        ],
      ),
    );
  }
}

/// Centres a section at a readable width with the page's side margins.
class _Page extends StatelessWidget {
  const _Page({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1080),
          child: Padding(padding: const EdgeInsets.fromLTRB(32, 0, 32, 36), child: child),
        ),
      );
}

/// A section heading (icon in a tinted circle, title, optional line) above
/// its content; the heading rises in first.
class _Section extends StatelessWidget {
  const _Section({required this.icon, required this.title, required this.child, this.subtitle});
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      FadeSlideIn(
        child: Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(shape: BoxShape.circle, color: cs.primary.withValues(alpha: 0.16)),
            child: Icon(icon, size: 20, color: cs.primary),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(title, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800))),
        ]),
      ),
      if (subtitle != null)
        FadeSlideIn(
          delay: const Duration(milliseconds: 80),
          child: Padding(
            padding: const EdgeInsets.only(left: 48, top: 4),
            child: Text(subtitle!, style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
          ),
        ),
      const SizedBox(height: 18),
      child,
    ]);
  }
}

/// The page's banner: title, what the score is about, and a floating,
/// shining SSS.
class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF4A1550), Color(0xFF2A1640), Color(0xFF151320)]),
        border: Border.all(color: const Color(0x33C8BEFA)),
        boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 40, offset: Offset(0, 16))],
      ),
      child: Stack(children: [
        // A soft moving glow behind the text.
        Positioned.fill(
          child: ShineTicker(
            builder: (context, t) => DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment(-0.6 + 0.5 * (t == null ? 0.5 : shinePulse(t, period: 9)), -0.4),
                  radius: 1.1,
                  colors: const [Color(0x40FF4FA3), Color(0x00FF4FA3)],
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(36, 32, 36, 32),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('KARAOKE BATTLE', style: theme.textTheme.labelMedium?.copyWith(color: const Color(0xFFC8BEFA), letterSpacing: 2.4, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text(tr('rules.title'), style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w900, color: Colors.white)),
                const SizedBox(height: 14),
                Text(tr('rules.intro'), style: theme.textTheme.bodyLarge?.copyWith(color: const Color(0xFFE6E1F2), height: 1.7)),
              ]),
            ),
            const SizedBox(width: 32),
            const Bob(
              amplitude: 6,
              child: Padding(padding: EdgeInsets.all(20), child: RankChip(rank: 'SSS', fontSize: 44)),
            ),
          ]),
        ),
      ]),
    );
  }
}

/// The seven ranks from SSS down, popping in one after another.
class _RankLadder extends StatelessWidget {
  const _RankLadder();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final ranks = RulesScreen._ranks;
    Widget tile(int i) {
      final (rank, threshold) = ranks[i];
      final c = rankColor(rank);
      return Entrance(
        delay: Duration(milliseconds: 70 * i),
        duration: const Duration(milliseconds: 700),
        curve: Curves.easeOutBack,
        builder: (context, t, child) => Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.scale(scale: 0.7 + 0.3 * t, child: child),
        ),
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 16, 10, 0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [c.withValues(alpha: 0.20), c.withValues(alpha: 0.05)]),
            border: Border.all(color: c.withValues(alpha: 0.5)),
          ),
          child: Column(children: [
            RankChip(rank: rank, fontSize: 20),
            const SizedBox(height: 10),
            Text(threshold, style: theme.textTheme.titleMedium?.copyWith(color: c, fontWeight: FontWeight.w800, fontFeatures: const [FontFeature.tabularFigures()])),
            const SizedBox(height: 12),
            Container(height: 4, decoration: BoxDecoration(color: c, borderRadius: const BorderRadius.vertical(top: Radius.circular(4)))),
          ]),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      LayoutBuilder(builder: (context, c) {
        if (c.maxWidth >= 640) {
          return Row(children: [
            for (var i = 0; i < ranks.length; i++) ...[if (i > 0) const SizedBox(width: 10), Expanded(child: tile(i))],
          ]);
        }
        final w = (c.maxWidth - 30) / 4;
        return Wrap(spacing: 10, runSpacing: 10, children: [for (var i = 0; i < ranks.length; i++) SizedBox(width: w, child: tile(i))]);
      }),
      const SizedBox(height: 14),
      FadeSlideIn(
        delay: const Duration(milliseconds: 400),
        child: Text(tr('rules.scale'), style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
      ),
    ]);
  }
}

/// The weights as one bar growing in, then a card per sub-score.
class _ScoreItems extends StatelessWidget {
  const _ScoreItems();

  @override
  Widget build(BuildContext context) {
    final items = RulesScreen._items;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // --- the weights, 100 % in all ---
      Entrance(
        duration: const Duration(milliseconds: 1200),
        builder: (context, t, child) => ClipRect(child: Align(alignment: Alignment.centerLeft, widthFactor: t, child: child)),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            height: 34,
            child: Row(children: [
              for (final (i, it) in items.indexed) ...[
                if (i > 0) const SizedBox(width: 2),
                Expanded(
                  flex: it.$2,
                  child: ColoredBox(
                    color: it.$4,
                    child: Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text(
                            it.$2 >= 20 ? '${tr('results.${it.$1}')} ${it.$2}%' : '${it.$2}%',
                            style: const TextStyle(color: Color(0xFF111111), fontWeight: FontWeight.w800, fontSize: 13),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ]),
          ),
        ),
      ),
      const SizedBox(height: 18),
      LayoutBuilder(builder: (context, c) {
        final per = c.maxWidth >= 900 ? 3 : (c.maxWidth >= 560 ? 2 : 1);
        final rows = <Widget>[];
        for (var r = 0; r * per < items.length; r++) {
          if (r > 0) rows.add(const SizedBox(height: 14));
          rows.add(IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (var k = 0; k < per; k++) ...[
                if (k > 0) const SizedBox(width: 14),
                Expanded(
                  child: r * per + k < items.length
                      ? FadeSlideIn(delay: Duration(milliseconds: 90 * (r * per + k)), child: _ItemCard(item: items[r * per + k]))
                      : const SizedBox.shrink(),
                ),
              ],
            ]),
          ));
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
      }),
    ]);
  }
}

class _ItemCard extends StatefulWidget {
  const _ItemCard({required this.item});
  final (String, int, IconData, Color) item;

  @override
  State<_ItemCard> createState() => _ItemCardState();
}

class _ItemCardState extends State<_ItemCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final (key, weight, icon, color) = widget.item;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
        transform: Matrix4.translationValues(0, _hover ? -3 : 0, 0),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: cs.surfaceContainer,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _hover ? color.withValues(alpha: 0.6) : cs.outlineVariant.withValues(alpha: 0.4)),
          boxShadow: [if (_hover) BoxShadow(color: color.withValues(alpha: 0.18), blurRadius: 24)],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [color, color.withValues(alpha: 0.55)]),
                boxShadow: [BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: 14)],
              ),
              child: Icon(icon, color: const Color(0xFF111111), size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(tr('results.$key'), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800))),
            Text('$weight%', style: theme.textTheme.titleMedium?.copyWith(color: color, fontWeight: FontWeight.w900)),
          ]),
          const SizedBox(height: 10),
          // The weight against pitch's 40 %, filling in.
          Entrance(
            delay: const Duration(milliseconds: 250),
            duration: const Duration(milliseconds: 1100),
            builder: (context, t, _) => ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: SizedBox(
                height: 6,
                child: Stack(fit: StackFit.expand, children: [
                  ColoredBox(color: cs.onSurface.withValues(alpha: 0.08)),
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: weight / 40 * t,
                    child: DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(colors: [color.withValues(alpha: 0.6), color]))),
                  ),
                  if (t >= 1) BarShine(fraction: weight / 40),
                ]),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(tr('rules.$key'), style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant, height: 1.6)),
        ]),
      ),
    );
  }
}

/// What is not penalised, with a tick each.
class _Forgiving extends StatelessWidget {
  const _Forgiving();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const green = Color(0xFF30D158);
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [green.withValues(alpha: 0.14), green.withValues(alpha: 0.03)]),
        border: Border.all(color: green.withValues(alpha: 0.35)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.verified_outlined, color: green),
          const SizedBox(width: 10),
          Text(tr('rules.forgivingTitle'), style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: 14),
        for (final (i, k) in ['octave', 'transpose', 'slides', 'lyrics'].indexed)
          FadeSlideIn(
            delay: Duration(milliseconds: 120 + 90 * i),
            offset: 10,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Padding(padding: EdgeInsets.only(top: 1), child: Icon(Icons.check_circle, size: 20, color: green)),
                const SizedBox(width: 10),
                Expanded(child: Text(tr('rules.$k'), style: theme.textTheme.bodyLarge?.copyWith(height: 1.5))),
              ]),
            ),
          ),
      ]),
    );
  }
}

/// The practical tips as cards with an icon each.
class _Tips extends StatelessWidget {
  const _Tips();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final tips = RulesScreen._tips;
    return LayoutBuilder(builder: (context, c) {
      final per = c.maxWidth >= 900 ? 3 : (c.maxWidth >= 560 ? 2 : 1);
      final w = (c.maxWidth - 14 * (per - 1)) / per;
      return Wrap(spacing: 14, runSpacing: 14, children: [
        for (final (i, (key, icon)) in tips.indexed)
          SizedBox(
            width: w,
            child: FadeSlideIn(
              delay: Duration(milliseconds: 80 * i),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: cs.surfaceContainer,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: cs.secondaryContainer),
                    child: Icon(icon, size: 20, color: cs.onSecondaryContainer),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(tr('rules.$key'), style: theme.textTheme.bodyMedium?.copyWith(height: 1.55))),
                ]),
              ),
            ),
          ),
      ]);
    });
  }
}

/// The link to the full algorithm document.
class _FullDoc extends StatelessWidget {
  const _FullDoc();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: cs.surfaceContainerHigh,
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Row(children: [
        Icon(Icons.menu_book, size: 32, color: cs.primary),
        const SizedBox(width: 16),
        Expanded(child: Text(tr('rules.fullDocHint'), style: theme.textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant))),
        const SizedBox(width: 16),
        FilledButton.icon(
          onPressed: () => launchUrl(Uri.parse(RulesScreen.scoringDocUrl())),
          icon: const Icon(Icons.open_in_new, size: 18),
          label: Text(tr('rules.fullDoc')),
        ),
      ]),
    );
  }
}
