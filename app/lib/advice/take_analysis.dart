// A compact, factual summary of one take for singing advice: per lyric
// line, per register and long-note statistics plus a ranked list of
// findings, all computed here from score.json so that whoever writes the
// advice (a template or an LLM) only has to phrase them and never has to do
// arithmetic on raw pitch data.
//
// Pure Dart (no Flutter, no I/O) so it can be unit tested.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../scoring/models.dart' show ReferenceNote, readScoreTotal;
import '../state/lyrics.dart' show LyricLine;
import '../state/song_data.dart' show NoteList, noteName;
import '../state/voice_range.dart';

/// Another scored take of the same song.
class HistoryTake {
  const HistoryTake({required this.createdAt, required this.total, this.subScores = const {}});
  final DateTime createdAt;
  final double total;

  /// Percent (0..100) keyed as in `sub_scores_flat`; null = not evaluated.
  final Map<String, double?> subScores;
}

class TakeAnalysisInput {
  const TakeAnalysisInput({
    required this.notes,
    required this.score,
    required this.takeCreatedAt,
    this.songTitle = '',
    this.artist = '',
    this.lyrics = const [],
    this.pitchShift = 0,
    this.ownRange,
    this.history = const [],
  });

  /// The reference notes the take was scored against, in notes.json order
  /// (score.json indexes them).
  final List<ReferenceNote> notes;

  /// score.json.
  final Map<String, dynamic> score;
  final DateTime takeCreatedAt;
  final String songTitle;
  final String artist;

  /// Main lyrics track as shown (offset applied), in track time.
  final List<LyricLine> lyrics;

  /// Key change the take was sung with (semitones, from take.json).
  final double pitchShift;

  /// The singer's own range (MIDI), when they have measured it.
  final VoiceZone? ownRange;

  /// Other takes of the same song (any order; later ones are ignored).
  final List<HistoryTake> history;
}

/// Thresholds shared by the analysis and the text describing it.
class AnalysisRules {
  AnalysisRules._();

  /// A note is in tune within this many cents.
  static const inTuneCents = 50.0;

  /// A note counts as not sung when voiced for less than this share.
  static const unsungVoiced = 0.3;

  /// Notes at least this long are long notes for release timing.
  static const longNoteSeconds = 0.5;

  /// A long note ending this much earlier than the original is cut short.
  static const earlyReleaseMs = -100.0;

  /// Lines sung with less than this share of notes hit are weak.
  static const weakLineAccuracy = 0.6;
}

/// Statistics of one sung line (a lyric line, or a run of notes between
/// pauses when the song has no lyrics).
class LineStats {
  LineStats({required this.number, required this.start, required this.end, this.lyric, required this.noteIndexes});

  /// 1-based, in time order.
  final int number;
  final double start, end;
  final String? lyric;
  final List<int> noteIndexes;

  int evaluable = 0, matched = 0, sharp = 0, flat = 0, unsung = 0;
  double? medianCents;

  /// Median signed onset error (ms) of the notes that were sung.
  double? medianOnsetMs;
  final Map<String, int> rhythm = {'perfect': 0, 'great': 0, 'good': 0, 'miss': 0};

  /// Notes sung (not [unsung]) whose onset was GOOD or MISS.
  int lateOrEarly = 0;
  int longNotes = 0, earlyReleases = 0;

  /// Lowest and highest reference pitch in the key it was sung in.
  double lowMidi = 0, highMidi = 0;

  double? get accuracy => evaluable == 0 ? null : matched / evaluable;
  String get range => lowMidi == highMidi ? noteName(lowMidi) : '${noteName(lowMidi)}–${noteName(highMidi)}';

  Map<String, dynamic> toJson() => {
        'number': number,
        'start': _r(start, 1),
        'end': _r(end, 1),
        'lyric': ?lyric,
        'notes': noteIndexes.length,
        'evaluable': evaluable,
        'matched': matched,
        'sharp': sharp,
        'flat': flat,
        'unsung': unsung,
        'median_cents': ?_rn(medianCents, 0),
        'median_onset_ms': ?_rn(medianOnsetMs, 0),
        'rhythm': rhythm,
        'long_notes': longNotes,
        'early_releases': earlyReleases,
        'range': range,
      };
}

