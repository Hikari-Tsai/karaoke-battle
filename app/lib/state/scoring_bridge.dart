// Bridge between the UI and the scoring module (lib/scoring/scoring.dart).
//
// The UI only depends on [ScoreData], a normalised view of score.json, which
// is exactly `ScoreResult.toJson()`:
//   {total, rank, sub_scores:{pitch:{value,weight,points}, ..., long_tone:{...}},
//    shift, octave_exact_shift, note_metrics:{per_note:[{index, matched,
//    cents_deviation, onset_error_ms, ...}]}, ...}
// Scoring itself runs in an isolate (pure Dart, JSON in / JSON out).
import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';
import 'dart:isolate';

import 'package:karaoke_battle/scoring/scoring.dart';
import 'package:path/path.dart' as p;

import 'energy_curve.dart';
import 'note_edits.dart';
import 'tuning_wand.dart';

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
    // Older files hold raw totals; readScoreTotal converts them.
    final t = readScoreTotal(j);
    return ScoreData(
      total: t.total,
      rank: t.rank,
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

  /// Beside a score made with items (the Tuning Wand, the Resonance Field):
  /// the same take scored as sung, without them (score.raw.json).
  static String rawScorePath(String scoreJsonPath) => p.join(p.dirname(scoreJsonPath), 'score.raw.json');

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
  /// The take scored without any wand (its field kept), and for each of
  /// [candidates] (a note's onset and offset) how much a wand on that note
  /// alone adds to it. Scored like [scoreAndSave], nothing written; the
  /// makings of [WandWeights].
  static Future<(double, List<double>)> wandGains({
    required String notesJsonPath,
    required String refF0JsonPath,
    required String takeF0JsonPath,
    required String scoreJsonPath,
    required List<(double, double)> candidates,
    double takeTimeOffset = 0,
    String? takeWavPath,
    String? referenceWavPath,
    double? noiseGateDb,
    double? tempoBpm,
    bool calibratedTiming = false,
  }) async {
    final notesText = await File(notesJsonPath).readAsString();
    final refText = await File(refF0JsonPath).exists() ? await File(refF0JsonPath).readAsString() : null;
    final takeText = await File(takeF0JsonPath).readAsString();
    final field = await TakeField.isOn(p.dirname(scoreJsonPath));
    final takeEnergyJson = takeWavPath == null ? null : (await wavEnergyCurve(takeWavPath, timeOffset: takeTimeOffset))?.toJson();
    final refEnergyJson = referenceWavPath == null ? null : (await wavEnergyCurve(referenceWavPath))?.toJson();
    return Isolate.run(() {
      final (:notes, :refF0, :takeF0) = _parseInputs(notesText, refText, takeText, takeTimeOffset, noiseGateDb, takeEnergyJson);
      final takeEnergy = takeEnergyJson == null ? null : EnergyCurve.fromJson(takeEnergyJson);
      final refEnergy = refEnergyJson == null ? null : EnergyCurve.fromJson(refEnergyJson);
      double total(List<(double, double)> perfect) => Scorer.score(ScoringInput(
            referenceNotes: notes,
            referenceF0: refF0,
            takeF0: takeF0,
            takeEnergy: takeEnergy,
            referenceEnergy: refEnergy,
            options: ScoringOptions(tempoBpm: tempoBpm, calibratedTiming: calibratedTiming, perfectSpans: perfect, lenience: field ? TakeField.lenience : 1),
          )).total;
      final base = total(const []);
      return (base, [for (final c in candidates) math.max(0.0, total([c]) - base)]);
    });
  }

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
    double? tempoBpm,
    bool calibratedTiming = false,
    List<(double, double)> previewSpans = const [],
    WandWeights? weights,
  }) async {
    // [previewSpans]: a dry run, as if the Tuning Wand were also used on
    // these notes; nothing is written. [weights]: with wands, the total is
    // the take without them plus the tuned notes' shares (see WandWeights).
    final preview = previewSpans.isNotEmpty;
    final notesText = await File(notesJsonPath).readAsString();
    final refText = await File(refF0JsonPath).exists() ? await File(refF0JsonPath).readAsString() : null;
    final takeText = await File(takeF0JsonPath).readAsString();
    // Notes fixed with the Tuning Wand, kept next to the score.
    final wand = await TakeWand.load(p.dirname(scoreJsonPath));
    final perfectSpans = [...wand.spans, ...previewSpans];
    // A take sung under the Resonance Field is judged more leniently.
    final field = await TakeField.isOn(p.dirname(scoreJsonPath));
    final takeEnergy = takeWavPath == null ? null : await wavEnergyCurve(takeWavPath, timeOffset: takeTimeOffset);
    final refEnergy = referenceWavPath == null ? null : await wavEnergyCurve(referenceWavPath);
    final takeEnergyJson = takeEnergy?.toJson();
    final refEnergyJson = refEnergy?.toJson();
    final scored = await Isolate.run(() {
      final (:notes, :refF0, :takeF0) = _parseInputs(notesText, refText, takeText, takeTimeOffset, noiseGateDb, takeEnergyJson);
      Map<String, dynamic> run({required bool items}) {
        final input = ScoringInput(
          referenceNotes: notes,
          referenceF0: refF0,
          takeF0: takeF0,
          takeEnergy: takeEnergyJson == null ? null : EnergyCurve.fromJson(takeEnergyJson),
          referenceEnergy: refEnergyJson == null ? null : EnergyCurve.fromJson(refEnergyJson),
          options: items
              ? ScoringOptions(tempoBpm: tempoBpm, calibratedTiming: calibratedTiming, perfectSpans: perfectSpans, lenience: field ? TakeField.lenience : 1)
              : ScoringOptions(tempoBpm: tempoBpm, calibratedTiming: calibratedTiming),
        );
        final j = Scorer.score(input).toJson();
        // The notes made perfect read as perfect note by note too.
        final perfect = items ? Scorer.perfectNoteIndices(notes.notes, perfectSpans) : const <int>{};
        if (perfect.isNotEmpty) {
          for (final e in ((j['note_metrics'] as Map?)?['per_note'] as List? ?? const [])) {
            if (e is Map<String, dynamic> && perfect.contains(e['index'])) {
              e.addAll(<String, dynamic>{
                'matched': true,
                'matched_onset': true,
                'matched_offset': true,
                'cents_deviation': 0.0,
                'onset_error_ms': 0.0,
                'offset_error_ms': 0.0,
                'voiced_fraction': 1.0,
                'pitch_coverage': 1.0,
                'evaluable': true,
              });
            }
          }
        }
        j['octave_invariant'] = octaveInvariant;
        if (noiseGateDb != null) j['noise_gate_db'] = noiseGateDb;
        return j;
      }

      final withItems = !preview && (perfectSpans.isNotEmpty || field);
      // The take as sung, without the items, for the AI tips.
      return (run(items: true), withItems ? run(items: false) : null);
    });
    final (result, raw) = scored;
    if (weights != null && perfectSpans.isNotEmpty) {
      final total = weights.totalWith([for (final s in perfectSpans) s.$1]);
      result['total'] = total;
      result['raw_total'] = total;
      result['rank'] = rankForTotal(total);
      result['wand_normalized'] = true;
    }
    if (preview) return ScoreData.fromJson(result);
    if (wand.uses.isNotEmpty) result['wand'] = [for (final u in wand.uses) u.toJson()];
    if (field) result['field'] = {'lenience': TakeField.lenience};
    await File(scoreJsonPath).writeAsString(jsonEncode(result));
    final rawFile = File(rawScorePath(scoreJsonPath));
    if (raw != null) {
      await rawFile.writeAsString(jsonEncode(raw));
    } else if (await rawFile.exists()) {
      await rawFile.delete();
    }
    return ScoreData.fromJson(result);
  }
}

