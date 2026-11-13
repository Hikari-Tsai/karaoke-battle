import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/state/loudness.dart';

void main() {
  test('reads the integrated loudness and sample peak from the ebur128 summary', () {
    const stderr = '''
[Parsed_ebur128_0 @ 0x6000] t: 1.2  TARGET:-23 LUFS    M: -20.1 S: -21.0     I: -19.9 LUFS       LRA:   0.0 LU  SPK:  -3.0 dBFS
[Parsed_ebur128_0 @ 0x6000] Summary:

  Integrated loudness:
    I:         -14.6 LUFS
    Threshold: -24.8 LUFS

  Loudness range:
    LRA:         6.2 LU

  Sample peak:
    Peak:       -0.4 dBFS
''';
    final l = parseEbur128Summary(stderr)!;
    expect(l.lufs, -14.6, reason: 'the summary, not a running value');
    expect(l.peakDb, -0.4);
    expect(parseEbur128Summary('no summary'), isNull);
    expect(parseEbur128Summary('Summary:\n I: -70.0 LUFS\n Peak: -inf dBFS')!.peakDb, -120);
  });

  test('the automatic volume brings a track to the target, within the peak and slider', () {
    double db(double g) => 20 * math.log(g) / math.ln10;
    const loud = SongLoudness(inst: TrackLoudness(lufs: -8, peakDb: 0), mix: TrackLoudness(lufs: -20, peakDb: -12));
    expect(db(loud.autoGain('inst')!), closeTo(-8, 0.01), reason: '-8 LUFS down to -16');
    expect(db(loud.autoGain('mix')!), closeTo(4, 0.01), reason: '-20 LUFS up to -16, the peak stays under -1 dBFS');
    const peaky = SongLoudness(inst: TrackLoudness(lufs: -22, peakDb: -3));
    expect(db(peaky.autoGain('inst')!), closeTo(2, 0.01), reason: 'limited by the peak: -3 + 2 = -1 dBFS');
    const quiet = SongLoudness(inst: TrackLoudness(lufs: -40, peakDb: -30));
    expect(quiet.autoGain('inst'), SongLoudness.maxGain);
    const silent = SongLoudness(inst: TrackLoudness(lufs: -70, peakDb: -120));
    expect(silent.autoGain('inst'), isNull);
    expect(const SongLoudness().autoGain('mix'), isNull);
  });

  test('the volume slider is in decibels: mute, then -30 dB .. +12 dB', () {
    double db(double g) => 20 * math.log(g) / math.ln10;
    expect(SongLoudness.gainFromSlider(0), 0);
    expect(db(SongLoudness.gainFromSlider(1)), closeTo(12, 1e-9));
    expect(db(SongLoudness.maxGain), closeTo(12, 1e-9));
    expect(SongLoudness.sliderFromGain(1.0), closeTo(30 / 42, 1e-9), reason: '0 dB');
    for (final g in [0.05, 0.36, 1.0, 2.95, SongLoudness.maxGain]) {
      expect(SongLoudness.gainFromSlider(SongLoudness.sliderFromGain(g)), closeTo(g, 1e-9));
    }
    expect(SongLoudness.sliderFromGain(0), 0);
    expect(SongLoudness.gainDb(1.0), '+0.0 dB');
    expect(SongLoudness.gainDb(0), isNull);
  });

  test('a very quiet track can now be raised up to the peak limit', () {
    double db(double g) => 20 * math.log(g) / math.ln10;
    // Measured in the library: -26.6 LUFS, peak -10.4 dBFS: +9.4 dB (peak) instead of +6 dB (old cap).
    const l = SongLoudness(inst: TrackLoudness(lufs: -26.6, peakDb: -10.4));
    expect(db(l.autoGain('inst')!), closeTo(9.4, 0.01));
  });

  test('saves and loads loudness.json; a broken file is ignored', () async {
    final dir = Directory.systemTemp.createTempSync('ke-loud-');
    final path = '${dir.path}/loudness.json';
    await const SongLoudness(inst: TrackLoudness(lufs: -12.5, peakDb: -0.8)).save(path);
    final back = (await SongLoudness.load(path))!;
    expect(back.inst!.lufs, -12.5);
    expect(back.mix, isNull);
    File(path).writeAsStringSync('{oops');
    expect(await SongLoudness.load(path), isNull);
    dir.deleteSync(recursive: true);
  });
}
