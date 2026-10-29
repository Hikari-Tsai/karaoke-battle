import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/scoring/scoring.dart';

import 'synthetic.dart';

void main() {
  // Notes of 0.4-0.8 s so onset shifts never swallow a whole note.
  final notes = makeMelody(seed: 3, duration: 30, durations: const [0.4, 0.5, 0.6, 0.8]);
  final end = songEnd(notes);
  final ref = synthesizeTrack(end, (t) => midiOfNotes(notes, t));

  /// Take whose note i starts [delay(i)] seconds late (offsets unchanged),
  /// the whole take shifted by [global].
  F0Track take(double Function(int i) delay, {double global = 0}) => synthesizeTrack(end + global + 0.5, (t) {
        final u = t - global;
        for (var i = 0; i < notes.length; i++) {
          final n = notes[i];
          if (u >= n.onset + delay(i) && u < n.offset) return n.pitch;
        }
        return null;
      });

  ScoreResult score(F0Track t, {bool calibrated = false, double? bpm}) => Scorer.score(ScoringInput(
        referenceNotes: ReferenceNotes(notes: notes),
        referenceF0: ref,
        takeF0: t,
        options: ScoringOptions(calibratedTiming: calibrated, tempoBpm: bpm),
      ));

  test('windows follow the tempo (faster = stricter), clamped', () {
    expect(RhythmWindows.forTempo(null).perfect, closeTo(0.05, 1e-9));
    expect(RhythmWindows.forTempo(120).great, closeTo(0.10, 1e-9));
    expect(RhythmWindows.forTempo(160).perfect, closeTo(0.0375, 1e-9));
    expect(RhythmWindows.forTempo(60).good, closeTo(0.225, 1e-9)); // 1.5x cap
    expect(RhythmWindows.forTempo(240).perfect, closeTo(0.0375, 1e-9)); // 0.75x cap
  });

  test('the original itself is all PERFECT with full rhythm marks', () {
    final r = score(ref).rhythm!;
    expect(r.counts['perfect'], r.noteIndex.length);
    expect(r.score, closeTo(1, 1e-9));
  });

  test('a uniformly late take is forgiven when latency is not calibrated', () {
    final r = score(take((_) => 0, global: 0.08)).rhythm!;
    expect(r.counts['perfect'], r.noteIndex.length);
    expect(r.tendency, 'none'); // no trusted clock -> no rushing/dragging verdict
  });

  test('with a calibrated clock the same take is judged late (dragging)', () {
    final r = score(take((_) => 0, global: 0.08), calibrated: true).rhythm!;
    expect(r.counts['great'], greaterThan(r.noteIndex.length * 0.8));
    expect(r.tendency, 'dragging');
    expect(r.tendencyMs, closeTo(80, 20));
  });

  test('per-note lateness lands in PERFECT / GREAT / GOOD / MISS tiers', () {
    // Cycle 30 / 75 / 125 / 250 ms late per note.
    const delays = [0.03, 0.075, 0.125, 0.25];
    final r = score(take((i) => delays[i % 4]), calibrated: true).rhythm!;
    final byTier = <String, int>{};
    for (var k = 0; k < r.noteIndex.length; k++) {
      final i = r.noteIndex[k];
      final expected = ['perfect', 'great', 'good', 'miss'][i % 4];
      if (r.onset[k].name == expected) byTier[expected] = (byTier[expected] ?? 0) + 1;
    }
    // At least 80 % of the notes of each tier land in it (16 ms frames).
    for (final t in ['perfect', 'great', 'good', 'miss']) {
      final total = r.noteIndex.where((i) => ['perfect', 'great', 'good', 'miss'][i % 4] == t).length;
      expect(byTier[t] ?? 0, greaterThanOrEqualTo((total * 0.8).floor()), reason: t);
    }
    expect(r.score, lessThan(0.75));
    expect(r.score, greaterThan(0.35));
  });

  test('a slow song widens the windows: 125 ms late becomes GREAT at 60 BPM', () {
    final fast = score(take((_) => 0.125), calibrated: true, bpm: 120).rhythm!;
    final slow = score(take((_) => 0.125), calibrated: true, bpm: 60).rhythm!;
    expect(fast.counts['good']! + fast.counts['miss']!, greaterThan(fast.noteIndex.length * 0.8));
    expect(slow.counts['great'], greaterThan(slow.noteIndex.length * 0.8));
    expect(slow.score, greaterThan(fast.score));
  });
}
