// A score on screen that follows its take: when the total changes while it
// is shown (觀眾加油 adding points, a Tuning Wand), it counts up (or down)
// from the number shown to the new one instead of jumping. The first value
// is shown as it is.
import 'package:flutter/material.dart';

import '../../scoring/models.dart' show rankForTotal;

/// How long a changed score takes to count to its new value.
const kLiveScoreDuration = Duration(milliseconds: 1600);

/// The rank to show beside [shown] while counting to [total] (whose rank
/// is [rank]): the stored rank once there, the rank of the number on the way.
String? liveRank(double shown, double total, String? rank) => (shown - total).abs() < 0.005 ? rank : rankForTotal(shown);

/// While on (a 觀眾加油 celebration covers the screen, or is about to),
/// changed scores wait, and count up once it is gone, where they can be
/// seen.
abstract final class LiveScoreHold {
  static final notifier = ValueNotifier<bool>(false);
}

/// Builds with the number to show for [value], counting to each new value.
class LiveScore extends StatefulWidget {
  const LiveScore({super.key, required this.value, required this.builder, this.duration = kLiveScoreDuration});
  final double value;
  final Widget Function(BuildContext context, double shown) builder;
  final Duration duration;

  @override
  State<LiveScore> createState() => _LiveScoreState();
}

class _LiveScoreState extends State<LiveScore> {
  late double _target = widget.value;

  @override
  void initState() {
    super.initState();
    LiveScoreHold.notifier.addListener(_catchUp);
  }

  @override
  void didUpdateWidget(LiveScore old) {
    super.didUpdateWidget(old);
    if (!LiveScoreHold.notifier.value) _target = widget.value;
  }

  @override
  void dispose() {
    LiveScoreHold.notifier.removeListener(_catchUp);
    super.dispose();
  }

  void _catchUp() {
    if (!LiveScoreHold.notifier.value && mounted && _target != widget.value) setState(() => _target = widget.value);
  }

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween<double>(end: _target),
        duration: widget.duration,
        curve: Curves.easeOutCubic,
        builder: (context, v, _) => widget.builder(context, v),
      );
}

/// A total as text (one decimal), counting to each new value.
class LiveScoreText extends StatelessWidget {
  const LiveScoreText(this.value, {super.key, this.style, this.digits = 1});
  final double value;
  final TextStyle? style;
  final int digits;

  @override
  Widget build(BuildContext context) => LiveScore(value: value, builder: (context, v) => Text(v.toStringAsFixed(digits), style: style));
}
