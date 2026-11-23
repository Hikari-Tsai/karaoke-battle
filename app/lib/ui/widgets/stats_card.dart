// The gradient stats card at the top of the History and Library pages: a
// title, a line on the right (e.g. the date range) and tiles whose numbers
// count up, coming in one after another.
import 'package:flutter/material.dart';

import 'reveal.dart';
import 'shine.dart';

class StatsCard extends StatelessWidget {
  const StatsCard({super.key, required this.icon, required this.title, required this.tiles, this.trailing, this.onTrailingTap, this.trailingTooltip});
  final IconData icon;
  final String title;
  final String? trailing;

  /// Makes [trailing] a button (e.g. the History's date range, to change
  /// where the stats start).
  final VoidCallback? onTrailingTap;
  final String? trailingTooltip;
  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FadeSlideIn(
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFF3D1546), Color(0xFF241640), Color(0xFF16141F)]),
          border: Border.all(color: const Color(0x33C8BEFA)),
          boxShadow: const [BoxShadow(color: Color(0x44000000), blurRadius: 30, offset: Offset(0, 12))],
        ),
        child: Stack(children: [
          // A soft glow drifting across.
          Positioned.fill(
            child: ShineTicker(
              builder: (context, t) => DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(-0.8 + 1.6 * (t == null ? 0.5 : shinePulse(t, period: 12)), -0.6),
                    radius: 1.2,
                    colors: const [Color(0x33FF4FA3), Color(0x00FF4FA3)],
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 18, 22, 20),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Icon(icon, size: 20, color: const Color(0xFFC8BEFA)),
                const SizedBox(width: 8),
                Text(title, style: theme.textTheme.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
                const Spacer(),
                if (trailing != null)
                  onTrailingTap == null
                      ? Text(trailing!, style: theme.textTheme.labelMedium?.copyWith(color: const Color(0xFFAAA6BA)))
                      : Tooltip(
                          message: trailingTooltip ?? '',
                          child: Material(
                            color: const Color(0x1AFFFFFF),
                            shape: const StadiumBorder(side: BorderSide(color: Color(0x40C8BEFA))),
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: onTrailingTap,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                                child: Row(mainAxisSize: MainAxisSize.min, children: [
                                  const Icon(Icons.event_outlined, size: 15, color: Color(0xFFC8BEFA)),
                                  const SizedBox(width: 6),
                                  Text(trailing!, style: theme.textTheme.labelMedium?.copyWith(color: const Color(0xFFE6E1F2), fontWeight: FontWeight.w600)),
                                  const SizedBox(width: 4),
                                  const Icon(Icons.edit_outlined, size: 13, color: Color(0xFFAAA6BA)),
                                ]),
                              ),
                            ),
                          ),
                        ),
              ]),
              const SizedBox(height: 14),
              LayoutBuilder(builder: (context, c) {
                // All across when there is room, else three per row.
                final per = c.maxWidth >= 900 ? tiles.length : 3;
                const gap = 10.0;
                final w = (c.maxWidth - gap * (per - 1)) / per;
                return Wrap(spacing: gap, runSpacing: gap, children: [
                  for (final (i, t) in tiles.indexed)
                    SizedBox(width: w, child: FadeSlideIn(delay: Duration(milliseconds: 80 + 70 * i), offset: 12, child: t)),
                ]);
              }),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// One figure on a StatsCard: a coloured icon, a label, the number counting
/// up, an optional note under it; [highlight] frames it in its colour.
class StatTile extends StatefulWidget {
  const StatTile({
    super.key,
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    required this.format,
    this.note,
    this.valueColor,
    this.trailing,
    this.highlight = false,
    this.onTap,
    this.progress,
    this.noteLines = 1,
  });
  final IconData icon;
  final Color color;
  final String label;
  final double value;
  final String Function(double) format;
  final String? note;
  final Color? valueColor;
  final Widget? trailing;
  final bool highlight;
  final VoidCallback? onTap;

  /// 0..1: a bar under the number, filling as it counts up.
  final double? progress;

  /// Lines the note may take (2 keeps a tile without a bar as tall).
  final int noteLines;

  @override
  State<StatTile> createState() => StatTileState();
}

class StatTileState extends State<StatTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final w = widget;
    final border = w.highlight ? w.color.withValues(alpha: _hover ? 0.9 : 0.55) : const Color(0x1FFFFFFF);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        transform: Matrix4.translationValues(0, _hover && w.onTap != null ? -2 : 0, 0),
        decoration: BoxDecoration(
          color: const Color(0x14FFFFFF),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: border),
          boxShadow: [if (w.highlight) BoxShadow(color: w.color.withValues(alpha: _hover ? 0.3 : 0.15), blurRadius: 18)],
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: w.onTap,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [w.color, w.color.withValues(alpha: 0.5)]),
                      boxShadow: [BoxShadow(color: w.color.withValues(alpha: 0.35), blurRadius: 10)],
                    ),
                    child: Icon(w.icon, size: 15, color: const Color(0xFF111111)),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(w.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelMedium?.copyWith(color: const Color(0xFFC9C4D8))),
                  ),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: CountUp(
                        value: w.value,
                        format: w.format,
                        delay: const Duration(milliseconds: 150),
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w900,
                          color: w.valueColor ?? Colors.white,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ),
                  if (w.trailing != null) ...[const SizedBox(width: 6), w.trailing!],
                ]),
                if (w.progress case final progress?) ...[
                  const SizedBox(height: 8),
                  ProgressStrip(value: progress, color: w.color),
                ],
                if (w.note != null) ...[
                  const SizedBox(height: 2),
                  Text(w.note!, maxLines: w.noteLines, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: const Color(0xFFAAA6BA))),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }
}


/// A thin rounded bar filling to [value] (0..1) with the count-up, its
/// leading edge glowing.
class ProgressStrip extends StatelessWidget {
  const ProgressStrip({super.key, required this.value, required this.color, this.height = 6});
  final double value;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) => Entrance(
        delay: const Duration(milliseconds: 150),
        duration: const Duration(milliseconds: 1400),
        curve: Curves.easeOutCubic,
        builder: (context, t, _) => ClipRRect(
          borderRadius: BorderRadius.circular(height),
          child: SizedBox(
            height: height,
            width: double.infinity,
            child: Stack(children: [
              const Positioned.fill(child: ColoredBox(color: Color(0x1FFFFFFF))),
              FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: (value.clamp(0.0, 1.0) * t).toDouble(),
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(height),
                    gradient: LinearGradient(colors: [color.withValues(alpha: 0.55), color]),
                    boxShadow: [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 8)],
                  ),
                ),
              ),
            ]),
          ),
        ),
      );
}
