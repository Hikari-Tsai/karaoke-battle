import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/scoring/rhythm.dart';
import 'package:karaoke_battle/state/live_judge.dart';
import 'package:karaoke_battle/state/song_data.dart';

void main() {
  const hop = 0.005;

  // Two notes: C4 at 1.0–1.6 s and E4 at 2.0–2.6 s.
  NoteList notes() => NoteList(
        Float64List.fromList([1.0, 2.0]),
        Float64List.fromList([1.6, 2.6]),
        Float64List.fromList([60, 64]),
      );

  bool near(double t, double at) => (t - at).abs() < hop / 2;

  /// Feeds onset frames every 5 ms from 0 to [until]: an onset at each time
  /// in [onsets], singing (-20 dB) while [singing] holds, else silence.
  LiveJudge run(List<double> onsets, {bool Function(double t)? singing, double until = 3.0, double shift = 0}) {
    final j = LiveJudge(notes: notes(), windows: RhythmWindows.forTempo(120), pitchShift: shift);
    for (var t = 0.0; t <= until; t += hop) {
      final sing = singing?.call(t) ?? onsets.any((o) => t >= o && t < o + 0.5);
      j.addFrame(t, onset: onsets.any((o) => near(t, o)), levelDb: sing ? -20 : -80);
      j.update(t);
    }
    return j;
  }

  test('on time: PERFECT with no tags, shown as soon as the onset arrives', () {
    final j = run([1.0, 2.0]);
    expect(j.marks.map((m) => m.tier), ['perfect', 'perfect']);
    expect(j.marks.every((m) => m.fast == null && m.high == null), isTrue);
    expect(j.marks.first.time, closeTo(1.0, 0.006));
  });

  test('early entry: GREAT with FAST; late: GOOD with LATE; never HIGH/LOW', () {
    final early = run([0.92, 1.92]);
    expect(early.marks.map((m) => m.tier), ['great', 'great']);
    expect(early.marks.first.fast, isTrue);
    final late = run([1.12, 2.12]);
    expect(late.marks.map((m) => m.tier), ['good', 'good']);
    expect(late.marks.first.fast, isFalse);
    expect([...early.marks, ...late.marks].every((m) => m.high == null), isTrue);
  });

  test('silence is a MISS when the window closes', () {
    final silent = run([], until: 1.8);
    final w = RhythmWindows.forTempo(120).good;
    expect(silent.marks.single.tier, 'miss');
    expect(silent.marks.single.time, closeTo(1.0 + w, 0.006));
  });

  test('singing through without a new onset gives no pop-up', () {
    // One syllable held from 0.95 s over the second note's onset.
    final j = run([0.95], singing: (t) => t >= 0.95 && t < 2.6);
    expect(j.marks.map((m) => m.tier), ['perfect'], reason: 'only the first note has an onset (50 ms early is still PERFECT)');
  });

  test('an onset is claimed by the nearer note only', () {
    // 1.45 s is closer to note 1 (1.0) than to note 2 (2.0): outside both
    // GOOD windows anyway, so both notes miss rather than share it.
    final j = run([1.45], singing: (t) => false);
    expect(j.marks.map((m) => m.tier), ['miss', 'miss']);
  });

  test('the key shift moves where the pop-up is drawn', () {
    final j = run([1.0, 2.0], shift: 2);
    expect(j.marks.map((m) => m.midi), [62, 66]);
  });

  test('waits for late frames, then judges anyway', () {
    final j = LiveJudge(notes: notes(), windows: RhythmWindows.forTempo(120));
    for (var t = 0.9; t < 1.05; t += hop) {
      j.addFrame(t, onset: false, levelDb: -20);
    }
    expect(j.update(1.2), isFalse, reason: 'frames only reach 1.05 s; the window closes at 1.15 s');
    expect(j.update(1.7), isFalse, reason: 'still waiting');
    expect(j.update(1.76), isFalse, reason: 'gave up waiting, but the singer was singing: no pop-up');
    final silent = LiveJudge(notes: notes(), windows: RhythmWindows.forTempo(120));
    silent.addFrame(1.0, onset: false, levelDb: -80);
    expect(silent.update(1.76), isTrue);
    expect(silent.marks.single.tier, 'miss');
    expect(silent.marks.single.time, 1.76, reason: 'shown from when it was judged');
  });

  test('frames arriving late: the pop-up starts when it is shown', () {
    const lag = 0.05;
    final j = LiveJudge(notes: notes(), windows: RhythmWindows.forTempo(120));
    final shownAt = <double>[];
    for (var t = 0.0; t <= 3.0; t += hop) {
      final ft = t - lag; // the frame for track time ft arrives at playback t
      if (ft >= 0) j.addFrame(ft, onset: near(ft, 1.0) || near(ft, 2.0), levelDb: -20);
      if (j.update(t)) shownAt.add(t);
    }
    expect(j.marks.map((m) => m.tier), ['perfect', 'perfect']);
    expect(j.marks.map((m) => m.time), shownAt);
    expect(j.marks.first.time, closeTo(1.0 + lag, 0.006));
  });
}
