// The moment items are gained (redeemed, or the daily top-up): the screen
// dims, the item's medal pops in with a burst in its colour, and its name,
// how many and what it cost come in. A click, Esc, Enter or Space closes
// it, and it closes by itself after a few seconds. It waits, as the
// achievement celebration does, while a song or a score reveal is on.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../services/items.dart';
import '../../services/settings.dart';
import '../../state/i18n.dart';
import '../results/score_reveal.dart' show ResultSfx;
import '../widgets/achievement_events.dart' show AchievementHold;
import '../widgets/shine.dart';
import 'achievement_celebration.dart' show CelebrationBurstPainter;
import 'items_view.dart' show ItemMedal, itemColor, resetLabel;

class ItemCelebration extends StatefulWidget {
  const ItemCelebration({super.key, required this.gain, required this.onDone, this.balance, this.nextReset, this.autoClose = true, this.time});

  final ItemGain gain;
  final VoidCallback onDone;

  /// The points left after a redeem; when the next top-up comes.
  final int? balance;
  final DateTime? nextReset;
  final bool autoClose;

  /// Pins the animation at this many seconds (for pictures and tests).
  final double? time;

  @override
  State<ItemCelebration> createState() => _ItemCelebrationState();
}

class _ItemCelebrationState extends State<ItemCelebration> with TickerProviderStateMixin {
  static const _introSeconds = 2.4;
  late final _intro = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));
  late final _spin = AnimationController(vsync: this, duration: const Duration(seconds: 16));
  late final _out = AnimationController(vsync: this, duration: const Duration(milliseconds: 320));
  final _focus = FocusNode();
  Timer? _auto;
  ResultSfx? _sfx;
  bool _closing = false;

  List<MapEntry<ItemKind, int>> get _items => widget.gain.items.entries.toList();

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
    if (widget.autoClose) _auto = Timer(const Duration(milliseconds: 4200), _close);
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
    final name = widget.gain.daily ? 'daily' : 'item';
    final sfx = _sfx = ResultSfx.of(settings, only: [name]);
    await sfx.preload();
    if (mounted) unawaited(sfx.play(name));
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
                ColoredBox(color: Colors.black.withValues(alpha: 0.8 * fade)),
                Opacity(
                  opacity: (1 - out).clamp(0.0, 1.0),
                  child: Transform.scale(scale: 1 + 0.06 * out, child: Center(child: SingleChildScrollView(child: _content(context, t)))),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 28,
                  child: Opacity(
                    opacity: _appear(t, 1.3, 0.5) * 0.7 * (1 - out),
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
    final items = _items;
    final accent = itemColor(items.first.key);
    final kicker = widget.gain.daily ? tr('items.gotDaily') : tr('items.got');
    final kickerStyle = theme.textTheme.titleMedium?.copyWith(color: accent, fontWeight: FontWeight.w900, letterSpacing: 6 + 6 * (1 - _appear(t, 0.4, 0.6)));
    final pill = widget.gain.daily
        ? (widget.nextReset == null ? null : tr('items.nextReset', {'at': resetLabel(widget.nextReset!)}))
        : tr('items.gotCost', {'cost': widget.gain.cost, 'left': widget.balance ?? 0});

    Widget medal(ItemKind k, int n, double start, double size) {
      final pop = _appear(t, start, 0.6, Curves.elasticOut);
      final turn = -0.8 * (1 - _appear(t, start, 0.45));
      final sweep = ((t - start - 0.8) / 0.6).clamp(0.0, 1.0);
      return Transform.rotate(
        angle: turn,
        child: Transform.scale(
          scale: pop,
          child: Stack(alignment: Alignment.center, children: [
            Container(width: size * 1.1, height: size * 1.1, decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.12))),
            ShineScope(enabled: widget.time == null, child: ItemMedal(kind: k, size: size)),
            if (sweep > 0 && sweep < 1) SizedBox(width: size * 0.78, height: size * 0.78, child: ClipOval(child: ShineBand(position: -0.4 + 1.8 * sweep, strength: 0.6))),
          ]),
        ),
      );
    }

    final count = TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 22, shadows: [Shadow(color: accent, blurRadius: 12)]);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (items.length == 1) ...[
          SizedBox(
            width: 280,
            height: 280,
            child: Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
              Positioned.fill(child: CustomPaint(painter: CelebrationBurstPainter(t: t, spin: _spin.value, color: accent))),
              medal(items.first.key, items.first.value, 0.1, 170),
            ]),
          ),
          const SizedBox(height: 14),
          _rise(t, 0.4, Text(kicker, textAlign: TextAlign.center, style: kickerStyle)),
          const SizedBox(height: 10),
          _rise(
            t,
            0.55,
            Text('${tr('items.${items.first.key.name}.name')}  × ${items.first.value}',
                textAlign: TextAlign.center, style: theme.textTheme.displaySmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w900)),
            dy: 30,
          ),
          const SizedBox(height: 10),
          _rise(t, 0.72, ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Text(tr('items.${items.first.key.name}.desc'), textAlign: TextAlign.center, style: theme.textTheme.titleMedium?.copyWith(color: const Color(0xFFC9C4D8))),
          )),
        ] else ...[
          _rise(t, 0.15, Text(kicker, textAlign: TextAlign.center, style: kickerStyle)),
          const SizedBox(height: 26),
          Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
            Positioned.fill(child: CustomPaint(painter: CelebrationBurstPainter(t: t, spin: _spin.value, color: accent, rays: 0.6, halo: false))),
            Wrap(alignment: WrapAlignment.center, spacing: 28, runSpacing: 22, children: [
              for (final (i, e) in items.indexed)
                SizedBox(
                  width: 150,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    medal(e.key, e.value, 0.3 + 0.18 * i, 104),
                    const SizedBox(height: 10),
                    Opacity(
                      opacity: _appear(t, 0.45 + 0.18 * i, 0.4),
                      child: Column(children: [
                        Text(tr('items.${e.key.name}.name'), textAlign: TextAlign.center, style: theme.textTheme.titleSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w900)),
                        Text('+ ${e.value}', style: count.copyWith(color: itemColor(e.key))),
                      ]),
                    ),
                  ]),
                ),
            ]),
          ]),
        ],
        if (pill != null) ...[
          const SizedBox(height: 24),
          _rise(
            t,
            0.9,
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
              decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(999)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(widget.gain.daily ? Icons.schedule : Icons.stars, size: 20, color: Colors.white),
                const SizedBox(width: 8),
                Text(pill, style: theme.textTheme.titleMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w900)),
              ]),
            ),
          ),
        ],
      ]),
    );
  }
}

