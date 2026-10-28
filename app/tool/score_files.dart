// Developer tool: score a take from files produced by the engine.
//
//   dart run tool/score_files.dart <notes.json> <take_f0.json> [ref_f0.json]
//
// Prints the ScoreResult JSON (total, rank, sub-scores, shift, frame metrics).
import 'dart:convert';
import 'dart:io';

import 'package:karaoke_battle/scoring/scoring.dart';

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('usage: dart run tool/score_files.dart <notes.json> <take_f0.json> [ref_f0.json]');
    exit(2);
  }
  Map<String, dynamic> read(String p) => jsonDecode(File(p).readAsStringSync()) as Map<String, dynamic>;
  final input = ScoringInput(
    referenceNotes: ReferenceNotes.fromJson(read(args[0])),
    takeF0: F0Track.fromJson(read(args[1])),
    referenceF0: args.length > 2 ? F0Track.fromJson(read(args[2])) : null,
  );
  final sw = Stopwatch()..start();
  final r = Scorer.score(input);
  sw.stop();
  final j = r.toJson();
  j.remove('alignment');
  j.remove('note_reports');
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(j));
  stderr.writeln('scored in ${sw.elapsedMilliseconds} ms');
}
