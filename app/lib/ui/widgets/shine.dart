// Light effects shared by the rank tags, the results card and the rules
// page's demo cards: a band of light sweeping across, a pulsing glow and
// sparkles. Everything runs on one clock, so the tags on screen shine
// together, and only while on screen (tickers are muted in hidden tabs).
// Captured images and videos turn it off with ShineScope.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

final _clock = Stopwatch()..start();

/// Seconds on the shared clock: the frame's time stamp, the same for every
/// widget in a frame (and the test clock in tests).
double get shineTime {
  final binding = SchedulerBinding.instance;
  if (binding.schedulerPhase == SchedulerPhase.idle) return _clock.elapsedMicroseconds / 1e6;
  return binding.currentFrameTimeStamp.inMicroseconds / 1e6;
}

/// Where the band of light is ([ShineBand.position], -1..2) at [t] seconds,
/// sweeping once every [period] seconds for [window] of it (0..1), [delay]
/// seconds after the shared start; null while it is not sweeping.
double? shineAt(double t, {double period = 3.6, double window = 0.3, double delay = 0}) {
  final u = ((t - delay) % period) / period;
  if (u > window) return null;
  return -1 + 3 * Curves.easeInOut.transform(u / window);
}

/// 0..1, slowly up and down once every [period] seconds.
double shinePulse(double t, {double period = 2.4, double phase = 0}) => 0.5 + 0.5 * math.sin((t / period + phase) * 2 * math.pi);

/// Turns the effects below it off (images and videos being captured).
class ShineScope extends InheritedWidget {
  const ShineScope({super.key, required this.enabled, required super.child});
  final bool enabled;

  static bool enabledFor(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ShineScope>()?.enabled ?? true;

  @override
  bool updateShouldNotify(ShineScope old) => old.enabled != enabled;
}

/// Rebuilds [builder] every frame with the shared time while it is on screen;
/// with the effects off ([ShineScope]), once with null.
class ShineTicker extends StatefulWidget {
  const ShineTicker({super.key, required this.builder});
  final Widget Function(BuildContext context, double? t) builder;

  @override
  State<ShineTicker> createState() => _ShineTickerState();
}

class _ShineTickerState extends State<ShineTicker> with SingleTickerProviderStateMixin {
  late final _ticker = createTicker((_) => setState(() {}));

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final on = ShineScope.enabledFor(context);
    if (on && !_ticker.isActive) _ticker.start();
    if (!on && _ticker.isActive) _ticker.stop();
    return widget.builder(context, on ? shineTime : null);
  }
}

/// A slanted band of white light at [position] (-1: just left of the box,
/// 2: just right of it). Put it in a Stack over what it shines on, clipped.
class ShineBand extends StatelessWidget {
  const ShineBand({super.key, required this.position, this.strength = 0.75, this.color = Colors.white});
  final double position;
  final double strength;

  /// The light's colour (white; tinted for the ranks below SSS).
  final Color color;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: FractionalTranslation(
          translation: Offset(position - 0.5, 0),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [color.withValues(alpha: 0), color.withValues(alpha: strength), color.withValues(alpha: 0)],
                stops: const [0.3, 0.5, 0.7],
              ),
            ),
          ),
        ),
      );
}

/// A four-pointed star twinkling with [value] (0: gone, 1: full).
class Sparkle extends StatelessWidget {
  const Sparkle({super.key, required this.size, required this.value, this.color = const Color(0xFFFFF3A6), this.glow = const Color(0xFFF9D84A)});
  final double size;
  final double value;
  final Color color;
  final Color glow;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: Opacity(
          opacity: value.clamp(0.0, 1.0),
          child: Transform.scale(
            scale: 0.5 + 0.5 * value,
            child: Transform.rotate(
              angle: value * 0.8,
              child: Icon(Icons.auto_awesome, size: size, color: color, shadows: [Shadow(color: glow, blurRadius: 8)]),
            ),
          ),
        ),
      );
}

/// A gentle sweep of light across a filled bar, for the sub-score bars; the
/// [index]th bar a little after the one above it.
class BarShine extends StatelessWidget {
  const BarShine({super.key, required this.fraction, this.index = 0, this.strength = 0.55});

  /// How much of the bar is filled (0..1): the light stays on the fill.
  final double fraction;
  final int index;
  final double strength;

  @override
  Widget build(BuildContext context) => ShineTicker(
        builder: (context, t) {
          final pos = t == null ? null : shineAt(t, period: 4.2, window: 0.28, delay: 0.12 * index);
          if (pos == null || fraction <= 0) return const SizedBox.shrink();
          return FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: fraction.clamp(0.0, 1.0),
            child: ClipRect(child: ShineBand(position: pos, strength: strength)),
          );
        },
      );
}