/// Accuracy of the highest or lowest quarter of the song's notes.
class RegisterStats {
  const RegisterStats({required this.label, required this.low, required this.high, required this.evaluable, required this.matched, this.medianCents, required this.unsung});
  final String label; // high | low
  final double low, high;
  final int evaluable, matched, unsung;
  final double? medianCents;
  double get accuracy => evaluable == 0 ? 0 : matched / evaluable;
  String get range => '${noteName(low)}–${noteName(high)}';

  Map<String, dynamic> toJson() => {
        'register': label,
        'range': range,
        'evaluable': evaluable,
        'matched': matched,
        'accuracy': _r(accuracy, 2),
        'median_cents': ?_rn(medianCents, 0),
        'unsung': unsung,
      };
}

/// One fact worth giving advice about, with the numbers behind it.
class Finding {
  Finding({required this.kind, required this.severity, this.lines = const [], this.data = const {}, this.positive = false});

  /// Assigned after ranking: F1, F2, …
  String id = '';
  final String kind;

  /// 0..1, higher first.
  final double severity;

  /// Line numbers ([LineStats.number]) the finding is about.
  final List<int> lines;
  final Map<String, Object?> data;

  /// A strength or an improvement rather than a problem.
  final bool positive;

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        if (positive) 'positive': true,
        if (lines.isNotEmpty) 'lines': lines,
        'data': data,
      };
}

class TakeAnalysis {
  TakeAnalysis({
    required this.input,
    required this.total,
    required this.rank,
    required this.subScores,
    required this.weights,
    required this.shift,
    required this.octaveExactShift,
    required this.rhythmWindowsMs,
    required this.rhythmCounts,
    required this.rhythmTendency,
    required this.rhythmTendencyMs,
    required this.lines,
    required this.registers,
    required this.findings,
    this.previous,
    this.best,
    this.historyCount = 0,
  });

  final TakeAnalysisInput input;
  final double total;
  final String rank;

  /// Percent keyed pitch, rhythm, stability, vibrato, expression, long_tone.
  final Map<String, double?> subScores;
  final Map<String, double> weights;
  final int shift, octaveExactShift;

  /// PERFECT / GREAT / GOOD half-widths in ms (tempo-scaled), when known.
  final ({double perfect, double great, double good})? rhythmWindowsMs;
  final Map<String, int> rhythmCounts;

  /// rushing | dragging | steady | none (none: not measurable).
  final String rhythmTendency;
  final double? rhythmTendencyMs;
  final List<LineStats> lines;
  final List<RegisterStats> registers;

  /// Ranked: problems by severity, then strengths and progress.
  final List<Finding> findings;

  /// The latest earlier take and the best earlier take, if any.
  final HistoryTake? previous, best;
  final int historyCount;

  bool get hasLyrics => input.lyrics.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'song': {'title': input.songTitle, if (input.artist.isNotEmpty) 'artist': input.artist},
        'total': _r(total, 1),
        'rank': rank,
        'sub_scores': {for (final e in subScores.entries) e.key: _rn(e.value, 0)},
        'weights': weights,
        'key': {'pitch_shift': input.pitchShift, 'shift': shift, 'octave_exact_shift': octaveExactShift},
        'rhythm': {
          'counts': rhythmCounts,
          'tendency': rhythmTendency,
          'tendency_ms': ?_rn(rhythmTendencyMs, 0),
        },
        'registers': [for (final r in registers) r.toJson()],
        'findings': [for (final f in findings) f.toJson()],
        'lines': [for (final l in lines) l.toJson()],
        if (previous != null) 'previous': _historyJson(previous!),
        if (best != null) 'best': _historyJson(best!),
      };

  static Map<String, dynamic> _historyJson(HistoryTake h) => {
        'created_at': h.createdAt.toIso8601String(),
        'total': _r(h.total, 1),
        'sub_scores': {for (final e in h.subScores.entries) e.key: _rn(e.value, 0)},
      };
}

