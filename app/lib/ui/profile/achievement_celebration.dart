// The full-screen moment when achievements unlock: the screen dims, rays and
// a shock ring burst from the medal, confetti flies, and the name, what it
// asked for and the points come in. One unlock gets the big medal; several
// unlocked together share one screen. A click, Esc, Enter or Space closes it,
// and it closes by itself after a few seconds.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/achievements.dart';
import '../../services/settings.dart';
import '../../state/i18n.dart';
import '../results/score_reveal.dart' show ResultSfx;
import '../widgets/shine.dart';
import 'achievements_view.dart' show AchievementMedal, TierBadge, medalColor;

const _gold = Color(0xFFE5A823);

/// The confetti's flat colours (the medal's own colour is added).
const _confetti = [Color(0xFFF9D84A), Color(0xFFFF4FA3), Color(0xFF64D2FF), Color(0xFF30D158), Color(0xFFBF5AF2), Color(0xFFFF9F0A)];

/// How many medals one screen shows; the rest are counted.
const kCelebrationMax = 5;

class AchievementCelebration extends StatefulWidget {
  const AchievementCelebration({super.key, this.unlocks = const [], this.summaryCount = 0, this.summaryPoints = 0, required this.onDone, this.autoClose = true, this.time});

  final List<AchievementUnlock> unlocks;

  /// The first start's summary (no [unlocks]): how many, and the points.
  final int summaryCount, summaryPoints;

  final VoidCallback onDone;
  final bool autoClose;

  /// Pins the animation at this many seconds (for pictures and tests).
  final double? time;

  @override
  State<AchievementCelebration> createState() => _AchievementCelebrationState();
}

