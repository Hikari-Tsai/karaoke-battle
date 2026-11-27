// 觀眾加油, full screen: when a viewer's donation comes in, the screen dims, a
// heart pops in with a burst, who gave how much (and their message) comes
// in, and the song's score counts up from what it was to what it is now,
// its rank changing on the way. A click, Esc, Enter or Space closes it, and
// it closes by itself. Like the item and achievement celebrations, it waits
// while a song or a score reveal holds the screen.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../scoring/models.dart' show rankForTotal;
import '../../services/cheer.dart';
import '../../services/ecpay_alert.dart' show Donation;
import '../../services/settings.dart';
import '../../state/i18n.dart';
import '../profile/achievement_celebration.dart' show CelebrationBurstPainter;
import '../results/score_reveal.dart' show ResultSfx;
import '../widgets/achievement_events.dart' show AchievementHold;
import '../widgets/live_score.dart' show LiveScoreHold;
import '../widgets/rank.dart';
import 'cheer_widgets.dart' show cheerPointsText;

const _pink = Color(0xFFFF4F8B);

class CheerCelebration extends StatefulWidget {
  const CheerCelebration({super.key, required this.credit, required this.onDone, this.autoClose = true, this.time});

  final CheerCredit credit;
  final VoidCallback onDone;
  final bool autoClose;

  /// Pins the animation at this many seconds (for pictures and tests).
  final double? time;

  @override
  State<CheerCelebration> createState() => _CheerCelebrationState();
}

class _CheerCelebrationState extends State<CheerCelebration> with TickerProviderStateMixin {
  static const _introSeconds = 3.2;

  /// When the score starts counting up, and for how long.
  static const _countStart = 1.1, _countLength = 1.6;

