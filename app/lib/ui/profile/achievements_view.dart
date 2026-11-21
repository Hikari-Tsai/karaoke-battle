// Achievements on the profile page (by category, with progress to the next
// tier) and the pop-up when one is unlocked, shown over any page.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/achievements.dart';
import '../../services/dev_mode.dart';
import '../../services/settings.dart';
import '../../services/sing_history.dart' show formatDay;
import '../../state/i18n.dart';
import '../widgets/reveal.dart';
import '../widgets/achievement_events.dart';
import '../widgets/info_tip.dart';
import '../widgets/rank.dart' show rankColor;
import '../widgets/shine.dart';
import 'achievement_celebration.dart';

// A flat palette: solid colours, white icons, no gradients or glows.
const _bronze = Color(0xFFC9824E);
const _silver = Color(0xFF8C9AAE);
const _gold = Color(0xFFE5A823);
const _lockedFill = Color(0xFF2B2734);
const _lockedIcon = Color(0xFF5D5770);

/// Single goals take their category's colour.
const _categoryColor = {
  AchievementCategory.basics: Color(0xFF7DBE3C),
  AchievementCategory.total: Color(0xFF4A8BF5),
  AchievementCategory.skill: Color(0xFFE8577A),
  AchievementCategory.ranks: Color(0xFF26A9C8),
  AchievementCategory.progress: Color(0xFF23B28E),
  AchievementCategory.explore: Color(0xFF8B62E8),
  AchievementCategory.live: Color(0xFFE5484D),
  AchievementCategory.secret: Color(0xFFF08A3C),
};

/// The medal colour of [tier] (0: not yet).
Color medalColor(AchievementDef a, int tier) {
  if (tier == 0) return _lockedIcon;
  final rank = rankAchievements[a.id];
  if (rank != null) return rankColor(rank);
  if (!a.tiered) return _categoryColor[a.category]!;
  return [_bronze, _silver, _gold][tier - 1];
}

/// Secret achievements show what they ask for in debug builds with 開發模式 on.
bool _revealSecrets(BuildContext context) => devFeatures(context.watch<AppSettings>());

/// Achievements that share one note.
const _noteGroups = {
  'fullPitch': 'full', 'fullRhythm': 'full', 'fullStability': 'full', 'fullExpression': 'full', 'fullLongTone': 'full',
  'firstD': 'rank', 'firstC': 'rank', 'firstB': 'rank', 'firstA': 'rank', 'rankS': 'rank', 'rankSS': 'rank', 'rankSSS': 'rank',
  'firstLive': 'live', 'liveSongs': 'live',
};

/// What needs saying about how [a] is judged (shown behind a circled i), or
/// null when its description says it all.
String? achievementNote(AchievementDef a) {
  final key = 'ach.note.${_noteGroups[a.id] ?? a.id}';
  return trHas(key) ? tr(key) : null;
}

String _tierName(AchievementDef a, int tier) => a.tiered ? tr('ach.tier$tier') : tr('ach.done');

String _number(AchievementDef a, num v) => a.id == 'hours' ? (v is int || v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1)) : '${v.floor()}';

/// All achievements, by category, with the points so far.
class AchievementsSection extends StatelessWidget {
  const AchievementsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final svc = context.watch<AchievementService>();
    final total = achievements.fold<int>(0, (a, d) => a + d.thresholds.length);
    final done = svc.unlocked.length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      FadeSlideIn(
        child: Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: const BoxDecoration(shape: BoxShape.circle, color: _gold),
            child: const Icon(Icons.emoji_events, size: 20, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Text(tr('ach.title'), style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
          const Spacer(),
          _Pill(icon: Icons.military_tech, text: tr('ach.count', {'n': done, 'total': total})),
          const SizedBox(width: 8),
          _Pill(icon: Icons.stars, text: tr('ach.points', {'n': svc.points}), color: _gold),
        ]),
      ),
      for (final cat in AchievementCategory.values) ...[
        const SizedBox(height: 22),
        FadeSlideIn(
          child: Text(tr('ach.cat.${cat.name}'), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, color: cs.onSurfaceVariant)),
        ),
        const SizedBox(height: 10),
        LayoutBuilder(builder: (context, c) {
          final per = c.maxWidth >= 900 ? 3 : (c.maxWidth >= 560 ? 2 : 1);
          const gap = 12.0;
          final w = (c.maxWidth - gap * (per - 1)) / per;
          final list = [for (final a in achievements) if (a.category == cat) a];
          return Wrap(spacing: gap, runSpacing: gap, children: [
            for (final (i, a) in list.indexed)
              SizedBox(
                width: w,
                child: FadeSlideIn(delay: Duration(milliseconds: 50 * i), offset: 10, child: _AchievementTile(def: a, index: i, tier: svc.tierOf(a), value: svc.values[a.id] ?? 0, dates: [for (var t = 1; t <= a.thresholds.length; t++) svc.unlocked[a.key(t)]])),
              ),
          ]);
        }),
      ],
    ]);
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text, this.color});
  final IconData icon;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(999), border: Border.all(color: c.withValues(alpha: 0.4))),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: c),
        const SizedBox(width: 6),
        Text(text, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: c, fontWeight: FontWeight.w800)),
      ]),
    );
  }
}

