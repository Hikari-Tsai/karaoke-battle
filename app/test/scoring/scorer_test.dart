import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/scoring/scoring.dart';

import 'synthetic.dart';

void main() {
  group('pitch helpers', () {
    test('hz <-> midi and chroma delta', () {
      expect(hzToMidi(440), closeTo(69, 1e-9));
      expect(midiToHz(60), closeTo(261.6256, 1e-3));
      expect(chromaDelta(60, 72), closeTo(0, 1e-9));
      expect(chromaDelta(60.3, 71.9), closeTo(0.4, 1e-9));
      expect(chromaDelta(59.5, 72), closeTo(-0.5, 1e-9));
      expect(chromaDistance(64, 70), closeTo(6, 1e-9));
    });
  });

  group('(a) identical take', () {
    final notes = makeMelody(seed: 7, duration: 40);
    final end = songEnd(notes);
    final ref = synthesizeTrack(end, (t) => midiOfNotes(notes, t));
    final input = ScoringInput(
      referenceNotes: ReferenceNotes(notes: notes),
      referenceF0: ref,
      takeF0: ref,
      referenceEnergy: synthesizeEnergy(notes, end),
      takeEnergy: synthesizeEnergy(notes, end),
    );
    final result = Scorer.score(input);

    test('frame metrics are perfect', () {
      expect(result.shift, 0);
      expect(result.octaveExactShift, 0);
      expect(result.frameMetrics.rawPitchAccuracy, closeTo(1, 1e-6));
      expect(result.frameMetrics.rawChromaAccuracy, closeTo(1, 1e-6));
      expect(result.frameMetrics.voicingRecall, closeTo(1, 1e-6));
      expect(result.frameMetrics.voicingFalseAlarm, closeTo(0, 1e-6));
      expect(result.frameMetrics.overallAccuracy, closeTo(1, 1e-6));
    });

    test('note metrics match every reference note', () {
      final n = result.noteMetrics;
      expect(n.takeNotes.length, notes.length);
      expect(n.onset.f1, closeTo(1, 1e-6));
      expect(n.onsetPitch.f1, closeTo(1, 1e-6));
      expect(n.onsetPitchOffset.f1, closeTo(1, 1e-6));
      expect(n.medianAbsOnsetErrorMs, lessThan(17));
      expect(n.medianAbsOffsetErrorMs, lessThan(17));
      for (final r in n.perNote) {
        expect(r.matched, isTrue);
        expect(r.matchedOffset, isTrue);
        expect(r.centsDeviation, closeTo(0, 1e-6));
        expect(r.overlapIoU, greaterThan(0.8));
        expect(r.voicedFraction, closeTo(1, 1e-6));
      }
    });

    test('technique and total are perfect', () {
      expect(result.technique.longToneScore, closeTo(1, 1e-6));
      expect(result.technique.pitchStabilityCents, closeTo(0, 1e-6));
      expect(result.technique.expressionCorrelation, closeTo(1, 1e-6));
      expect(result.technique.referenceVibratoFraction, 0);
      expect(result.subScores.vibrato.value, isNull);
      expect(result.total, closeTo(100, 1e-6));
      expect(result.rank, 'SSS');
    });

    test('notes-only reference caps vibrato at the target fraction', () {
      final r = Scorer.score(
        ScoringInput(
          referenceNotes: ReferenceNotes(notes: notes),
          takeF0: ref,
        ),
      );
      expect(r.frameMetrics.rawChromaAccuracy, closeTo(1, 1e-6));
      expect(r.subScores.vibrato.value, 0);
      expect(r.subScores.expression.value, isNull);
      // 40 + 20 + 10 + 0 + 10 out of 90 available points.
      expect(r.total, closeTo(100 * 80 / 90, 1e-6));
    });
  });

  group('(b) transposition', () {
    final notes = makeMelody(seed: 3, duration: 30);
    final end = songEnd(notes);
    final ref = synthesizeTrack(end, (t) => midiOfNotes(notes, t));

    test('+3 semitones and one octave down -> k = 9, RCA = 1', () {
      final take = synthesizeTrack(end, (t) {
        final m = midiOfNotes(notes, t);
        return m == null ? null : m + 3 - 12;
      });
      final r = Scorer.score(
        ScoringInput(
          referenceNotes: ReferenceNotes(notes: notes),
          referenceF0: ref,
          takeF0: take,
        ),
      );
      expect(r.shift, 9);
      expect(r.octaveExactShift, 9);
      expect(r.frameMetrics.rawChromaAccuracy, closeTo(1, 1e-6));
      expect(r.noteMetrics.onsetPitch.f1, closeTo(1, 1e-6));
      expect(r.total, closeTo(100, 1e-6));
    });

    test('pure octave down -> k = 0, octave-exact 12, RCA = 1, RPA = 0', () {
      final take = synthesizeTrack(end, (t) {
        final m = midiOfNotes(notes, t);
        return m == null ? null : m - 12;
      });
      final r = Scorer.score(
        ScoringInput(
          referenceNotes: ReferenceNotes(notes: notes),
          takeF0: take,
        ),
      );
      expect(r.shift, 0);
      expect(r.octaveExactShift, 12);
      expect(r.frameMetrics.rawChromaAccuracy, closeTo(1, 1e-6));
      expect(r.frameMetrics.rawPitchAccuracy, closeTo(0, 1e-6));
      expect(r.frameMetrics.rawPitchAccuracyOctaveExact, closeTo(1, 1e-6));
      expect(r.subScores.pitch.value, closeTo(1, 1e-6));
      expect(r.technique.longToneScore, closeTo(1, 1e-6));
    });

    test('shift estimators on raw arrays', () {
      final a = [60.0, 62.0, double.nan, 64.0];
      final b = [67.0, 69.0, 65.0, 71.0];
      expect(estimateChromaShift(a, b), 7);
      expect(estimateOctaveExactShift(a, b), 7);
      expect(estimateChromaShift(b, a), 5);
      expect(estimateOctaveExactShift(b, a), -7);
    });
  });

  group('(c) time alignment', () {
    final notes = makeMelody(seed: 11, duration: 25);
    final end = songEnd(notes);
    final ref = synthesizeTrack(end, (t) => midiOfNotes(notes, t));

    test('300 ms delay is absorbed by DTW', () {
      final take = synthesizeTrack(
        end + 0.3,
        (t) => midiOfNotes(notes, t - 0.3),
      );
      final r = Scorer.score(
        ScoringInput(
          referenceNotes: ReferenceNotes(notes: notes),
          referenceF0: ref,
          takeF0: take,
        ),
      );
      expect(r.alignment.mode, AlignmentMode.dtw);
      expect(r.alignment.offsetSeconds, closeTo(0.3, 0.02));
      expect(r.alignment.takeTimeToRefTime(5.3), closeTo(5.0, 0.02));
      expect(r.alignment.refTimeToTakeTime(5.0), closeTo(5.3, 0.02));
      expect(r.frameMetrics.rawChromaAccuracy, greaterThan(0.98));
      expect(r.noteMetrics.onset.f1, greaterThan(0.95));
      expect(r.noteMetrics.medianAbsOnsetErrorMs, lessThan(20));
      expect(r.noteMetrics.medianAbsOffsetErrorMs, lessThan(20));
      expect(r.total, greaterThan(95));
    });

    test('300 ms delay with the fixed-offset mode', () {
      final take = synthesizeTrack(
        end + 0.3,
        (t) => midiOfNotes(notes, t - 0.3),
      );
      final r = Scorer.score(
        ScoringInput(
          referenceNotes: ReferenceNotes(notes: notes),
          takeF0: take,
          options: const ScoringOptions(
            alignmentMode: AlignmentMode.fixedOffset,
          ),
        ),
      );
      expect(r.alignment.mode, AlignmentMode.fixedOffset);
      expect(r.alignment.offsetSeconds, closeTo(0.3, 0.02));
      expect(r.frameMetrics.rawChromaAccuracy, greaterThan(0.98));
      expect(r.noteMetrics.onset.f1, greaterThan(0.95));
      expect(r.noteMetrics.medianAbsOnsetErrorMs, lessThan(20));
    });

    test('3 % tempo drift: DTW beats the fixed offset', () {
      final take = synthesizeTrack(
        end * 1.03,
        (t) => midiOfNotes(notes, t / 1.03),
      );
      final dtw = Scorer.score(
        ScoringInput(
          referenceNotes: ReferenceNotes(notes: notes),
          takeF0: take,
        ),
      );
      final fixed = Scorer.score(
        ScoringInput(
          referenceNotes: ReferenceNotes(notes: notes),
          takeF0: take,
          options: const ScoringOptions(
            alignmentMode: AlignmentMode.fixedOffset,
          ),
        ),
      );
      expect(dtw.frameMetrics.rawChromaAccuracy, greaterThan(0.95));
      expect(dtw.noteMetrics.onset.f1, greaterThan(0.9));
      expect(dtw.noteMetrics.medianAbsOnsetErrorMs, lessThan(25));
      expect(
        dtw.frameMetrics.rawChromaAccuracy,
        greaterThan(fixed.frameMetrics.rawChromaAccuracy + 0.1),
      );
      expect(dtw.noteMetrics.onset.f1, greaterThan(fixed.noteMetrics.onset.f1));
    });

    test('phrase-level late entry: DTW beats the fixed offset', () {
      // 300 ms late for the first half, 600 ms late afterwards.
      final take = synthesizeTrack(
        end + 0.6,
        (t) => midiOfNotes(notes, t - (t > 13.0 ? 0.6 : 0.3)),
      );
      final dtw = Scorer.score(
        ScoringInput(
          referenceNotes: ReferenceNotes(notes: notes),
          takeF0: take,
        ),
      );
      final fixed = Scorer.score(
        ScoringInput(
          referenceNotes: ReferenceNotes(notes: notes),
          takeF0: take,
          options: const ScoringOptions(
            alignmentMode: AlignmentMode.fixedOffset,
          ),
        ),
      );
      expect(dtw.frameMetrics.rawChromaAccuracy, greaterThan(0.93));
      expect(dtw.noteMetrics.onset.f1, greaterThan(0.85));
      expect(
        fixed.frameMetrics.rawChromaAccuracy,
        lessThan(dtw.frameMetrics.rawChromaAccuracy - 0.1),
      );
      expect(dtw.alignment.takeTimeToRefTime(5.3), closeTo(5.0, 0.02));
      expect(dtw.alignment.takeTimeToRefTime(20.6), closeTo(20.0, 0.03));
    });

    test('DTW path of identical tracks is the diagonal', () {
      final a = [double.nan, 60.0, 60.0, 62.0, 62.0, double.nan, 64.0];
      final r = alignDtw(a, a, hop: 0.016, bandFrames: 3);
      expect(r.pathTake, r.pathRef);
      expect(r.pathTake.length, a.length);
      expect(r.cost, 0);
    });
  });

  group('(d) random take', () {
    final notes = makeMelody(seed: 5, duration: 30);
    final end = songEnd(notes);

    test('random frame pitches score very low', () {
      final rng = math.Random(42);
      final take = synthesizeTrack(
        end,
        (t) => rng.nextDouble() < 0.7
            ? hzToMidi(100 + rng.nextDouble() * 400)
            : null,
      );
      final r = Scorer.score(
        ScoringInput(
          referenceNotes: ReferenceNotes(notes: notes),
          takeF0: take,
        ),
      );
      expect(r.frameMetrics.rawChromaAccuracy, lessThan(0.15));
      expect(r.subScores.pitch.value, 0);
      expect(r.total, lessThan(15));
      expect(r.rank, 'D');
      // Without the gap penalty the free warp would cherry-pick frames.
      final free = Scorer.score(
        ScoringInput(
          referenceNotes: ReferenceNotes(notes: notes),
          takeF0: take,
          options: const ScoringOptions(stepPenalty: 0),
        ),
      );
      expect(
        free.frameMetrics.rawChromaAccuracy,
        greaterThan(r.frameMetrics.rawChromaAccuracy + 0.2),
      );
    });

    test('a random melody also scores low', () {
      final other = makeMelody(seed: 99, duration: 30);
      final take = synthesizeTrack(end, (t) => midiOfNotes(other, t));
      final r = Scorer.score(
        ScoringInput(
          referenceNotes: ReferenceNotes(notes: notes),
          takeF0: take,
        ),
      );
      expect(r.total, lessThan(50));
    });

    test('silent take does not crash and scores 0', () {
      final take = synthesizeTrack(end, (_) => null);
      final r = Scorer.score(
        ScoringInput(
          referenceNotes: ReferenceNotes(notes: notes),
          takeF0: take,
        ),
      );
      expect(r.total, 0);
      expect(r.rank, 'D');
      expect(r.frameMetrics.voicingRecall, 0);
    });
  });

  group('(e) vibrato', () {
    final notes = makeLongNoteMelody(count: 8, noteSeconds: 1.0);
    final end = songEnd(notes);
    const rate = 5.5;
    const extentCents = 60.0; // peak-to-peak
    final take = synthesizeTrack(end, (t) {
      final m = midiOfNotes(notes, t);
      if (m == null) return null;
      return m + (extentCents / 200) * math.sin(2 * math.pi * rate * t);
    });
    final flatRef = synthesizeTrack(end, (t) => midiOfNotes(notes, t));

    test('single window analysis', () {
      const hop = 0.016;
      final x = List<double>.generate(
        32,
        (i) => 0.3 * math.sin(2 * math.pi * rate * i * hop) + 0.01 * i,
      );
      final w = analyzeVibratoWindow(x, hop)!;
      expect(w.present, isTrue);
      expect(w.rateHz, closeTo(rate, 0.5));
      expect(w.extentCents, closeTo(60, 12));
      final flat = analyzeVibratoWindow(List<double>.filled(32, 60.0), hop);
      expect(flat, isNull);
    });

    test('detected on every long note with the right rate and extent', () {
      final r = Scorer.score(
        ScoringInput(
          referenceNotes: ReferenceNotes(notes: notes),
          referenceF0: flatRef,
          takeF0: take,
        ),
      );
      expect(r.technique.longReferenceNotes, 8);
      expect(r.technique.longTakeSegments, 8);
      expect(r.technique.vibratoFraction, greaterThanOrEqualTo(0.9));
      expect(r.technique.vibratoRateHz, closeTo(rate, 0.5));
      expect(r.technique.vibratoExtentCents, closeTo(extentCents, 15));
      expect(r.technique.referenceVibratoFraction, 0);
      expect(r.subScores.vibrato.value, isNull);
      // Vibrato band removed before measuring stability.
      expect(r.technique.pitchStabilityCents, lessThan(12));
      expect(r.frameMetrics.rawChromaAccuracy, greaterThan(0.95));
      expect(r.technique.longToneScore, greaterThan(0.95));
    });

    test('no vibrato in the take scores 0 against a vibrato reference', () {
      final r = Scorer.score(
        ScoringInput(
          referenceNotes: ReferenceNotes(notes: notes),
          referenceF0: take,
          takeF0: flatRef,
        ),
      );
      expect(r.technique.referenceVibratoFraction, greaterThanOrEqualTo(0.9));
      expect(r.technique.referenceVibratoAmount, greaterThan(0.8));
      expect(r.technique.vibratoFraction, 0);
      expect(r.subScores.vibrato.value, 0);
    });

    test('vibrato score mapping', () {
      expect(Scorer.vibratoScore(0.2, null, 0.4), closeTo(0.5, 1e-9));
      expect(Scorer.vibratoScore(0.9, null, 0.4), 1.0);
      expect(Scorer.vibratoScore(0.0, 0.0, 0.4), isNull);
      expect(Scorer.vibratoScore(0.0, 0.2, 0.4), isNull);
      expect(Scorer.vibratoScore(0.2, 0.3, 0.4), closeTo(2 / 3, 1e-9));
      expect(Scorer.vibratoScore(0.2, 1.0, 0.4), closeTo(0.5, 1e-9));
    });
  });

  group('(f) JSON round trips', () {
    final notes = makeMelody(seed: 2, duration: 12);
    final end = songEnd(notes);
    final ref = synthesizeTrack(end, (t) => midiOfNotes(notes, t));
    final take = synthesizeTrack(end + 0.1, (t) {
      final m = midiOfNotes(notes, t - 0.1);
      return m == null ? null : m + 2;
    });
    final input = ScoringInput(
      referenceNotes: ReferenceNotes(
        notes: notes,
        timestep: 0.01,
        language: 'zh',
        model: 'game-large',
      ),
      referenceF0: ref,
      takeF0: take,
      referenceEnergy: synthesizeEnergy(notes, end),
      takeEnergy: synthesizeEnergy(notes, end + 0.1, delay: 0.1),
      weights: const ScoringWeights(pitch: 50, rhythm: 10),
      options: const ScoringOptions(bandSeconds: 0.5, confidenceThreshold: 0.3),
    );

    test('ScoringInput survives toJson/fromJson', () {
      final json = jsonEncode(input.toJson());
      final back = ScoringInput.fromJson(
        jsonDecode(json) as Map<String, dynamic>,
      );
      expect(jsonEncode(back.toJson()), json);
      expect(back.referenceNotes.language, 'zh');
      expect(back.weights.pitch, 50);
      expect(back.options.bandSeconds, 0.5);
      expect(back.referenceF0!.f0.length, ref.f0.length);
    });

    test('engine-shaped JSON parses', () {
      final engineNotes = jsonDecode(
        '{"timestep":0.01,"language":"zh","model":"game-large",'
        '"notes":[{"onset":1.23,"offset":1.80,"pitch":62.4}]}',
      ) as Map<String, dynamic>;
      final n = ReferenceNotes.fromJson(engineNotes);
      expect(n.notes.single.pitch, 62.4);
      final f0 = F0Track.fromJson(
        jsonDecode(
          '{"hop":0.016,"sample_rate":16000,"times":[0,0.016],"f0":[0,220],"confidence":[0,0.9]}',
        ) as Map<String, dynamic>,
      );
      expect(f0.length, 2);
      expect(f0.sampleRate, 16000);
      final e = EnergyCurve.fromJson(
        jsonDecode('{"times":[0,1],"rms_db":[-20,-30]}')
            as Map<String, dynamic>,
      );
      expect(e.rmsDb, [-20, -30]);
    });

    test(
      'ScoreResult survives toJson/fromJson and scoring is deterministic',
      () {
        final r1 = Scorer.score(input);
        final r2 = Scorer.score(
          ScoringInput.fromJson(
            jsonDecode(jsonEncode(input.toJson())) as Map<String, dynamic>,
          ),
        );
        final j1 = jsonEncode(r1.toJson());
        expect(jsonEncode(r2.toJson()), j1);
        final back = ScoreResult.fromJson(
          jsonDecode(j1) as Map<String, dynamic>,
        );
        expect(jsonEncode(back.toJson()), j1);
        expect(back.total, r1.total);
        expect(back.rank, r1.rank);
        expect(back.shift, 10);
        expect(back.alignment.pathTake.length, r1.alignment.pathLength);
        expect(
          back.alignment.takeTimeToRefTime(3.1),
          closeTo(r1.alignment.takeTimeToRefTime(3.1), 1e-9),
        );
        expect(back.noteMetrics.perNote.length, notes.length);
        expect(back.subScores.expression.value, r1.subScores.expression.value);
      },
    );
  });

  group('score mapping', () {
    test('rank thresholds are monotonic', () {
      expect(rankForTotal(100), 'SSS');
      expect(rankForTotal(97), 'SSS');
      expect(rankForTotal(96.9), 'SS');
      expect(rankForTotal(92), 'SS');
      expect(rankForTotal(85), 'S');
      expect(rankForTotal(75), 'A');
      expect(rankForTotal(60), 'B');
      expect(rankForTotal(40), 'C');
      expect(rankForTotal(39.9), 'D');
      var prev = 'D';
      for (var t = 0.0; t <= 100; t += 0.5) {
        final r = rankForTotal(t);
        expect(
          rankLetters.indexOf(r),
          lessThanOrEqualTo(rankLetters.indexOf(prev)),
        );
        prev = r;
      }
    });

    test('sub-score curves', () {
      expect(Scorer.pitchScore(1.0), 1.0);
      expect(Scorer.pitchScore(0.95), 1.0);
      expect(Scorer.pitchScore(0.575), closeTo(0.5, 1e-9));
      expect(Scorer.pitchScore(0.1), 0.0);
      expect(Scorer.stabilityScore(0), 1.0);
      expect(Scorer.stabilityScore(25), closeTo(0.5, 1e-9));
      expect(Scorer.stabilityScore(null), 0.0);
      expect(Scorer.expressionScore(0.8), 1.0);
      expect(Scorer.expressionScore(-0.5), 0.0);
    });

    test('weights renormalise over available components', () {
      const s = SubScores(
        pitch: SubScore(value: 1, weight: 40),
        rhythm: SubScore(value: 0.5, weight: 20),
        stability: SubScore(value: null, weight: 10),
        vibrato: SubScore(value: null, weight: 10),
        expression: SubScore(value: null, weight: 10),
        longTone: SubScore(value: null, weight: 10),
      );
      expect(s.total, closeTo(100 * 50 / 60, 1e-9));
    });
  });

  group('live comparator', () {
    final notes = ReferenceNotes(
      notes: const [
        ReferenceNote(onset: 1.0, offset: 1.5, pitch: 60),
        ReferenceNote(onset: 1.5, offset: 2.0, pitch: 64),
        ReferenceNote(onset: 3.0, offset: 4.0, pitch: 67),
      ],
    );

    test('categories and chroma-wise cents', () {
      final live = LiveComparator(notes);
      expect(live.compare(0.5, 261.6).category, LiveCategory.noNote);
      expect(live.compare(1.2, 0).category, LiveCategory.unvoiced);
      final c = live.compare(1.2, midiToHz(60.2));
      expect(c.category, LiveCategory.good);
      expect(c.noteIndex, 0);
      expect(c.centsDeviation, closeTo(20, 1e-6));
      // One octave down is still "good".
      expect(live.compare(1.6, midiToHz(52.0)).category, LiveCategory.good);
      expect(live.compare(1.6, midiToHz(64.8)).category, LiveCategory.near);
      expect(live.compare(3.5, midiToHz(69.0)).category, LiveCategory.off);
      expect(live.compare(2.5, 300).category, LiveCategory.noNote);
      // Seeking backwards works too.
      expect(live.compare(1.1, midiToHz(60)).noteIndex, 0);
    });

    test('shift and low confidence', () {
      final live = LiveComparator(notes, shift: 9);
      // Singing 51 + 9 = 60.
      final c = live.compare(1.2, midiToHz(51.0));
      expect(c.category, LiveCategory.good);
      expect(c.centsDeviation, closeTo(0, 1e-6));
      expect(
        live.compareFrame([1.2, midiToHz(60), 0.1, -20, 0]).category,
        LiveCategory.unvoiced,
      );
      expect(
        live.compareFrame([1.2, midiToHz(51), 0.9, -20, 0]).category,
        LiveCategory.good,
      );
    });
  });

  group('(e) scoops in the original', () {
    // The original singer slides into every note from 200 cents below over
    // the first 120 ms (well beyond the 50 cent tolerance) and sags 200 cents
    // over the last 80 ms. GAME's notes carry the plain pitch.
    final notes = makeMelody(seed: 11, duration: 40);
    final end = songEnd(notes);
    double? ornamented(double t) {
      for (final n in notes) {
        if (t >= n.onset && t < n.offset) {
          final a = t - n.onset;
          final b = n.offset - t;
          if (a < 0.12) return n.pitch - 2.0 * (1 - a / 0.12);
          if (b < 0.08) return n.pitch - 2.0 * (1 - b / 0.08);
          return n.pitch;
        }
      }
      return null;
    }

    final curve = synthesizeTrack(end, ornamented);
    final plain = synthesizeTrack(end, (t) => midiOfNotes(notes, t));

    test('holding the plain note through the scoops is a perfect take', () {
      final r = Scorer.score(
        ScoringInput(
          referenceNotes: ReferenceNotes(notes: notes),
          referenceF0: curve,
          takeF0: plain,
          referenceEnergy: synthesizeEnergy(notes, end),
          takeEnergy: synthesizeEnergy(notes, end),
        ),
      );
      expect(r.shift, 0);
      expect(r.frameMetrics.rawChromaAccuracy, closeTo(1, 1e-6));
      expect(r.subScores.pitch.value, closeTo(1, 1e-6));
      expect(r.noteMetrics.onsetPitch.f1, closeTo(1, 1e-6));
      expect(r.total, greaterThanOrEqualTo(97));
    });

    test('following the scoops is also a perfect take', () {
      final r = Scorer.score(
        ScoringInput(
          referenceNotes: ReferenceNotes(notes: notes),
          referenceF0: curve,
          takeF0: curve,
        ),
      );
      expect(r.frameMetrics.rawChromaAccuracy, closeTo(1, 1e-6));
      expect(r.subScores.pitch.value, closeTo(1, 1e-6));
    });

    test('alternating +75 / -75 cents off both targets still fails', () {
      // A constant offset would be absorbed by the chroma shift; alternating
      // the sign per note cannot be.
      final off = synthesizeTrack(end, (t) {
        for (var i = 0; i < notes.length; i++) {
          final n = notes[i];
          if (t >= n.onset && t < n.offset) return n.pitch + (i.isEven ? 0.75 : -0.75);
        }
        return null;
      });
      final r = Scorer.score(
        ScoringInput(
          referenceNotes: ReferenceNotes(notes: notes),
          referenceF0: curve,
          takeF0: off,
        ),
      );
      expect(r.frameMetrics.rawChromaAccuracy, lessThan(0.6));
      expect(r.subScores.pitch.value, lessThan(0.6));
    });
  });
}