  late final _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 3200));
  late final _spin = AnimationController(vsync: this, duration: const Duration(seconds: 16));
  late final _out = AnimationController(vsync: this, duration: const Duration(milliseconds: 320));
  final _focus = FocusNode();
  Timer? _auto;
  ResultSfx? _sfx;
  bool _closing = false;
  bool _dinged = false;

  @override
  void initState() {
    super.initState();
    if (widget.time != null) {
      _intro.value = (widget.time! / _introSeconds).clamp(0.0, 1.0);
      _spin.value = (widget.time! / 16) % 1;
    } else {
      _intro.forward();
      _spin.repeat();
      _intro.addListener(_maybeDing);
    }
    if (widget.autoClose) _auto = Timer(const Duration(milliseconds: 7000), _close);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
    _playSound();
  }

  Future<void> _playSound() async {
    AppSettings settings;
    try {
      settings = context.read<AppSettings>();
    } catch (_) {
      return;
    }
    if (!settings.resultSounds || widget.time != null) return;
    final sfx = _sfx = ResultSfx.of(settings, only: const ['item', 'ding']);
    await sfx.preload();
    if (mounted) unawaited(sfx.play('item'));
  }

  /// A ding as the count reaches the new score.
  void _maybeDing() {
    if (_dinged || widget.credit.after == null) return;
    if (_intro.value * _introSeconds >= _countStart + _countLength) {
      _dinged = true;
      unawaited(_sfx?.play('ding'));
    }
  }

  @override
  void dispose() {
    _auto?.cancel();
    _intro.dispose();
    _spin.dispose();
    _out.dispose();
    _focus.dispose();
    _sfx?.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    _auto?.cancel();
    if (mounted) await _out.forward();
    widget.onDone();
  }

  static double _appear(double t, double start, double length, [Curve curve = Curves.easeOutCubic]) => curve.transform(((t - start) / length).clamp(0.0, 1.0));

  Widget _rise(double t, double start, Widget child, {double dy = 22}) {
    final a = _appear(t, start, 0.4);
    return Opacity(opacity: a, child: Transform.translate(offset: Offset(0, dy * (1 - a)), child: child));
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: (node, e) {
        if (e is KeyDownEvent && (e.logicalKey == LogicalKeyboardKey.escape || e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.space)) {
          _close();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _close,
        child: Material(
          type: MaterialType.transparency,
          child: AnimatedBuilder(
            animation: Listenable.merge([_intro, _spin, _out]),
            builder: (context, _) {
              final t = _intro.value * _introSeconds;
              final out = Curves.easeIn.transform(_out.value);
              final fade = Curves.easeOut.transform((t / 0.25).clamp(0.0, 1.0)) * (1 - out);
              return Stack(fit: StackFit.expand, children: [
                ColoredBox(color: Colors.black.withValues(alpha: 0.82 * fade)),
                Opacity(
                  opacity: (1 - out).clamp(0.0, 1.0),
                  child: Transform.scale(scale: 1 + 0.06 * out, child: Center(child: SingleChildScrollView(child: _content(context, t)))),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 28,
                  child: Opacity(
                    opacity: _appear(t, 2.6, 0.5) * 0.7 * (1 - out),
                    child: Text(tr('ach.tapToClose'), textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white70, letterSpacing: 1)),
                  ),
                ),
              ]);
            },
          ),
        ),
      ),
    );
  }

  Widget _content(BuildContext context, double t) {
    final theme = Theme.of(context);
    final c = widget.credit;
    final d = c.donation;
    final kickerStyle = theme.textTheme.titleMedium?.copyWith(color: _pink, fontWeight: FontWeight.w900, letterSpacing: 6 + 6 * (1 - _appear(t, 0.4, 0.6)));
    final before = c.before, after = c.after;
    // The score counting up, and the rank of where the count is.
    final k = _appear(t, _countStart, _countLength);
    final shown = before == null || after == null ? null : before + (after - before) * k;
    final shownRank = shown == null ? null : (k >= 1 ? c.afterRank : (shown == before ? c.beforeRank : rankForTotal(shown)));
    final landed = k >= 1;
    final landPop = 1 + 0.12 * (1 - _appear(t, _countStart + _countLength, 0.5, Curves.easeOutBack));
    final rc = rankColor(shownRank);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 260,
          height: 260,
          child: Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
            Positioned.fill(child: CustomPaint(painter: CelebrationBurstPainter(t: t, spin: _spin.value, color: _pink))),
            Transform.scale(
              scale: _appear(t, 0.1, 0.6, Curves.elasticOut),
              child: Container(
                width: 150,
                height: 150,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFFFB3CF), _pink, Color(0xFFB0145A)]),
                ),
                child: const Icon(Icons.volunteer_activism, size: 82, color: Colors.white),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 10),
        _rise(t, 0.35, Text(tr('cheer.kicker'), textAlign: TextAlign.center, style: kickerStyle)),
        const SizedBox(height: 10),
        _rise(
          t,
          0.5,
          Text(tr('cheer.from', {'name': d.name.isEmpty ? '—' : d.name, 'amount': d.amount}),
              textAlign: TextAlign.center, style: theme.textTheme.displaySmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w900)),
          dy: 30,
        ),
        if (d.message.isNotEmpty) ...[
          const SizedBox(height: 10),
          _rise(
            t,
            0.65,
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Text('「${d.message}」', textAlign: TextAlign.center, maxLines: 3, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleLarge?.copyWith(color: const Color(0xFFFFD6E5))),
            ),
          ),
        ],
        const SizedBox(height: 24),
        if (c.songTitle == null)
          _rise(t, 0.85, Text(tr('cheer.noSong'), textAlign: TextAlign.center, style: theme.textTheme.titleMedium?.copyWith(color: Colors.white70)))
        else ...[
          _rise(
            t,
            0.8,
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: Text(c.songTitle!, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium?.copyWith(color: const Color(0xFFC9C4D8))),
            ),
          ),
          const SizedBox(height: 8),
          if (shown != null)
            _rise(
              t,
              0.9,
              Transform.scale(
                scale: landed ? landPop : 1,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(
                    shown.toStringAsFixed(1),
                    style: theme.textTheme.displayLarge?.copyWith(
                      color: rc,
                      fontWeight: FontWeight.w900,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      shadows: [Shadow(color: rc.withValues(alpha: 0.6), blurRadius: 24)],
                    ),
                  ),
                  const SizedBox(width: 14),
                  RankChip(rank: shownRank, fontSize: 22),
                ]),
              ),
              dy: 30,
            ),
          const SizedBox(height: 16),
          _rise(
            t,
            1.0,
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              decoration: BoxDecoration(color: _pink, borderRadius: BorderRadius.circular(999)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.trending_up, size: 20, color: Colors.white),
                const SizedBox(width: 8),
                Text(
                  c.points <= 0
                      ? tr('cheer.belowRate', {'n': context.read<AppSettings>().cheerTwdPerPoint})
                      : after != null && before != null && after <= before
                          ? tr('cheer.atMax')
                          : tr('cheer.plus', {'points': cheerPointsText(c.points)}),
                  style: theme.textTheme.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w900),
                ),
              ]),
            ),
          ),
        ],
        // The item points (點數) it gave, whether or not a song got points.
        if (c.itemPoints > 0) ...[
          const SizedBox(height: 10),
          _rise(
            t,
            1.15,
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              decoration: BoxDecoration(color: const Color(0xFFE5A823), borderRadius: BorderRadius.circular(999)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.stars, size: 20, color: Colors.white),
                const SizedBox(width: 8),
                Text(tr('cheer.itemPoints', {'n': c.itemPoints}), style: theme.textTheme.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w900)),
              ]),
            ),
          ),
        ],
      ]),
    );
  }
}