/// The notes, the reference curve (without the notes the user deleted) and
/// the take's curve in track time behind the noise gate, parsed for scoring.
({ReferenceNotes notes, F0Track? refF0, F0Track takeF0}) _parseInputs(
  String notesText,
  String? refText,
  String takeText,
  double takeTimeOffset,
  double? noiseGateDb,
  Map<String, dynamic>? takeEnergyJson,
) {
  final notesMap = jsonDecode(notesText) as Map<String, dynamic>;
  final notes = ReferenceNotes.fromJson(notesMap);
  // Spans of notes the user deleted (ghosts) are excluded from the
  // reference curve too, so they cannot count against the singer.
  final spans = excludedSpansFromJson(notesMap);
  // A duet part: the other part's lines are left out of both curves.
  final duet = <(double, double)>[
    for (final s in (notesMap['duet_spans'] as List? ?? const []))
      if (s is List && s.length == 2 && s[0] is num && s[1] is num) ((s[0] as num).toDouble(), (s[1] as num).toDouble()),
  ];
  bool inDuet(double t) => duet.any((s) => t >= s.$1 && t <= s.$2);
  final refRaw = refText == null ? null : F0Track.fromJson(jsonDecode(refText) as Map<String, dynamic>);
  final refF0 = refRaw == null || (spans.isEmpty && duet.isEmpty)
      ? refRaw
      : F0Track(
          times: refRaw.times,
          f0: [for (var i = 0; i < refRaw.f0.length; i++) i < refRaw.times.length && (inSpans(spans, refRaw.times[i]) || inDuet(refRaw.times[i])) ? 0.0 : refRaw.f0[i]],
          confidence: refRaw.confidence,
          hop: refRaw.hop,
          sampleRate: refRaw.sampleRate,
        );
  final takeRaw = F0Track.fromJson(jsonDecode(takeText) as Map<String, dynamic>);
  final moved = takeTimeOffset == 0
      ? takeRaw
      : F0Track(
          times: takeRaw.times.map((t) => t + takeTimeOffset).toList(growable: false),
          f0: takeRaw.f0,
          confidence: takeRaw.confidence,
          hop: takeRaw.hop,
          sampleRate: takeRaw.sampleRate,
        );
  final shifted = duet.isEmpty
      ? moved
      : F0Track(
          times: moved.times,
          f0: [for (var i = 0; i < moved.f0.length; i++) i < moved.times.length && inDuet(moved.times[i]) ? 0.0 : moved.f0[i]],
          confidence: moved.confidence,
          hop: moved.hop,
          sampleRate: moved.sampleRate,
        );
  // The energy curve is already in track time (same offset), so the gate
  // compares each take frame with the loudness recorded at that moment.
  final takeF0 = (noiseGateDb != null && takeEnergyJson != null) ? applyNoiseGate(shifted, EnergyCurve.fromJson(takeEnergyJson), noiseGateDb) : shifted;
  return (notes: notes, refF0: refF0, takeF0: takeF0);
}
