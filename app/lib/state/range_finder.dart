// The singer's range from live pitch: a key counts once it has been held for
// [RangeFinder.reachSeconds] in all (in the real octave sung). Used before a
// take on the sing screen and by the range check in Settings; the keys found
// are kept in the settings, shared by every song.
import 'package:flutter/foundation.dart';

class RangeFinder {
  RangeFinder([Set<int> initial = const {}]) : keys = ValueNotifier(initial);

  static const reachSeconds = 0.25;

  /// Keys held long enough so far.
  final ValueNotifier<Set<int>> keys;

  final Map<int, double> _time = {};
  double _last = double.nan;

  /// One voiced pitch frame ([midi] at [t] seconds); true when it completed
  /// a new key.
  bool add(double midi, double t) {
    final dt = _last.isNaN ? 0.01 : (t - _last).clamp(0.0, 0.05);
    _last = t;
    final k = midi.round();
    if (k < 24 || k > 108) return false;
    final total = (_time[k] ?? 0) + dt;
    _time[k] = total;
    if (total >= reachSeconds && !keys.value.contains(k)) {
      keys.value = {...keys.value, k};
      return true;
    }
    return false;
  }

  /// Starts over with [initial] (no time held on any other key).
  void reset([Set<int> initial = const {}]) {
    _time.clear();
    _last = double.nan;
    if (!setEquals(keys.value, initial)) keys.value = initial;
  }

  void dispose() => keys.dispose();
}
