import 'dart:math' as math;
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

  test('every pop-up is anchored on its note start, also when judged late', () {
    expect(run([1.12, 2.12]).marks.map((m) => m.anchor), [1.0, 2.0]);
    expect(run([], until: 1.8).marks.single.anchor, 1.0);
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

  group('speakers leaking into the mic', () {
    // Music plays at -10 dBFS with a beat on every note start; 25 dB of it
    // reaches the mic, whose own noise floor is -70 dB.
    double music(double t) => -10 + ((t % 0.5) < 0.05 ? 6 : 0);
    double power(double db) => math.pow(10, db / 10).toDouble();
    double sum(double a, double b) => 10 * math.log(power(a) + power(b)) / math.ln10;

    LiveJudge take({required bool Function(double t) singing, List<double> extraOnsets = const []}) {
      final j = LiveJudge(notes: notes(), windows: RhythmWindows.forTempo(120));
      for (var t = 0.0; t <= 3.0; t += hop) {
        var mic = sum(music(t) - 25, -70);
        if (singing(t)) mic = sum(mic, -12);
        // The leaked beat makes an onset at every note start, sung or not.
        final onset = near(t, 1.0) || near(t, 2.0) || extraOnsets.any((o) => near(t, o));
        j.addFrame(t, onset: onset, levelDb: mic, playbackDb: music(t));
        j.update(t);
      }
      return j;
    }

    test('a silent singer gets MISS, not the track\'s onsets', () {
      expect(take(singing: (_) => false).marks.map((m) => m.tier), ['miss', 'miss']);
    });

    test('singing over the track is judged as before', () {
      final j = take(singing: (t) => (t >= 1.0 && t < 1.5) || (t >= 2.0 && t < 2.5));
      expect(j.marks.map((m) => m.tier), ['perfect', 'perfect']);
    });

    test('an onset the singer did not follow up is skipped for a later sung one', () {
      // The beat at 1.0 is only the track; the singer comes in at 1.08.
      final j = take(singing: (t) => t >= 1.08 && t < 1.5, extraOnsets: [1.08]);
      expect(j.marks.first.tier, 'great');
      expect(j.marks.first.fast, isFalse);
    });
  });

  group('legato (no new syllable): judged from the pitch', () {
    /// Sings from 0.95 s to 2.6 s with one onset at 0.95 s; [pitch] is the
    /// sung MIDI at time t (NaN = unvoiced). Pitch frames every 10 ms reach
    /// the judge [lag] seconds late (SwiftF0 is ~0.2 s behind).
    LiveJudge legato(double Function(double t) pitch, {double lag = 0, NoteList? n}) {
      final j = LiveJudge(notes: n ?? notes(), windows: RhythmWindows.forTempo(120));
      var nextPitch = 0.0;
      for (var t = 0.0; t <= 3.5; t += hop) {
        final sing = t >= 0.95 && t < 2.6;
        j.addFrame(t, onset: near(t, 0.95), levelDb: sing ? -20 : -80);
        while (nextPitch <= t - lag) {
          j.addPitch(nextPitch, nextPitch >= 0.95 && nextPitch < 2.6 ? pitch(nextPitch) : double.nan);
          nextPitch += 0.01;
        }
        j.update(t);
      }
      return j;
    }

    test('gliding onto the next note on time is PERFECT, with DSP or late SwiftF0 frames', () {
      for (final lag in [0.0, 0.25]) {
        final j = legato((t) => t < 2.02 ? 60 : 64, lag: lag);
        expect(j.marks.map((m) => m.tier), ['perfect', 'perfect'], reason: 'lag $lag');
        expect(j.marks.last.anchor, 2.0);
      }
    });

    test('reaching the note late is LATE; an octave lower still counts', () {
      final late = legato((t) => t < 2.12 ? 60 : 64);
      expect(late.marks.last.tier, 'good');
      expect(late.marks.last.fast, isFalse);
      expect(legato((t) => t < 2.0 ? 60 : 52).marks.last.tier, 'perfect');
    });

    test('never reaching the note, or a pitch blip, gives no pop-up', () {
      expect(legato((t) => 60).marks.length, 1);
      expect(legato((t) => (t > 2.0 && t < 2.02) ? 64 : 60).marks.length, 1, reason: '20 ms is too short');
    });

    test('a note on the same pitch held over is not a new arrival', () {
      final same = NoteList(Float64List.fromList([1.0, 2.0]), Float64List.fromList([1.6, 2.6]), Float64List.fromList([60, 60]));
      expect(legato((t) => 60, n: same).marks.length, 1);
    });
  });

  group('pitch judging (setting)', () {
    /// Onsets on time at 1.0 and 2.0 s, singing [pitch] (MIDI at t); pitch
    /// frames every 10 ms arrive [lag] s late.
    LiveJudge sung(double Function(double t) pitch, {bool judgePitch = true, double lag = 0}) {
      final j = LiveJudge(notes: notes(), windows: RhythmWindows.forTempo(120), judgePitch: judgePitch);
      var nextPitch = 0.0;
      for (var t = 0.0; t <= 3.5; t += hop) {
        final sing = (t >= 1.0 && t < 1.6) || (t >= 2.0 && t < 2.6);
        j.addFrame(t, onset: near(t, 1.0) || near(t, 2.0), levelDb: sing ? -20 : -80);
        while (nextPitch <= t - lag) {
          final on = (nextPitch >= 1.0 && nextPitch < 1.6) || (nextPitch >= 2.0 && nextPitch < 2.6);
          j.addPitch(nextPitch, on ? pitch(nextPitch) : double.nan);
          nextPitch += 0.01;
        }
        j.update(t);
      }
      return j;
    }

    test('in tune stays PERFECT; sharp and flat drop the tier and tag HIGH / LOW', () {
      final inTune = sung((t) => t < 1.8 ? 60.05 : 64);
      expect(inTune.marks.map((m) => m.tier), ['perfect', 'perfect']);
      expect(inTune.marks.every((m) => m.high == null), isTrue);
      final off = sung((t) => t < 1.8 ? 60.4 : 63.75);
      expect(off.marks.map((m) => m.tier), ['good', 'great']);
      expect(off.marks.map((m) => m.high), [true, false]);
    });

    test('waits for the pitch: the pop-up comes after the read span, also with late frames', () {
      for (final lag in [0.0, 0.25]) {
        final j = sung((t) => t < 1.8 ? 61 : 64, lag: lag);
        expect(j.marks.first.tier, 'miss', reason: 'a semitone off (lag $lag)');
        expect(j.marks.first.high, isTrue);
        expect(j.marks.first.time, greaterThanOrEqualTo(1.0 + LiveJudge.pitchSkipSeconds + LiveJudge.pitchWindowSeconds + lag - 0.01));
        expect(j.marks.first.anchor, 1.0);
      }
    });

    test('an octave off is in tune when folded; off, timing only without the setting', () {
      expect(sung((t) => t < 1.8 ? 48 : 52).marks.map((m) => m.tier), ['perfect', 'perfect']);
      final timingOnly = sung((t) => 61, judgePitch: false);
      expect(timingOnly.marks.map((m) => m.tier), ['perfect', 'perfect']);
      expect(timingOnly.marks.first.time, closeTo(1.0, 0.006));
    });

    test('too little voiced pitch: judged on timing alone', () {
      expect(sung((t) => double.nan).marks.map((m) => m.tier), ['perfect', 'perfect']);
    });
  });
}