class _AchievementCelebrationState extends State<AchievementCelebration> with TickerProviderStateMixin {
  static const _introSeconds = 3.0;
  late final _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 3000));
  late final _spin = AnimationController(vsync: this, duration: const Duration(seconds: 16));
  late final _out = AnimationController(vsync: this, duration: const Duration(milliseconds: 380));
  final _focus = FocusNode();
  Timer? _auto;
  ResultSfx? _sfx;
  bool _closing = false;

  bool get _many => widget.unlocks.length > 1;

  @override
  void initState() {
    super.initState();
    if (widget.time != null) {
      _intro.value = (widget.time! / _introSeconds).clamp(0.0, 1.0);
      _spin.value = (widget.time! / 16) % 1;
    } else {
      _intro.forward();
      _spin.repeat();
    }
    if (widget.autoClose) _auto = Timer(Duration(milliseconds: _many ? 6500 : 5000), _close);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
    _playSound();
  }

  Future<void> _playSound() async {
    bool on;
    try {
      on = context.read<AppSettings>().resultSounds;
    } catch (_) {
      return;
    }
    if (!on || widget.time != null) return;
    final sfx = _sfx = ResultSfx(enabled: true);
    await sfx.preload();
    if (mounted) unawaited(sfx.play('ding'));
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

  Color get _accent => widget.unlocks.isEmpty ? _gold : medalColor(widget.unlocks.first.def, widget.unlocks.first.tier);

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
              final fade = Curves.easeOut.transform((t / 0.3).clamp(0.0, 1.0)) * (1 - out);
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
                    opacity: _appear(t, 1.6, 0.5) * 0.7 * (1 - out),
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

  /// 0 → 1 from [start] over [length] seconds, eased.
  static double _appear(double t, double start, double length, [Curve curve = Curves.easeOutCubic]) => curve.transform(((t - start) / length).clamp(0.0, 1.0));

  /// Fades and rises into place from [start].
  Widget _rise(double t, double start, Widget child, {double dy = 24}) {
    final a = _appear(t, start, 0.45);
    return Opacity(opacity: a, child: Transform.translate(offset: Offset(0, dy * (1 - a)), child: child));
  }

  Widget _content(BuildContext context, double t) {
    final theme = Theme.of(context);
    final accent = _accent;
    final kicker = _many ? tr('ach.unlockedMany', {'n': widget.unlocks.length}) : tr('ach.unlocked');
    final kickerStyle = theme.textTheme.titleMedium?.copyWith(color: accent, fontWeight: FontWeight.w900, letterSpacing: 6 + 6 * (1 - _appear(t, 0.45, 0.6)));
    final points = widget.unlocks.isEmpty ? widget.summaryPoints : widget.unlocks.fold<int>(0, (a, u) => a + u.points);

    if (_many) {
      final shown = widget.unlocks.take(kCelebrationMax).toList();
      final rest = widget.unlocks.length - shown.length;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _rise(t, 0.2, Text(kicker, textAlign: TextAlign.center, style: kickerStyle)),
          const SizedBox(height: 28),
          Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
            Positioned.fill(child: CustomPaint(painter: _BurstPainter(t: t, spin: _spin.value, color: accent, rays: 0.6, halo: false))),
            Wrap(alignment: WrapAlignment.center, spacing: 18, runSpacing: 22, children: [
              for (final (i, u) in shown.indexed) _smallMedal(theme, t, 0.35 + 0.16 * i, u),
            ]),
          ]),
          const SizedBox(height: 28),
          if (rest > 0) _rise(t, 0.5 + 0.16 * shown.length, Text(tr('ach.more', {'n': rest}), style: theme.textTheme.bodyLarge?.copyWith(color: Colors.white70))),
          if (rest > 0) const SizedBox(height: 12),
          _rise(t, 0.6 + 0.16 * shown.length, _pointsPill(theme, accent, tr('ach.pointsGained', {'n': points}))),
        ]),
      );
    }

    final u = widget.unlocks.isEmpty ? null : widget.unlocks.first;
    final title = u == null ? tr('ach.firstRun', {'n': widget.summaryCount}) : tr('ach.${u.def.id}.name');
    final desc = u == null ? null : tr('ach.${u.def.id}.desc', {'n': _number(u.def, u.def.thresholds[u.tier - 1])});
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 280,
          height: 280,
          child: Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
            Positioned.fill(child: CustomPaint(painter: _BurstPainter(t: t, spin: _spin.value, color: accent))),
            _bigMedal(t, u, 150),
          ]),
        ),
        const SizedBox(height: 18),
        _rise(t, 0.45, Text(kicker, textAlign: TextAlign.center, style: kickerStyle)),
        const SizedBox(height: 10),
        _rise(
          t,
          0.6,
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Text(title, textAlign: TextAlign.center, style: theme.textTheme.displaySmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w900, height: 1.15)),
          ),
          dy: 32,
        ),
        if (desc != null) ...[
          const SizedBox(height: 10),
          _rise(t, 0.78, Text(desc, textAlign: TextAlign.center, style: theme.textTheme.titleMedium?.copyWith(color: const Color(0xFFC9C4D8)))),
        ],
        const SizedBox(height: 22),
        _rise(
          t,
          0.95,
          u == null
              ? _pointsPill(theme, accent, tr('ach.points', {'n': points}))
              // The tier's badge beside the points.
              : Row(mainAxisSize: MainAxisSize.min, children: [
                  TierBadge(def: u.def, tier: u.tier, size: 30),
                  const SizedBox(width: 12),
                  _pointsPill(theme, accent, tr('ach.pointsGained', {'n': points})),
                ]),
        ),
      ]),
    );
  }

  static String _number(AchievementDef a, num v) => a.id == 'hours' ? (v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1)) : '${v.floor()}';

  /// The medal: pops in with a spin, lands with a bounce, then a light
  /// sweeps across it.
  Widget _bigMedal(double t, AchievementUnlock? u, double size) {
    final pop = _appear(t, 0.12, 0.6, Curves.elasticOut);
    final turn = -0.9 * (1 - _appear(t, 0.12, 0.5));
    final sweep = ((t - 1.0) / 0.7).clamp(0.0, 1.0);
    final medal = u == null
        ? Container(
            width: size,
            height: size,
            decoration: const BoxDecoration(shape: BoxShape.circle, color: _gold),
            child: Icon(Icons.emoji_events, size: size * 0.5, color: Colors.white),
          )
        : AchievementMedal(def: u.def, tier: u.tier, size: size);
    return Transform.rotate(
      angle: turn,
      child: Transform.scale(
        scale: pop,
        child: Stack(alignment: Alignment.center, children: [
          // A flat rim around the disc.
          Container(width: size + 16, height: size + 16, decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.14))),
          medal,
          if (sweep > 0 && sweep < 1)
            SizedBox(width: size, height: size, child: ClipOval(child: ShineBand(position: -0.4 + 1.8 * sweep, strength: 0.6))),
        ]),
      ),
    );
  }

  Widget _smallMedal(ThemeData theme, double t, double start, AchievementUnlock u) {
    final pop = _appear(t, start, 0.55, Curves.elasticOut);
    final label = _appear(t, start + 0.15, 0.4);
    return SizedBox(
      width: 150,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Transform.scale(
          scale: pop,
          child: Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.14)),
            child: AchievementMedal(def: u.def, tier: u.tier, size: 92),
          ),
        ),
        const SizedBox(height: 10),
        Opacity(
          opacity: label,
          child: Column(children: [
            Text(tr('ach.${u.def.id}.name'), textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w900)),
            const SizedBox(height: 2),
            Row(mainAxisSize: MainAxisSize.min, children: [
              TierBadge(def: u.def, tier: u.tier, size: 14),
              const SizedBox(width: 6),
              Text('+${u.points}', style: theme.textTheme.bodySmall?.copyWith(color: medalColor(u.def, u.tier), fontWeight: FontWeight.w800)),
            ]),
          ]),
        ),
      ]),
    );
  }

  Widget _pointsPill(ThemeData theme, Color color, String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(999)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.stars, size: 20, color: Colors.white),
          const SizedBox(width: 8),
          Text(text, style: theme.textTheme.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w900)),
        ]),
      );
}

/// Behind the medal: turning rays, two shock rings, a burst of confetti and
/// twinkling sparks, all flat.
class _BurstPainter extends CustomPainter {
  _BurstPainter({required this.t, required this.spin, required this.color, this.rays = 1, this.halo = true});
  final double t;
  final double spin;
  final Color color;

