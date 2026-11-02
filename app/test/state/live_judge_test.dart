import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/scoring/rhythm.dart';
import 'package:karaoke_battle/state/live_judge.dart';
import 'package:karaoke_battle/state/song_data.dart';

void main() {
  const hop = 0.01;

  // Two notes: C4 at 1.0–1.6 s and E4 at 2.0–2.6 s.
  NoteList notes() => NoteList(
        Float64List.fromList([1.0, 2.0]),
        Float64List.fromList([1.6, 2.6]),
        Float64List.fromList([60, 64]),
      );

  /// Feeds frames every 10 ms from 0 to [until]; [pitch] gives the sung
  /// MIDI pitch at a time (NaN = silent).
  LiveJudge run(double Function(double t) pitch, {double until = 3.0, double shift = 0}) {
    final j = LiveJudge(notes: notes(), windows: RhythmWindows.forTempo(120), pitchShift: shift);
    for (var t = 0.0; t <= until; t += hop) {
      j.addFrame(t, pitch(t));
      j.update(t);
    }
    return j;
  }

  double sung(double t, {double early = 0, double cents = 0}) {
    if (t >= 1.0 - early && t < 1.6) return 60 + cents / 100;
    if (t >= 2.0 - early && t < 2.6) return 64 + cents / 100;
    return double.nan;
  }

  test('on time and in tune: PERFECT with no tags', () {
    final j = run((t) => sung(t));
    expect(j.marks.map((m) => m.tier), ['perfect', 'perfect']);
    expect(j.marks.every((m) => m.fast == null && m.high == null), isTrue);
    expect(j.marks.first.time, closeTo(1.3, 1e-9), reason: 'pops up 0.3 s after the onset');
  });

  test('early entry: GREAT with FAST', () {
    final j = run((t) => sung(t, early: 0.08));
    expect(j.marks.map((m) => m.tier), ['great', 'great']);
    expect(j.marks.first.fast, isTrue);
  });

  test('on time but 40 cents flat: GOOD with LOW', () {
    final j = run((t) => sung(t, cents: -40));
    expect(j.marks.map((m) => m.tier), ['good', 'good']);
    expect(j.marks.first.high, isFalse);
    expect(j.marks.first.fast, isNull);
  });

  test('silence is a MISS; an octave off is still in tune', () {
    final silent = run((t) => double.nan);
    expect(silent.marks.map((m) => m.tier), ['miss', 'miss']);
    final octave = run((t) => sung(t) - 12);
    expect(octave.marks.map((m) => m.tier), ['perfect', 'perfect']);
  });

  test('the key shift moves the target', () {
    final j = run((t) => sung(t) + 2, shift: 2);
    expect(j.marks.map((m) => m.tier), ['perfect', 'perfect']);
  });

  test('waits for late frames, then judges anyway', () {
    final j = LiveJudge(notes: notes(), windows: RhythmWindows.forTempo(120));
    for (var t = 1.0; t < 1.2; t += hop) {
      j.addFrame(t, 60);
    }
    expect(j.update(1.35), isFalse, reason: 'frames only reach 1.2 s; judgement time is 1.3 s');
    expect(j.update(1.61), isTrue, reason: 'gives up waiting after 0.3 s');
    expect(j.marks.single.tier, 'perfect');
  });
}