/// Builds the analysis of one take.
TakeAnalysis analyzeTake(TakeAnalysisInput input) {
  final s = input.score;
  final notes = input.notes;
  final octaveExact = _int(s['octave_exact_shift']);
  final shift = _int(s['shift']);
  // Reference pitch in the key the take was sung in. The octave-exact shift
  // is not used: octave estimates are unreliable and scoring ignores octaves.
  double sung(int i) => notes[i].pitch + input.pitchShift;

  // --- per-note facts from score.json ------------------------------------
  final perNote = <int, Map>{};
  final nm = s['note_metrics'];
  if (nm is Map) {
    for (final e in (nm['per_note'] as List? ?? const [])) {
      if (e is Map && e['index'] is num) perNote[(e['index'] as num).toInt()] = e;
    }
  }
  final rhythmOnset = <int, String>{};
  final rj = s['rhythm'];
  ({double perfect, double great, double good})? windows;
  var rhythmCounts = <String, int>{'perfect': 0, 'great': 0, 'good': 0, 'miss': 0};
  var tendency = 'none';
  double? tendencyMs;
  if (rj is Map) {
    for (final n in (rj['notes'] as List? ?? const [])) {
      if (n is Map && n['index'] is num && n['onset'] is String) rhythmOnset[(n['index'] as num).toInt()] = n['onset'] as String;
    }
    final w = rj['windows'];
    if (w is Map && w['perfect_ms'] is num && w['great_ms'] is num && w['good_ms'] is num) {
      windows = (perfect: (w['perfect_ms'] as num).toDouble(), great: (w['great_ms'] as num).toDouble(), good: (w['good_ms'] as num).toDouble());
    }
    rhythmCounts = {for (final k in rhythmCounts.keys) k: rhythmOnset.values.where((v) => v == k).length};
    if (rj['clock_trusted'] == true && rj['tendency'] is String) {
      tendency = rj['tendency'] as String;
      tendencyMs = (rj['tendency_ms'] as num?)?.toDouble();
    }
  }
  final longDetail = <int, Map>{};
  final tech = s['technique'] is Map ? s['technique'] as Map : const {};
  for (final e in (tech['long_notes'] as List? ?? const [])) {
    if (e is Map && e['index'] is num) longDetail[(e['index'] as num).toInt()] = e;
  }

  bool evaluable(int i) => perNote[i]?['evaluable'] != false && perNote.containsKey(i);
  double? cents(int i) => (perNote[i]?['cents_deviation'] as num?)?.toDouble();
  bool unsung(int i) => evaluable(i) && ((perNote[i]?['voiced_fraction'] as num?)?.toDouble() ?? 0) < AnalysisRules.unsungVoiced;
  bool matched(int i) => perNote[i]?['matched'] == true;

  // --- lines ---------------------------------------------------------------
  final lines = _groupLines(notes, input.lyrics);
  for (final l in lines) {
    final c = <double>[], on = <double>[];
    l.lowMidi = double.infinity;
    l.highMidi = -double.infinity;
    for (final i in l.noteIndexes) {
      l.lowMidi = math.min(l.lowMidi, sung(i));
      l.highMidi = math.max(l.highMidi, sung(i));
      if (!evaluable(i)) continue;
      l.evaluable++;
      if (matched(i)) l.matched++;
      final ci = cents(i);
      if (ci != null) {
        c.add(ci);
        if (ci > AnalysisRules.inTuneCents) l.sharp++;
        if (ci < -AnalysisRules.inTuneCents) l.flat++;
      }
      final silent = unsung(i);
      if (silent) l.unsung++;
      final j = rhythmOnset[i];
      if (j != null) {
        l.rhythm[j] = (l.rhythm[j] ?? 0) + 1;
        if (!silent && (j == 'good' || j == 'miss')) l.lateOrEarly++;
      }
      final o = (perNote[i]?['onset_error_ms'] as num?)?.toDouble();
      if (o != null && !silent) on.add(o);
      if (notes[i].duration >= AnalysisRules.longNoteSeconds && !silent) {
        final off = (perNote[i]?['offset_error_ms'] as num?)?.toDouble();
        if (off != null) {
          l.longNotes++;
          if (off <= AnalysisRules.earlyReleaseMs) l.earlyReleases++;
        }
      }
    }
    l.medianCents = c.isEmpty ? null : _median(c);
    l.medianOnsetMs = on.isEmpty ? null : _median(on);
  }
  final lineOf = <int, LineStats>{for (final l in lines) for (final i in l.noteIndexes) i: l};

  // --- registers -------------------------------------------------------------
  final eval = [for (var i = 0; i < notes.length; i++) if (evaluable(i)) i];
  final overallMatched = eval.where(matched).length;
  final overallAcc = eval.isEmpty ? 0.0 : overallMatched / eval.length;
  final registers = <RegisterStats>[];
  if (eval.length >= 16) {
    final byPitch = [...eval]..sort((a, b) => notes[a].pitch.compareTo(notes[b].pitch));
    final q = byPitch.length ~/ 4;
    RegisterStats reg(String label, List<int> idx) {
      final c = [for (final i in idx) ?cents(i)];
      return RegisterStats(
        label: label,
        low: idx.map(sung).reduce(math.min),
        high: idx.map(sung).reduce(math.max),
        evaluable: idx.length,
        matched: idx.where(matched).length,
        medianCents: c.isEmpty ? null : _median(c),
        unsung: idx.where(unsung).length,
      );
    }

    registers.add(reg('high', byPitch.sublist(byPitch.length - q)));
    registers.add(reg('low', byPitch.sublist(0, q)));
  }

  // --- findings ----------------------------------------------------------------
  final problems = <Finding>[];
  final strengths = <Finding>[];

  // Weakest lines.
  final weak = [
    for (final l in lines)
      // Lines mostly not sung are covered by the 'unsung' finding.
      if (l.evaluable >= 2 && l.unsung * 2 <= l.evaluable && l.accuracy! < AnalysisRules.weakLineAccuracy) l,
  ]..sort((a, b) => a.accuracy!.compareTo(b.accuracy!));
  for (final l in weak.take(3)) {
    problems.add(Finding(
      kind: 'weak_line',
      severity: 0.35 + 0.6 * (AnalysisRules.weakLineAccuracy - l.accuracy!) / AnalysisRules.weakLineAccuracy,
      lines: [l.number],
      data: {
        'matched': l.matched,
        'evaluable': l.evaluable,
        'median_cents': _rn(l.medianCents, 0),
        'sharp': l.sharp,
        'flat': l.flat,
        'unsung': l.unsung,
        'range': l.range,
      },
    ));
  }

  // Overall sharp / flat tendency.
  final allCents = [for (final i in eval) ?cents(i)];
  if (allCents.length >= 10) {
    final m = _median(allCents);
    if (m.abs() >= 15) {
      final worst = [
        for (final l in lines)
          if (l.medianCents != null && l.evaluable >= 3 && l.medianCents!.sign == m.sign) l,
      ]..sort((a, b) => b.medianCents!.abs().compareTo(a.medianCents!.abs()));
      problems.add(Finding(
        kind: m > 0 ? 'sharp_overall' : 'flat_overall',
        severity: math.min(1.0, m.abs() / 40),
        lines: [for (final l in worst.take(3)) l.number],
        data: {'median_cents': m.round(), 'notes': allCents.length},
      ));
    }
  }

  // High or low register clearly worse than the rest.
  for (final r in registers) {
    final gap = overallAcc - r.accuracy;
    if (gap < 0.12 || r.evaluable < 4) continue;
    final inReg = [
      for (final l in lines)
        if (l.evaluable > 0 && (r.label == 'high' ? l.highMidi >= r.low : l.lowMidi <= r.high) && (l.accuracy ?? 1) < overallAcc) l,
    ]..sort((a, b) => a.accuracy!.compareTo(b.accuracy!));
    problems.add(Finding(
      kind: r.label == 'high' ? 'high_register' : 'low_register',
      severity: math.min(1.0, 0.3 + gap * 2),
      lines: [for (final l in inReg.take(3)) l.number],
      data: {
        'range': r.range,
        'accuracy': _pct(r.accuracy),
        'overall_accuracy': _pct(overallAcc),
        'median_cents': _rn(r.medianCents, 0),
        'unsung': r.unsung,
      },
    ));
  }

  // Song range against the singer's own range.
  final own = input.ownRange;
  if (own != null && notes.isNotEmpty) {
    // Scoring ignores octaves, so assume the singer takes the song in the
    // octave that suits their range best (a man singing a woman's song an
    // octave down is not out of range).
    SongRange folded(double octave) => SongRange.of(NoteList(
          Float64List.fromList([for (final n in notes) n.onset]),
          Float64List.fromList([for (final n in notes) n.offset]),
          Float64List.fromList([for (final n in notes) n.pitch + octave]),
        ));
    double miss(SongRange r) {
      final (a, b) = r.outside(own, input.pitchShift);
      return a + b;
    }

    var octave = 0.0;
    var range = folded(0);
    for (final o in const [-12.0, 12.0, -24.0, 24.0]) {
      final r = folded(o);
      if (miss(r) < miss(range) - 1e-9) {
        range = r;
        octave = o;
      }
    }
    final now = range.verdict(own, input.pitchShift);
    if (now.fit != RangeFit.fits) {
      final (above, below) = range.outside(own, input.pitchShift);
      final best = range.bestShift(own);
      final aboveIdx = [for (final i in eval) if (sung(i) + octave > own.high + 0.5) i];
      final belowIdx = [for (final i in eval) if (sung(i) + octave < own.low - 0.5) i];
      final outIdx = now.fit == RangeFit.low ? belowIdx : aboveIdx;
      problems.add(Finding(
        kind: 'out_of_range',
        severity: math.min(1.0, 0.3 + (above + below)),
        lines: [
          for (final l in lines)
            if (l.noteIndexes.any(outIdx.contains)) l.number,
        ].take(3).toList(),
        data: {
          'fit': now.fit.name,
          'semitones': now.bySemitones,
          'own_range': '${noteName(own.low)}–${noteName(own.high)}',
          'song_tessitura': '${noteName(range.low + input.pitchShift)}–${noteName(range.high + input.pitchShift)}',
          'time_above': _pct(above),
          'time_below': _pct(below),
          'accuracy_outside': outIdx.isEmpty ? null : _pct(outIdx.where(matched).length / outIdx.length),
          'current_key_change': input.pitchShift.round(),
          'suggested_key_change': best,
        },
      ));
    }
  }

  // Notes not sung at all.
  final silent = eval.where(unsung).length;
  if (silent >= 3 && silent >= 0.08 * eval.length) {
    final worst = [for (final l in lines) if (l.unsung > 0) l]..sort((a, b) => b.unsung.compareTo(a.unsung));
    problems.add(Finding(
      kind: 'unsung',
      severity: math.min(1.0, 0.3 + silent / eval.length * 2),
      lines: [for (final l in worst.take(3)) l.number],
      data: {'unsung': silent, 'evaluable': eval.length},
    ));
  }

  // Rushing or dragging overall (only with a calibrated clock).
  if ((tendency == 'rushing' || tendency == 'dragging') && tendencyMs != null) {
    final worst = [
      for (final l in lines)
        if (l.medianOnsetMs != null && l.medianOnsetMs!.sign == tendencyMs.sign && l.medianOnsetMs!.abs() >= 25) l,
    ]..sort((a, b) => b.medianOnsetMs!.abs().compareTo(a.medianOnsetMs!.abs()));
    problems.add(Finding(
      kind: tendency,
      severity: math.min(1.0, 0.3 + tendencyMs.abs() / 100),
      lines: [for (final l in worst.take(3)) l.number],
      data: {'median_ms': tendencyMs.round()},
    ));
  }

  // Lines with many off-beat entries.
  final offBeat = [
    for (final l in lines)
      if (l.lateOrEarly >= 2 && l.lateOrEarly >= 0.4 * (l.evaluable - l.unsung)) l,
  ]..sort((a, b) => b.lateOrEarly.compareTo(a.lateOrEarly));
  if (offBeat.isNotEmpty) {
    final l0 = offBeat.first;
    problems.add(Finding(
      kind: 'timing_lines',
      severity: math.min(1.0, 0.25 + l0.lateOrEarly / math.max(1, l0.evaluable - l0.unsung) * 0.6),
      lines: [for (final l in offBeat.take(3)) l.number],
      data: {
        for (final l in offBeat.take(3))
          'line_${l.number}': {'good_or_miss': l.lateOrEarly, 'sung': l.evaluable - l.unsung, 'median_onset_ms': _rn(l.medianOnsetMs, 0)},
      },
    ));
  }

  // Long notes cut short.
  final longIdx = <int>[], offErrors = <double>[];
  for (final i in eval) {
    if (notes[i].duration < AnalysisRules.longNoteSeconds || unsung(i)) continue;
    final off = (perNote[i]?['offset_error_ms'] as num?)?.toDouble();
    if (off == null) continue;
    longIdx.add(i);
    offErrors.add(off);
  }
  if (longIdx.length >= 4) {
    final early = offErrors.where((e) => e <= AnalysisRules.earlyReleaseMs).length;
    final share = early / longIdx.length;
    if (share >= 0.35) {
      final worst = [for (final l in lines) if (l.earlyReleases > 0) l]..sort((a, b) => b.earlyReleases.compareTo(a.earlyReleases));
      problems.add(Finding(
        kind: 'early_release',
        severity: math.min(1.0, 0.2 + share * 0.8),
        lines: [for (final l in worst.take(3)) l.number],
        data: {'early': early, 'long_notes': longIdx.length, 'median_offset_ms': _median(offErrors).round()},
      ));
    }
  }

  // Unsteady long notes.
  final takeStab = (tech['pitch_stability_cents'] as num?)?.toDouble();
  final refStab = (tech['reference_pitch_stability_cents'] as num?)?.toDouble();
  if (takeStab != null && takeStab - (refStab ?? 15) >= 8) {
    final shaky = <(int, double, double?)>[];
    for (final e in longDetail.entries) {
      final st = (e.value['stability_cents'] as num?)?.toDouble();
      if (st == null) continue;
      final rs = (e.value['ref_stability_cents'] as num?)?.toDouble();
      if (st - (rs ?? 15) >= 15) shaky.add((e.key, st, rs));
    }
    shaky.sort((a, b) => (b.$2 - (b.$3 ?? 15)).compareTo(a.$2 - (a.$3 ?? 15)));
    problems.add(Finding(
      kind: 'unsteady_long_notes',
      severity: math.min(1.0, 0.25 + (takeStab - (refStab ?? 15)) / 40),
      lines: {for (final x in shaky) ?lineOf[x.$1]?.number}.take(3).toList(),
      data: {
        'stability_cents': takeStab.round(),
        'reference_cents': ?refStab?.round(),
        'notes': [
          for (final x in shaky.take(3))
            {'line': lineOf[x.$1]?.number, 'note': noteName(sung(x.$1)), 'stability_cents': x.$2.round(), 'reference_cents': ?_rn(x.$3, 0)},
        ],
      },
    ));
  }

  // Vibrato: the original uses it but the take hardly does.
  final vibAmount = (tech['vibrato_amount'] as num?)?.toDouble();
  final refVib = (tech['reference_vibrato_amount'] as num?)?.toDouble();
  if (vibAmount != null && refVib != null && refVib >= 0.25 && vibAmount < 0.5 * refVib) {
    problems.add(Finding(
      kind: 'little_vibrato',
      severity: math.min(1.0, 0.2 + (refVib - vibAmount)),
      data: {'amount': _pct(vibAmount), 'reference_amount': _pct(refVib)},
    ));
  }

  // Dynamics that do not follow the original.
  final expr = (tech['expression_correlation'] as num?)?.toDouble();
  if (expr != null && expr < 0.45) {
    problems.add(Finding(kind: 'flat_dynamics', severity: math.min(1.0, 0.2 + (0.45 - expr)), data: {'correlation': _r(expr, 2)}));
  }

  // --- strengths ------------------------------------------------------------
  final subScores = <String, double?>{};
  final weights = <String, double>{};
  final sj = s['sub_scores'];
  for (final k in const ['pitch', 'rhythm', 'stability', 'vibrato', 'expression', 'long_tone']) {
    final v = sj is Map ? sj[k] : null;
    subScores[k] = v is Map && v['value'] is num ? (v['value'] as num).toDouble() * 100 : null;
    final w = v is Map ? v['weight'] : null;
    if (w is num) weights[k] = w.toDouble();
  }
  final strong = [
    for (final e in subScores.entries)
      if (e.value != null && e.value! >= 90) e,
  ]..sort((a, b) => b.value!.compareTo(a.value!));
  if (strong.isNotEmpty) {
    strengths.add(Finding(kind: 'strong_scores', severity: 0, positive: true, data: {for (final e in strong.take(3)) e.key: e.value!.round()}));
  }
  final clean = [
    for (final l in lines)
      if (l.evaluable >= 4 && l.matched == l.evaluable && l.rhythm['miss'] == 0 && l.earlyReleases == 0) l,
  ]..sort((a, b) => b.evaluable.compareTo(a.evaluable));
  if (clean.isNotEmpty) {
    strengths.add(Finding(kind: 'clean_lines', severity: 0, positive: true, lines: [for (final l in clean.take(3)) l.number]));
  }

  // --- history ----------------------------------------------------------------
  final earlier = [for (final h in input.history) if (h.createdAt.isBefore(input.takeCreatedAt)) h]
    ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  final previous = earlier.isEmpty ? null : earlier.first;
  final best = earlier.isEmpty ? null : earlier.reduce((a, b) => b.total > a.total ? b : a);
  // Older files hold raw totals; readScoreTotal puts them on today's scale.
  final scaled = s['total'] is num ? readScoreTotal(s) : null;
  final total = scaled?.total ?? 0.0;
  final rank = scaled?.rank ?? '';
  if (previous != null) {
    final deltas = <String, int>{};
    for (final k in subScores.keys) {
      final a = subScores[k], b = previous.subScores[k];
      if (a != null && b != null && (a - b).abs() >= 5) deltas[k] = (a - b).round();
    }
    final up = {for (final e in deltas.entries) if (e.value > 0) e.key: e.value};
    final down = {for (final e in deltas.entries) if (e.value < 0) e.key: e.value};
    final change = total - previous.total;
    if (up.isNotEmpty || change >= 2) {
      strengths.add(Finding(kind: 'progress', severity: 0, positive: true, data: {'total_change': _r(change, 1), 'improved': up}));
    }
    if (down.isNotEmpty) {
      problems.add(Finding(kind: 'regression', severity: math.min(0.6, 0.2 + down.values.map((v) => -v).reduce(math.max) / 50), data: {'total_change': _r(change, 1), 'dropped': down}));
    }
  }

  problems.sort((a, b) => b.severity.compareTo(a.severity));
  final findings = [...problems.take(6), ...strengths];
  for (var i = 0; i < findings.length; i++) {
    findings[i].id = 'F${i + 1}';
  }

  return TakeAnalysis(
    input: input,
    total: total,
    rank: rank,
    subScores: subScores,
    weights: weights,
    shift: shift,
    octaveExactShift: octaveExact,
    rhythmWindowsMs: windows,
    rhythmCounts: rhythmCounts,
    rhythmTendency: tendency,
    rhythmTendencyMs: tendencyMs,
    lines: lines,
    registers: registers,
    findings: findings,
    previous: previous,
    best: best,
    historyCount: earlier.length,
  );
}