  /// The rays' strength (fainter behind a row of medals).
  final double rays;

  /// The disc and sparks around one medal (not behind a row of them).
  final bool halo;

  static final _pieces = _makePieces();

  static List<_Piece> _makePieces() {
    final r = math.Random(7);
    return [
      for (var i = 0; i < 90; i++)
        _Piece(
          angle: r.nextDouble() * math.pi * 2,
          speed: 380 + r.nextDouble() * 620,
          size: 6 + r.nextDouble() * 8,
          colorIndex: r.nextInt(_confetti.length + 2),
          round: r.nextBool() && r.nextBool(),
          turn: (r.nextDouble() - 0.5) * 14,
          delay: r.nextDouble() * 0.12,
        ),
    ];
  }

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    double appear(double start, double len) => Curves.easeOutCubic.transform(((t - start) / len).clamp(0.0, 1.0));

    // Rays: twelve flat wedges turning slowly.
    final ray = appear(0.15, 0.5);
    if (ray > 0 && rays > 0) {
      final paint = Paint()..color = color.withValues(alpha: 0.16 * ray * rays);
      final reach = 640.0 * ray;
      const n = 12;
      for (var i = 0; i < n; i++) {
        final a = spin * math.pi * 2 + i * math.pi * 2 / n;
        const half = math.pi / n * 0.45;
        canvas.drawPath(
          Path()
            ..moveTo(c.dx, c.dy)
            ..lineTo(c.dx + reach * math.cos(a - half), c.dy + reach * math.sin(a - half))
            ..lineTo(c.dx + reach * math.cos(a + half), c.dy + reach * math.sin(a + half))
            ..close(),
          paint,
        );
      }
      if (halo) canvas.drawCircle(c, 120 * ray, Paint()..color = color.withValues(alpha: 0.22 * ray * rays.clamp(0.6, 1.0)));
    }

    // Two shock rings.
    for (final start in const [0.22, 0.42]) {
      final p = ((t - start) / 0.8).clamp(0.0, 1.0);
      if (p <= 0 || p >= 1) continue;
      final e = Curves.easeOutCubic.transform(p);
      canvas.drawCircle(
        c,
        70 + 340 * e,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 12 * (1 - p)
          ..color = (start == 0.22 ? color : Colors.white).withValues(alpha: 0.9 * (1 - p)),
      );
    }

    // Confetti: thrown out, slowed by the air, falling, then gone.
    const k = 2.2, g = 520.0;
    for (final piece in _pieces) {
      final tau = t - 0.25 - piece.delay;
      if (tau <= 0) continue;
      final alpha = 1 - ((tau - 1.7) / 0.6).clamp(0.0, 1.0);
      if (alpha <= 0) continue;
      final travel = piece.speed * (1 - math.exp(-k * tau)) / k;
      final pos = c + Offset(math.cos(piece.angle) * travel, math.sin(piece.angle) * travel + 0.5 * g * tau * tau * 0.55);
      final col = piece.colorIndex >= _confetti.length ? color : _confetti[piece.colorIndex];
      final paint = Paint()..color = col.withValues(alpha: alpha);
      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      canvas.rotate(piece.turn * tau);
      if (piece.round) {
        canvas.drawCircle(Offset.zero, piece.size * 0.45, paint);
      } else {
        // Flutters: the strip narrows as it turns over.
        final w = piece.size * (0.35 + 0.65 * math.cos(piece.turn * tau * 0.7).abs());
        canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: w, height: piece.size * 0.55), paint);
      }
      canvas.restore();
    }

    // Sparks twinkling around the medal.
    final spark = appear(0.6, 0.5);
    if (halo && spark > 0) {
      for (var i = 0; i < 10; i++) {
        final a = i * math.pi * 2 / 10 + 0.3;
        final r = 118.0 + 34 * ((i * 37) % 5) / 4;
        final tw = 0.5 + 0.5 * math.sin(spin * math.pi * 2 * 10 + i * 1.7);
        _star(canvas, c + Offset(math.cos(a) * r, math.sin(a) * r), (5 + 5 * tw) * spark, Colors.white.withValues(alpha: (0.35 + 0.65 * tw) * spark));
      }
    }
  }

  static void _star(Canvas canvas, Offset p, double r, Color color) {
    final w = r * 0.28;
    canvas.drawPath(
      Path()
        ..moveTo(p.dx, p.dy - r)
        ..quadraticBezierTo(p.dx + w, p.dy - w, p.dx + r, p.dy)
        ..quadraticBezierTo(p.dx + w, p.dy + w, p.dx, p.dy + r)
        ..quadraticBezierTo(p.dx - w, p.dy + w, p.dx - r, p.dy)
        ..quadraticBezierTo(p.dx - w, p.dy - w, p.dx, p.dy - r)
        ..close(),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_BurstPainter old) => old.t != t || old.spin != spin || old.color != color || old.rays != rays || old.halo != halo;
}

class _Piece {
  const _Piece({required this.angle, required this.speed, required this.size, required this.colorIndex, required this.round, required this.turn, required this.delay});
  final double angle, speed, size, turn, delay;
  final int colorIndex;
  final bool round;
}
