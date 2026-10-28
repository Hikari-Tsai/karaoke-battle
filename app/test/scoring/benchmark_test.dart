import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/scoring/scoring.dart';

import 'synthetic.dart';

void main() {
  test('scores a 5-minute song in under 2 s', () {
    final notes = makeMelody(seed: 21, duration: 300);
    final end = songEnd(notes);
    final ref = synthesizeTrack(end, (t) => midiOfNotes(notes, t));
    final rng = math.Random(1);
    // Slightly late, slightly sharp, with a little pitch noise and vibrato.
    final take = synthesizeTrack(end + 0.12, (t) {
      final m = midiOfNotes(notes, t - 0.12);
      if (m == null) return null;
      return m +
          0.1 +
          0.05 * (rng.nextDouble() - 0.5) +
          0.25 * math.sin(2 * math.pi * 5.8 * t);
    });
    final input = ScoringInput(
      referenceNotes: ReferenceNotes(notes: notes),
      referenceF0: ref,
      takeF0: take,
      referenceEnergy: synthesizeEnergy(notes, end),
      takeEnergy: synthesizeEnergy(notes, end + 0.12, delay: 0.12),
    );
    expect(take.length, greaterThan(18000));

    // Warm-up (JIT) then timed run.
    Scorer.score(input);
    final sw = Stopwatch()..start();
    final result = Scorer.score(input);
    sw.stop();
    // ignore: avoid_print
    print(
      '5-minute song (${take.length} frames, ${notes.length} notes): '
      '${sw.elapsedMilliseconds} ms, total ${result.total.toStringAsFixed(1)} '
      '${result.rank}, k=${result.shift}',
    );
    expect(sw.elapsedMilliseconds, lessThan(2000));
    expect(result.frameMetrics.rawChromaAccuracy, greaterThan(0.95));
    expect(result.total, greaterThan(80));
  });
}
