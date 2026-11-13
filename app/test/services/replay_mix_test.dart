import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/replay_mix.dart';

void main() {
  test('the replay balance keeps both at 0, fades one side out at the ends', () {
    expect(replayStemGains(0), (1.0, 1.0));
    final (m1, v1) = replayStemGains(1);
    expect(m1, closeTo(0, 1e-9));
    expect(v1, 1.0);
    final (m2, v2) = replayStemGains(-1);
    expect((m2, v2.abs() < 1e-9), (1.0, true));
    // Half way is -3 dB (equal power).
    final (half, _) = replayStemGains(0.5);
    expect(half, closeTo(math.sqrt1_2, 1e-9));
    expect(replayStemGains(5), replayStemGains(1), reason: 'clamped');
  });
}