/// Shows [ItemCelebration] over any page when items are gained, one after
/// another, waiting while a song or a score reveal holds the screen.
class ItemGainPopups extends StatefulWidget {
  const ItemGainPopups({super.key, required this.child});
  final Widget child;

  @override
  State<ItemGainPopups> createState() => _ItemGainPopupsState();
}

class _ItemGainPopupsState extends State<ItemGainPopups> {
  late final ItemService _items = context.read<ItemService>();
  StreamSubscription<ItemGain>? _sub;
  final _pending = <ItemGain>[];
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    _sub = _items.gains.listen(_onGain);
    AchievementHold.notifier.addListener(_onHold);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _items.takeMissed().forEach(_onGain);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    AchievementHold.notifier.removeListener(_onHold);
    super.dispose();
  }

  void _onGain(ItemGain g) {
    _pending.add(g);
    // A moment later, so a dialog that just closed is gone.
    Future<void>.delayed(const Duration(milliseconds: 250), _pump);
  }

  void _onHold() {
    if (!AchievementHold.active) Future<void>.delayed(const Duration(milliseconds: 500), _pump);
  }

  void _pump() {
    if (!mounted || _showing || AchievementHold.active || _pending.isEmpty) return;
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final gain = _pending.removeAt(0);
    _showing = true;
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => ItemCelebration(
        gain: gain,
        balance: _items.balance,
        nextReset: _items.nextReset,
        onDone: () {
          entry.remove();
          _showing = false;
          Future<void>.delayed(const Duration(milliseconds: 250), _pump);
        },
      ),
    );
    overlay.insert(entry);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