/// Groups the notes into lines: each lyric line takes the notes whose
/// middle falls in it (or within half a second of it); the remaining notes
/// are split at pauses of [pause] seconds.
List<LineStats> _groupLines(List<ReferenceNote> notes, List<LyricLine> lyrics, {double pause = 0.35}) {
  final order = [for (var i = 0; i < notes.length; i++) i]..sort((a, b) => notes[a].onset.compareTo(notes[b].onset));
  final groups = <(double, double, String?, List<int>)>[];
  final byLyric = <int, List<int>>{};
  final loose = <int>[];
  for (final i in order) {
    final mid = (notes[i].onset + notes[i].offset) / 2;
    var best = -1;
    var bestDist = 0.5;
    for (var k = 0; k < lyrics.length; k++) {
      final l = lyrics[k];
      final d = mid < l.start ? l.start - mid : (mid >= l.end ? mid - l.end : 0.0);
      if (d < bestDist || (d == 0 && bestDist == 0 && best < 0)) {
        best = k;
        bestDist = d;
        if (d == 0) break;
      }
    }
    if (best >= 0) {
      (byLyric[best] ??= []).add(i);
    } else {
      loose.add(i);
    }
  }
  for (final e in byLyric.entries) {
    final l = lyrics[e.key];
    final text = l.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    groups.add((notes[e.value.first].onset, notes[e.value.last].offset, text.isEmpty ? null : _clip(text, 80), e.value));
  }
  var run = <int>[];
  void flush() {
    if (run.isEmpty) return;
    groups.add((notes[run.first].onset, notes[run.last].offset, null, run));
    run = [];
  }

  for (final i in loose) {
    if (run.isNotEmpty && notes[i].onset - notes[run.last].offset >= pause) flush();
    run.add(i);
  }
  flush();
  groups.sort((a, b) => a.$1.compareTo(b.$1));
  return [
    for (var k = 0; k < groups.length; k++)
      LineStats(number: k + 1, start: groups[k].$1, end: groups[k].$2, lyric: groups[k].$3, noteIndexes: groups[k].$4),
  ];
}

String _clip(String s, int max) => s.runes.length <= max ? s : '${String.fromCharCodes(s.runes.take(max - 1))}…';

double _median(List<double> v) {
  final s = [...v]..sort();
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
}

int _int(Object? v) => v is num ? v.round() : 0;
double _r(double v, int digits) {
  final f = math.pow(10, digits);
  return (v * f).round() / f;
}

double? _rn(double? v, int digits) => v == null ? null : _r(v, digits);
int _pct(double v) => (v * 100).round();
