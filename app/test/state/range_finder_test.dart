import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/settings.dart';
import 'package:karaoke_battle/state/range_finder.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  /// Holds [midi] for [seconds] with 10 ms frames from [t0].
  void hold(RangeFinder f, double midi, double t0, double seconds) {
    for (var t = t0; t < t0 + seconds; t += 0.01) {
      f.add(midi, t);
    }
  }

  test('a key counts once held about 0.25 s in all, in its real octave', () {
    final f = RangeFinder();
    hold(f, 55.2, 0, 0.1);
    expect(f.keys.value, isEmpty);
    hold(f, 55.0, 1, 0.2);
    expect(f.keys.value, {55}, reason: 'time adds up across holds');
    hold(f, 67, 2, 0.3);
    expect(f.keys.value, {55, 67});
    f.reset();
    expect(f.keys.value, isEmpty);
    hold(f, 55, 3, 0.1);
    expect(f.keys.value, isEmpty, reason: 'reset forgets the time held too');
  });

  test('starts from the saved range and keeps adding to it', () {
    final f = RangeFinder({48, 60});
    hold(f, 62, 0, 0.3);
    expect(f.keys.value, {48, 60, 62});
  });

  test('the range is saved in the settings, shared, and can be reset', () async {
    SharedPreferences.setMockInitialValues({});
    final s = await AppSettings.load();
    expect(s.ownRangeKeys, isEmpty);
    await s.setOwnRangeKeys({62, 45, 50});
    expect((await AppSettings.load()).ownRangeKeys, {45, 50, 62});
    await s.setOwnRangeKeys(const {});
    expect((await AppSettings.load()).ownRangeKeys, isEmpty);
  });
}