/// 開發模式: shows the celebration for a made-up donation (nothing credited).
void previewCheerCelebration(BuildContext context) {
  final overlay = Overlay.of(context, rootOverlay: true);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => CheerCelebration(
      credit: CheerCredit(
        donation: Donation(source: 'ecpay', name: tr('cheer.previewName'), amount: 450, message: tr('cheer.previewMsg'), receivedAt: DateTime.now()),
        points: 3,
        itemPoints: 45,
        songTitle: 'Karaoke Battle',
        before: 95.6,
        beforeRank: 'SS',
        after: 98.6,
        afterRank: 'SSS',
      ),
      onDone: () => entry.remove(),
    ),
  );
  overlay.insert(entry);
}

/// Shows [CheerCelebration] over any page for each donation, one after
/// another, waiting while a song or a score reveal holds the screen.
class CheerPopups extends StatefulWidget {
  const CheerPopups({super.key, required this.child});
  final Widget child;

  @override
  State<CheerPopups> createState() => _CheerPopupsState();
}

class _CheerPopupsState extends State<CheerPopups> {
  StreamSubscription<CheerCredit>? _sub;
  final _pending = <CheerCredit>[];
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    _sub = context.read<CheerService>().credits.listen(_onCredit);
    AchievementHold.notifier.addListener(_onHold);
  }

  @override
  void dispose() {
    _sub?.cancel();
    AchievementHold.notifier.removeListener(_onHold);
    LiveScoreHold.notifier.value = false;
    super.dispose();
  }

  void _onCredit(CheerCredit c) {
    _pending.add(c);
    _holdScores();
    Future<void>.delayed(const Duration(milliseconds: 250), _pump);
  }

  /// Scores on the pages count up once the celebrations are over.
  void _holdScores() => LiveScoreHold.notifier.value = _showing || _pending.isNotEmpty;

  void _onHold() {
    if (!AchievementHold.active) Future<void>.delayed(const Duration(milliseconds: 500), _pump);
  }

  void _pump() {
    if (!mounted || _showing || AchievementHold.active || _pending.isEmpty) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final credit = _pending.removeAt(0);
    _showing = true;
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => CheerCelebration(
        credit: credit,
        onDone: () {
          entry.remove();
          _showing = false;
          _holdScores();
          Future<void>.delayed(const Duration(milliseconds: 250), _pump);
        },
      ),
    );
    overlay.insert(entry);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