/// A medal: the achievement's icon, white on a flat disc of its tier's (or
/// category's) colour; dim while locked, a padlock while secret.
class AchievementMedal extends StatelessWidget {
  const AchievementMedal({super.key, required this.def, required this.tier, this.size = 48, this.reveal = false});
  final AchievementDef def;
  final int tier;
  final double size;

  /// Show a locked secret's own icon (開發模式).
  final bool reveal;

  @override
  Widget build(BuildContext context) {
    final locked = tier == 0;
    final secret = locked && def.hidden && !reveal;
    final fill = locked ? _lockedFill : medalColor(def, tier);
    final rank = rankAchievements[def.id];
    // A rank's medal shows the rank itself, dark on the light SSS gold.
    final ink = locked ? _lockedIcon : (fill.computeLuminance() > 0.62 ? const Color(0xFF3A2E00) : Colors.white);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(shape: BoxShape.circle, color: fill),
      child: rank != null && !secret
          ? Text(
              rank,
              maxLines: 1,
              style: TextStyle(fontSize: size * const [0.5, 0.4, 0.31][rank.length - 1], fontWeight: FontWeight.w900, color: ink, height: 1, letterSpacing: -size * 0.01, decoration: TextDecoration.none),
            )
          : Icon(secret ? Icons.lock : def.icon, size: size * 0.48, color: ink),
    );
  }
}

class _AchievementTile extends StatefulWidget {
  const _AchievementTile({required this.def, required this.tier, required this.value, this.dates = const [], this.index = 0});
  final AchievementDef def;
  final int tier;
  final double value;

  /// When each tier was unlocked (null: not yet).
  final List<DateTime?> dates;

  /// Its place in the category: the entrance follows the cards' fade-in.
  final int index;

  @override
  State<_AchievementTile> createState() => _AchievementTileState();
}

class _AchievementTileState extends State<_AchievementTile> {
  bool _hover = false;

