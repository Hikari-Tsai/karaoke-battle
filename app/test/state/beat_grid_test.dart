import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/state/beat_grid.dart';

void main() {
  // 120 BPM, 4/4, music starts at 1.25 s (silence before).
  final detected = DetectedBeats(
    beats: [for (var i = 0; i < 16; i++) 1.25 + i * 0.5],
    downbeats: [for (var i = 0; i < 4; i++) 1.25 + i * 2.0],
    bpm: 120,
    signature: 4,
    mode: 'constant',
  );

  test('detected grid keeps beats and downbeat accents', () {
    final g = BeatGrid.build(detected, const TempoOverride(), duration: 30);
    expect(g.times.first, 1.25);
    expect(g.times.length, 16);
    expect(g.accents.where((a) => a).length, 4);
    expect(g.accents[0], isTrue);
    expect(g.accents[1], isFalse);
    expect(g.accents[4], isTrue);
    expect(g.bpm, 120);
    expect(g.manual, isFalse);
  });

  test('moving only the first beat shifts the detected grid', () {
    final g = BeatGrid.build(detected, const TempoOverride(firstBeat: 1.35), duration: 30);
    expect(g.times.first, closeTo(1.35, 1e-9));
    expect(g.accents[0], isTrue);
    expect(g.firstBeat, closeTo(1.35, 1e-9));
  });

  test('manual BPM builds an even grid from the first downbeat, back to 0 s', () {
    final g = BeatGrid.build(detected, const TempoOverride(bpm: 100, beatsPerBar: 3), duration: 6);
    // Period 0.6 s anchored at 1.25 s: 0.05, 0.65, 1.25, 1.85, ...
    expect(g.times.first, closeTo(0.05, 1e-9));
    expect(g.times[2], closeTo(1.25, 1e-9));
    expect(g.accents[2], isTrue); // the first downbeat
    expect(g.accents[5], isTrue); // three beats later
    expect(g.accents[3], isFalse);
    expect(g.times.last, lessThanOrEqualTo(6));
    expect(g.manual, isTrue);
  });

  test('manual BPM without any detection starts at the given first beat', () {
    final g = BeatGrid.build(null, const TempoOverride(bpm: 60, firstBeat: 2), duration: 5);
    expect(g.times, [0, 1, 2, 3, 4, 5]);
    expect(g.accents, [false, false, true, false, false, false]);
  });

  test('nothing detected and no BPM gives an empty grid', () {
    expect(BeatGrid.build(null, const TempoOverride(), duration: 10).isEmpty, isTrue);
  });

  test('tap tempo fits a line through the taps', () {
    final r = BeatGrid.fromTaps([2.02, 2.51, 2.99, 3.50, 4.01])!;
    expect(r.bpm, closeTo(120, 1.0));
    expect(r.firstBeat, closeTo(2.0, 0.03));
    expect(BeatGrid.fromTaps([1.0]), isNull);
    expect(BeatGrid.fromTaps([1.0, 1.01]), isNull); // too fast to be a beat
  });

  test('override json round trip and empty override', () {
    const o = TempoOverride(bpm: 98.5, firstBeat: 0.8, beatsPerBar: 3);
    final r = TempoOverride.fromJson(o.toJson());
    expect(r.bpm, 98.5);
    expect(r.firstBeat, 0.8);
    expect(r.beatsPerBar, 3);
    expect(const TempoOverride().isEmpty, isTrue);
  });
}
