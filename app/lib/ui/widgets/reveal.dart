// Entrance animations for page sections: played once a section comes into
// view in its scrollable, and again each time its tab is shown again (the
// shell keeps tabs mounted; hidden tabs have their tickers muted).
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import 'live_score.dart';

/// The website's entrance easing (cubic-bezier(0.16, 1, 0.3, 1)).
const revealEase = Cubic(0.16, 1, 0.3, 1);

/// Builds [builder] with its entrance progress t (0..1, eased), which runs
/// over [duration] after [delay] once the widget is on screen.
class Entrance extends StatefulWidget {
  const Entrance({
    super.key,
    required this.builder,
    this.duration = const Duration(milliseconds: 900),
    this.delay = Duration.zero,
    this.curve = revealEase,
    this.child,
  });

  final Widget Function(BuildContext context, double t, Widget? child) builder;
  final Duration duration;
  final Duration delay;
  final Curve curve;
  final Widget? child;

  @override
  State<Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<Entrance> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: widget.delay + widget.duration);
  ScrollPosition? _position;
  ValueListenable<TickerModeData>? _tab;
  bool _played = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final pos = Scrollable.maybeOf(context)?.position;
    if (pos != _position) {
      _position?.removeListener(_checkSoon);
      _position = pos?..addListener(_checkSoon);
    }
    final tab = TickerMode.getValuesNotifier(context);
    if (tab != _tab) {
      _tab?.removeListener(_checkSoon);
      _tab = tab..addListener(_checkSoon);
    }
    _checkSoon();
  }

  @override
  void dispose() {
    _position?.removeListener(_checkSoon);
    _tab?.removeListener(_checkSoon);
    _c.dispose();
    super.dispose();
  }

  /// After the next layout, when the scrolled positions are up to date.
  void _checkSoon() {
    WidgetsBinding.instance
      ..addPostFrameCallback((_) => _check())
      ..ensureVisualUpdate();
  }

  void _check() {
    if (!mounted) return;
    if (!(_tab?.value.enabled ?? true)) {
      // Another tab: play again when this one is shown.
      _played = false;
      _c.value = 0;
      return;
    }
    if (!_played && _onScreen()) {
      _played = true;
      _c.forward(from: 0);
    }
  }

  bool _onScreen() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return false;
    final view = Scrollable.maybeOf(context)?.context.findRenderObject() as RenderBox?;
    if (view == null || !view.hasSize) return true;
    final top = box.localToGlobal(Offset.zero).dy;
    final viewTop = view.localToGlobal(Offset.zero).dy;
    return top < viewTop + view.size.height - 40 && top + box.size.height > viewTop;
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        child: widget.child,
        builder: (context, child) {
          final total = widget.delay + widget.duration;
          final start = total.inMicroseconds == 0 ? 0.0 : widget.delay.inMicroseconds / total.inMicroseconds;
          final raw = start >= 1 ? (_c.value >= 1 ? 1.0 : 0.0) : ((_c.value - start) / (1 - start)).clamp(0.0, 1.0);
          return widget.builder(context, widget.curve.transform(raw), child);
        },
      );
}

/// Fades [child] in while it rises [offset] pixels into place.
class FadeSlideIn extends StatelessWidget {
  const FadeSlideIn({super.key, required this.child, this.delay = Duration.zero, this.offset = 18, this.duration = const Duration(milliseconds: 800)});
  final Widget child;
  final Duration delay;
  final double offset;
  final Duration duration;

  @override
  Widget build(BuildContext context) => Entrance(
        delay: delay,
        duration: duration,
        child: child,
        builder: (context, t, child) => Opacity(
          opacity: t.clamp(0.0, 1.0),
          child: Transform.translate(offset: Offset(0, offset * (1 - t)), child: child),
        ),
      );
}

/// A number counting up to [value] (with [format]) as it comes into view,
/// then running from the shown number to each new [value].
class CountUp extends StatelessWidget {
  const CountUp({super.key, required this.value, required this.format, this.style, this.delay = Duration.zero, this.duration = const Duration(milliseconds: 1400)});
  final double value;
  final String Function(double v) format;
  final TextStyle? style;
  final Duration delay;
  final Duration duration;

  @override
  Widget build(BuildContext context) => Entrance(
        delay: delay,
        duration: duration,
        curve: Curves.easeOutCubic,
        // First a count up from 0; after that a new value runs from the one
        // shown (points spent count down from where they were).
        // (Held, like every score, while a 觀眾加油 celebration covers it.)
        builder: (context, t, _) => LiveScore(
          value: value,
          duration: const Duration(milliseconds: 900),
          builder: (context, v) => Stack(alignment: AlignmentDirectional.centerStart, children: [
            // The final text keeps the width while counting.
            Opacity(opacity: 0, child: Text(format(value), style: style, maxLines: 1)),
            Text(format(v * t), style: style, maxLines: 1),
          ]),
        ),
      );
}

/// Gentle up and down drift (for a floating badge), [amplitude] pixels.
class Bob extends StatefulWidget {
  const Bob({super.key, required this.child, this.amplitude = 4, this.period = const Duration(milliseconds: 3200)});
  final Widget child;
  final double amplitude;
  final Duration period;

  @override
  State<Bob> createState() => _BobState();
}

class _BobState extends State<Bob> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: widget.period)..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        child: widget.child,
        builder: (context, child) => Transform.translate(offset: Offset(0, widget.amplitude * math.sin(_c.value * 2 * math.pi)), child: child),
      );
}