  /// The tier picked with the dots (1-based); null shows the next to reach.
  int? _view;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final def = widget.def, tier = widget.tier, value = widget.value;
    final revealed = def.hidden && tier == 0 && _revealSecrets(context);
    final secret = def.hidden && tier == 0 && !revealed;
    final maxed = tier >= def.thresholds.length;
    // The tier shown: picked with the dots, else the next to reach (or the
    // last one, when all are done).
    final shown = _view ?? (maxed ? def.thresholds.length : tier + 1);
    final reached = shown <= tier;
    final next = def.thresholds[shown - 1];
    final progress = reached ? 1.0 : (value / next).clamp(0.0, 1.0);
    final c = def.tiered ? [_bronze, _silver, _gold][shown - 1] : _categoryColor[def.category]!;
    final shownDate = shown - 1 < widget.dates.length ? widget.dates[shown - 1] : null;
    final delay = Duration(milliseconds: 120 + 50 * widget.index);
    final border = tier > 0 ? medalColor(def, tier) : cs.outlineVariant;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      // Lifts a little under the pointer, its border brighter.
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        transform: Matrix4.translationValues(0, _hover ? -3 : 0, 0),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _hover ? cs.surfaceContainerHigh : cs.surfaceContainer,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: border.withValues(alpha: tier > 0 ? (_hover ? 0.9 : 0.5) : (_hover ? 0.5 : 0.25))),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // The medal pops in; an unlocked one catches the light now and then.
          Entrance(
            delay: delay,
            duration: const Duration(milliseconds: 650),
            curve: Curves.easeOutBack,
            builder: (context, t, child) => Transform.scale(scale: 0.6 + 0.4 * t, child: Opacity(opacity: t.clamp(0.0, 1.0), child: child)),
            child: _ShiningMedal(def: def, tier: tier, reveal: revealed),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Row(children: [
                    Flexible(
                      child: Text(
                        secret ? '???' : tr('ach.${def.id}.name'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                    // How it is judged, where that needs saying (secrets only once seen).
                    if (!secret)
                      if (achievementNote(def) case final note?) InfoTip(sections: [(tr('ach.${def.id}.name'), note)], size: 15),
                  ]),
                ),
                if (tier > 0)
                  TierBadge(def: def, tier: tier, size: 20)
                else if (revealed)
                  // Only in debug builds with 開發模式 on.
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(color: cs.tertiary.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(4)),
                    child: Text(tr('dev.mode'), style: theme.textTheme.labelSmall?.copyWith(color: cs.tertiary, fontWeight: FontWeight.w700)),
                  ),
              ]),
              const SizedBox(height: 2),
              Text(
                secret ? tr('ach.secretDesc') : tr('ach.${def.id}.desc', {'n': _number(def, next)}),
                style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
              if (!secret && def.tiered) ...[
                const SizedBox(height: 8),
                // The bar fills and the count runs up to where it stands.
                Entrance(
                  delay: delay,
                  duration: const Duration(milliseconds: 1100),
                  curve: Curves.easeOutCubic,
                  builder: (context, t, _) => Row(children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(value: progress * t, minHeight: 6, color: c, backgroundColor: cs.onSurface.withValues(alpha: 0.08)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      reached
                          ? (shownDate != null ? tr('ach.on', {'date': formatDay(shownDate.toLocal())}) : tr('ach.done'))
                          : '${_number(def, value * t)} / ${_number(def, next)}',
                      style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                  ]),
                ),
                const SizedBox(height: 6),
                // The tiers, filled as they are reached; click one to see it
                // (again to go back to the next one to reach).
                Row(children: [
                  for (var t = 1; t <= def.thresholds.length; t++)
                    Tooltip(
                      message: '${tr('ach.tier$t')} · ${tr('ach.${def.id}.desc', {'n': _number(def, def.thresholds[t - 1])})}',
                      waitDuration: const Duration(milliseconds: 400),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(() => _view = _view == t ? null : t),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(0, 3, 6, 3),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 160),
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: t <= tier ? [_bronze, _silver, _gold][t - 1] : cs.onSurface.withValues(alpha: 0.12),
                                // The tier on show is ringed.
                                border: Border.all(color: t == shown ? cs.onSurface : Colors.transparent, width: 2),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  const Spacer(),
                  Text('+${def.pointsOf(shown)}', style: theme.textTheme.labelSmall?.copyWith(color: _gold, fontWeight: FontWeight.w700)),
                ]),
              ] else if (!secret) ...[
                const SizedBox(height: 6),
                Text(
                  tier > 0 && shownDate != null ? '${tr('ach.on', {'date': formatDay(shownDate.toLocal())})} · +${def.pointsOf(1)}' : '+${def.pointsOf(1)}',
                  style: theme.textTheme.labelSmall?.copyWith(color: tier > 0 ? medalColor(def, 1) : _gold, fontWeight: FontWeight.w700),
                ),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

/// A tier as a small rosette: a flat disc in bronze, silver or gold with two
/// ribbon tails and a white star (a check for single goals, in the medal's
/// colour); its name in a tooltip.
class TierBadge extends StatelessWidget {
  const TierBadge({super.key, required this.def, required this.tier, this.size = 20});
  final AchievementDef def;
  final int tier;
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: _tierName(def, tier),
        child: CustomPaint(size: Size(size, size * 1.25), painter: _TierBadgePainter(medalColor(def, tier), star: def.tiered)),
      );
}

class _TierBadgePainter extends CustomPainter {
  _TierBadgePainter(this.color, {required this.star});
  final Color color;
  final bool star;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    Offset at(double x, double y) => Offset(x * s, y * s);
    final tail = Paint()..color = Color.lerp(color, Colors.black, 0.28)!;
    // Two ribbon tails, notched at the end.
    for (final m in const [1.0, -1.0]) {
      double x(double v) => m == 1 ? v : 1 - v;
      canvas.drawPath(
        Path()
          ..moveTo(at(x(0.30), 0.55).dx, at(x(0.30), 0.55).dy)
          ..lineTo(at(x(0.50), 0.62).dx, at(x(0.50), 0.62).dy)
          ..lineTo(at(x(0.42), 1.24).dx, at(x(0.42), 1.24).dy)
          ..lineTo(at(x(0.30), 1.12).dx, at(x(0.30), 1.12).dy)
          ..lineTo(at(x(0.16), 1.20).dx, at(x(0.16), 1.20).dy)
          ..close(),
        tail,
      );
    }
    final c = at(0.5, 0.46);
    final r = s * 0.44;
    canvas.drawCircle(c, r, Paint()..color = color);
    canvas.drawCircle(
      c,
      r * 0.76,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.05
        ..color = Colors.white.withValues(alpha: 0.45),
    );
    final white = Paint()..color = Colors.white;
    if (star) {
      final path = Path();
      for (var i = 0; i < 10; i++) {
        final a = -math.pi / 2 + i * math.pi / 5;
        final rr = (i.isEven ? 0.42 : 0.18) * r;
        final p = c + Offset(math.cos(a) * rr, math.sin(a) * rr);
        i == 0 ? path.moveTo(p.dx, p.dy) : path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path..close(), white);
    } else {
      canvas.drawPath(
        Path()
          ..moveTo(c.dx - r * 0.36, c.dy + r * 0.02)
          ..lineTo(c.dx - r * 0.10, c.dy + r * 0.28)
          ..lineTo(c.dx + r * 0.38, c.dy - r * 0.26),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * 0.09
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = Colors.white,
      );
    }
  }

  @override
  bool shouldRepaint(_TierBadgePainter old) => old.color != color || old.star != star;
}

