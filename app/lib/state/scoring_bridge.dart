// Bridge between the UI and the scoring module (lib/scoring/scoring.dart).
//
// The UI only depends on [ScoreData], a normalised view of score.json, which
// is exactly `ScoreResult.toJson()`:
//   {total, rank, sub_scores:{pitch:{value,weight,points}, ..., long_tone:{...}},
//    shift, octave_exact_shift, note_metrics:{per_note:[{index, matched,
//    cents_deviation, onset_error_ms, ...}]}, ...}
// Scoring itself runs in an isolate (pure Dart, JSON in / JSON out).
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:karaoke_battle/scoring/scoring.dart';

import 'energy_curve.dart';
import 'note_edits.dart';

class ScoreNoteRow {
  ScoreNoteRow({required this.index, required this.cents, required this.matched, this.onsetErrorMs});
  final int index;
  final double? cents;
  final bool matched;
  final double? onsetErrorMs;
}

class ScoreData {
  ScoreData({
    required this.total,
    required this.rank,
    required this.subScores,
    required this.notes,
    required this.shift,
    required this.octaveExactShift,
    required this.placeholder,
    required this.raw,
  });

  final double total;
  final String rank;

  /// Keys: pitch, rhythm, stability, vibrato, expression, long_tone. Values in
  /// 0..100 or null when the component was not evaluated.
  final Map<String, double?> subScores;
  final List<ScoreNoteRow> notes;
  final int shift;
  final int octaveExactShift;
  final bool placeholder;
  final Map<String, dynamic> raw;

  static const subScoreKeys = ['pitch', 'rhythm', 'stability', 'vibrato', 'expression', 'long_tone'];

  static ScoreData fromJson(Map<String, dynamic> j) {
    final subs = <String, double?>{};
    final sj = j['sub_scores'];
    for (final k in subScoreKeys) {
      Object? v = sj is Map ? sj[k] : null;
      if (v is Map) v = v['value'] is num ? (v['value'] as num).toDouble() * 100.0 : null;
      subs[k] = v is num ? v.toDouble() : null;
    }
    final notes = <ScoreNoteRow>[];
    final nm = j['note_metrics'];
    final perNote = nm is Map ? nm['per_note'] : j['notes'];
    if (perNote is List) {
      for (final e in perNote) {
        if (e is! Map) continue;
        final c = e['cents_deviation'] ?? e['cents'];
        notes.add(ScoreNoteRow(
          index: (e['index'] as num?)?.toInt() ?? notes.length,
          cents: c is num ? c.toDouble() : null,
          matched: e['matched'] == true,
          onsetErrorMs: (e['onset_error_ms'] as num?)?.toDouble(),
        ));
      }
    }
    return ScoreData(
      total: (j['total'] as num?)?.toDouble() ?? 0,
      rank: j['rank'] as String? ?? '—',
      subScores: subs,
      notes: notes,
      shift: (j['shift'] as num?)?.toInt() ?? 0,
      octaveExactShift: (j['octave_exact_shift'] as num?)?.toInt() ?? 0,
      placeholder: j['placeholder'] == true,
      raw: j,
    );
  }

  static ScoreData fromResult(ScoreResult r) => fromJson(r.toJson());
}

class ScoringBridge {
  ScoringBridge._();

  static Future<ScoreData?> load(String scoreJsonPath) async {
    final f = File(scoreJsonPath);
    if (!await f.exists()) return null;
    try {
      return ScoreData.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Scores a take with [Scorer] and writes score.json. [takeTimeOffset] maps
  /// take-file time to track time (added to every take frame time) so the
  /// take lines up with the reference before alignment.
  static Future<ScoreData> scoreAndSave({
    required String notesJsonPath,
    required String refF0JsonPath,
    required String takeF0JsonPath,
    required String scoreJsonPath,
    required bool octaveInvariant,
    double takeTimeOffset = 0,
    String? takeWavPath,
    String? referenceWavPath,
    double? noiseGateDb,
  }) async {
    final notesText = await File(notesJsonPath).readAsString();
    final refText = await File(refF0JsonPath).exists() ? await File(refF0JsonPath).readAsString() : null;
    final takeText = await File(takeF0JsonPath).readAsString();
    final takeEnergy = takeWavPath == null ? null : await wavEnergyCurve(takeWavPath, timeOffset: takeTimeOffset);
    final refEnergy = referenceWavPath == null ? null : await wavEnergyCurve(referenceWavPath);
    final takeEnergyJson = takeEnergy?.toJson();
    final refEnergyJson = refEnergy?.toJson();
    final result = await Isolate.run(() {
      final notesMap = jsonDecode(notesText) as Map<String, dynamic>;
      final notes = ReferenceNotes.fromJson(notesMap);
      // Spans of notes the user deleted (ghosts) are excluded from the
      // reference curve too, so they cannot count against the singer.
      final spans = excludedSpansFromJson(notesMap);
      final refRaw = refText == null ? null : F0Track.fromJson(jsonDecode(refText) as Map<String, dynamic>);
      final refF0 = refRaw == null || spans.isEmpty
          ? refRaw
          : F0Track(
              times: refRaw.times,
              f0: [for (var i = 0; i < refRaw.f0.length; i++) i < refRaw.times.length && inSpans(spans, refRaw.times[i]) ? 0.0 : refRaw.f0[i]],
              confidence: refRaw.confidence,
              hop: refRaw.hop,
              sampleRate: refRaw.sampleRate,
            );
      final takeRaw = F0Track.fromJson(jsonDecode(takeText) as Map<String, dynamic>);
      final shifted = takeTimeOffset == 0
          ? takeRaw
          : F0Track(
              times: takeRaw.times.map((t) => t + takeTimeOffset).toList(growable: false),
              f0: takeRaw.f0,
              confidence: takeRaw.confidence,
              hop: takeRaw.hop,
              sampleRate: takeRaw.sampleRate,
            );
      // The energy curve is already in track time (same offset), so the gate
      // compares each take frame with the loudness recorded at that moment.
      final takeF0 = (noiseGateDb != null && takeEnergyJson != null)
          ? applyNoiseGate(shifted, EnergyCurve.fromJson(takeEnergyJson), noiseGateDb)
          : shifted;
      final input = ScoringInput(
        referenceNotes: notes,
        referenceF0: refF0,
        takeF0: takeF0,
        takeEnergy: takeEnergyJson == null ? null : EnergyCurve.fromJson(takeEnergyJson),
        referenceEnergy: refEnergyJson == null ? null : EnergyCurve.fromJson(refEnergyJson),
        options: const ScoringOptions(),
      );
      final r = Scorer.score(input);
      final j = r.toJson();
      j['octave_invariant'] = octaveInvariant;
      if (noiseGateDb != null) j['noise_gate_db'] = noiseGateDb;
      return j;
    });
    await File(scoreJsonPath).writeAsString(jsonEncode(result));
    return ScoreData.fromJson(result);
  }
}
