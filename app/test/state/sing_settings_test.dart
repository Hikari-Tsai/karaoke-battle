import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/state/sing_settings.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('ke-sing-settings-'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('each song keeps what was last set for it', () async {
    final a = '${tmp.path}/a.json', b = '${tmp.path}/b.json';
    await const SongSingSettings(track: 'mix', pitchShift: -2, volume: 0.3, octaveAlign: false, windowSeconds: 12, metronomeOn: true, metronomeGain: 0.9).save(a);
    final back = await SongSingSettings.load(a);
    expect(back.toJson(), {
      'v': 2,
      'track': 'mix',
      'pitch_shift': -2.0,
      'volume': 0.3,
      'octave_align': false,
      'window_seconds': 12.0,
      'metronome_on': true,
      'metronome_gain': 0.9,
    });
    // Another song is untouched: it still starts from the defaults.
    final other = await SongSingSettings.load(b);
    expect(other.volume, isNull, reason: 'automatic volume');
    expect(other.pitchShift, 0);
    expect(other.track, isNull);
    expect(other.metronomeOn, isNull, reason: 'falls back to the global metronome setting');
  });

  test('a missing, broken or out-of-range file gives safe values', () async {
    final f = File('${tmp.path}/s.json');
    expect((await SongSingSettings.load(f.path)).volume, isNull);
    f.writeAsStringSync('{not json');
    expect((await SongSingSettings.load(f.path)).windowSeconds, 8);
    f.writeAsStringSync('{"track":"karaoke","pitch_shift":9.4,"volume":-1,"window_seconds":"x","octave_align":1,"metronome_gain":7}');
    final s = await SongSingSettings.load(f.path);
    expect(s.track, isNull);
    expect(s.pitchShift, 6);
    expect(s.volume, 0);
    f.writeAsStringSync('{"volume":1.0,"pitch_shift":2}');
    expect((await SongSingSettings.load(f.path)).volume, isNull, reason: '0.7.11 always wrote the default 1.0');
    f.writeAsStringSync('{"v":2,"volume":1.0}');
    expect((await SongSingSettings.load(f.path)).volume, 1.0, reason: 'set by the singer');
    expect(s.windowSeconds, 8);
    expect(s.octaveAlign, isTrue);
    expect(s.metronomeGain, 1.5);
  });

  test('settings that were never set are not written', () {
    expect(const SongSingSettings().toJson().keys, ['v', 'pitch_shift', 'octave_align', 'window_seconds']);
  });
}
