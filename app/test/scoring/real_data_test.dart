// Real engine data (GAME-large notes + SwiftF0 F0 of a CC-BY song clip).
// Skipped when the fixtures are missing.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/scoring/scoring.dart';

void main() {
  final dir = Directory('test/scoring/fixtures');
  final names = [
    'real_notes.json',
    'real_ref_f0.json',
    'real_take_transposed.json',
    'real_take_random.json',
  ];
  final present = names.every((n) => File('${dir.path}/$n').existsSync());
  final skip = present ? false : 'fixtures missing in ${dir.absolute.path}';

  Map<String, dynamic> read(String n) =>
      jsonDecode(File('${dir.path}/$n').readAsStringSync())
          as Map<String, dynamic>;

  group('real engine data', () {
    late ReferenceNotes notes;
    late F0Track ref;
    setUpAll(() {
      if (!present) return;
      notes = ReferenceNotes.fromJson(read('real_notes.json'));
      ref = F0Track.fromJson(read('real_ref_f0.json'));
    });

    test('the original vocal scores >= 97 (SSS/SS)', () {
      final r = Scorer.score(
        ScoringInput(referenceNotes: notes, referenceF0: ref, takeF0: ref),
      );
      expect(r.shift, 0);
      expect(r.frameMetrics.rawChromaAccuracy, closeTo(1, 1e-9));
      expect(r.noteMetrics.onset.f1, greaterThan(0.97));
      expect(r.noteMetrics.medianAbsOnsetErrorMs, 0);
      expect(r.subScores.rhythm.value, greaterThan(0.95));
      expect(r.subScores.stability.value, 1);
      expect(r.subScores.vibrato.value, isNull); // original has no vibrato
      expect(r.subScores.longTone.value, closeTo(1, 1e-9));
      expect(r.total, greaterThanOrEqualTo(97));
      expect(['SSS', 'SS'], contains(r.rank));
      final flat = r.toJson()['sub_scores_flat'] as Map<String, dynamic>;
      expect(flat['pitch'], closeTo(100, 1e-9));
      expect(flat['expression'], isNull);
    }, skip: skip);

    test('transposed and delayed take scores >= 95', () {
      final take = F0Track.fromJson(read('real_take_transposed.json'));
      final r = Scorer.score(
        ScoringInput(referenceNotes: notes, referenceF0: ref, takeF0: take),
      );
      expect(r.shift, 9);
      expect(r.frameMetrics.rawChromaAccuracy, greaterThan(0.98));
      expect(r.total, greaterThanOrEqualTo(95));
    }, skip: skip);

    test('random take scores < 20', () {
      final take = F0Track.fromJson(read('real_take_random.json'));
      final r = Scorer.score(
        ScoringInput(referenceNotes: notes, referenceF0: ref, takeF0: take),
      );
      expect(r.subScores.pitch.value, 0);
      expect(r.total, lessThan(20));
      expect(r.rank, 'D');
    }, skip: skip);

    test('take-F0 segmentation mode still runs on real data', () {
      final r = Scorer.score(
        ScoringInput(
          referenceNotes: notes,
          referenceF0: ref,
          takeF0: ref,
          options: const ScoringOptions(
            noteSegmentation: NoteSegmentation.fromTakeF0,
          ),
        ),
      );
      expect(r.noteMetrics.segmentation, NoteSegmentation.fromTakeF0);
      expect(r.frameMetrics.rawChromaAccuracy, closeTo(1, 1e-9));
      expect(r.total, greaterThan(80));
    }, skip: skip);
  });
}