/// A medal; once unlocked, a band of light crosses it every few seconds
/// (each medal at its own moment, so they do not all flash together).
class _ShiningMedal extends StatelessWidget {
  const _ShiningMedal({required this.def, required this.tier, required this.reveal});
  final AchievementDef def;
  final int tier;
  final bool reveal;

  @override
  Widget build(BuildContext context) {
    final medal = AchievementMedal(def: def, tier: tier, reveal: reveal);
    if (tier == 0) return medal;
    final offset = (def.id.hashCode % 50) / 10; // 0..5 s
    return ClipOval(
      child: Stack(children: [
        medal,
        Positioned.fill(
          child: ShineTicker(
            builder: (context, t) {
              final pos = t == null ? null : shineAt(t, period: 5.2, window: 0.22, delay: offset);
              return pos == null ? const SizedBox.shrink() : ShineBand(position: pos, strength: 0.45);
            },
          ),
        ),
      ]),
    );
  }
}

/// Shows the full-screen celebration for new unlocks, over any page, once
/// no screen is holding it back (singing, the score reveal); what unlocks
/// meanwhile is shown together. A first run gives one summary.
class AchievementPopups extends StatefulWidget {
  const AchievementPopups({super.key, required this.child});
  final Widget child;

  @override
  State<AchievementPopups> createState() => _AchievementPopupsState();
}

class _AchievementPopupsState extends State<AchievementPopups> {
  late final AchievementService _svc = context.read<AchievementService>();
  StreamSubscription<List<AchievementUnlock>>? _sub;
  final _pending = <AchievementUnlock>[];
  bool _summaryPending = false;
  bool _showing = false;
  static bool _summaryShown = false;

  @override
  void initState() {
    super.initState();
    _sub = _svc.unlocks.listen(_onUnlocks);
    _svc.addListener(_onService);
    AchievementHold.notifier.addListener(_onHold);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onService());
  }

  @override
  void dispose() {
    _sub?.cancel();
    _svc.removeListener(_onService);
    AchievementHold.notifier.removeListener(_onHold);
    super.dispose();
  }

  void _onService() {
    if (_summaryShown || _svc.firstRunCount == 0) return;
    _summaryShown = true;
    _summaryPending = true;
    _pump();
  }

  void _onUnlocks(List<AchievementUnlock> list) {
    _pending.addAll(list);
    _pump();
  }

  // A screen let go: wait a moment, the next one (results after singing)
  // may take hold straight away.
  void _onHold() {
    if (!AchievementHold.active) Future<void>.delayed(const Duration(milliseconds: 500), _pump);
  }

  void _pump() {
    if (!mounted || _showing || AchievementHold.active) return;
    if (!_summaryPending && _pending.isEmpty) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final summary = _summaryPending;
    final batch = summary ? const <AchievementUnlock>[] : List.of(_pending);
    if (summary) {
      _summaryPending = false;
    } else {
      _pending.clear();
    }
    _showing = true;
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => AchievementCelebration(
        unlocks: batch,
        summaryCount: summary ? _svc.firstRunCount : 0,
        summaryPoints: summary ? _svc.points : 0,
        onDone: () {
          entry.remove();
          _showing = false;
          Future<void>.delayed(const Duration(milliseconds: 300), _pump);
        },
      ),
    );
    overlay.insert(entry);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
