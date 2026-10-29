/// Rhythm judgements in the style of rhythm games (maimai, CHUNITHM, Taiko):
/// every reference note's onset and offset error falls into a tier with a
/// fixed credit, and the rhythm sub-score is the average credit.
///
///   PERFECT  <= 50 ms   100 %
///   GREAT    <= 100 ms   70 %
///   GOOD     <= 150 ms   40 %
///   MISS     beyond, or the note was not sung    0 %
///
/// Windows are for 120 BPM and scale with the beat length (faster songs are
/// stricter, slower songs looser), clamped to 0.75x..1.5x. Offsets use the
/// same tiers widened to 20 / 40 / 60 % of the note length for long notes.
/// A note's credit is 70 % onset + 30 % offset (offset only counts when the
/// onset was not a MISS).
library;

import 'dart:math' as math;

import 'models.dart';

enum RhythmJudgement { perfect, great, good, miss }

class RhythmWindows {
  const RhythmWindows({required this.perfect, required this.great, required this.good, this.scale = 1, this.bpm});

  /// Half-widths in seconds.
  final double perfect, great, good;
  final double scale;
  final double? bpm;

  static const basePerfect = 0.05, baseGreat = 0.10, baseGood = 0.15;
  static const referenceBpm = 120.0;

  /// Windows for a song tempo (null = unknown -> the 120 BPM windows).
  factory RhythmWindows.forTempo(double? bpm) {
    final s = (bpm == null || !(bpm > 0)) ? 1.0 : (referenceBpm / bpm).clamp(0.75, 1.5).toDouble();
    return RhythmWindows(perfect: basePerfect * s, great: baseGreat * s, good: baseGood * s, scale: s, bpm: bpm);
  }

  RhythmJudgement classify(double absErrorSeconds, {double minPerfect = 0, double minGreat = 0, double minGood = 0}) {
    if (absErrorSeconds <= math.max(perfect, minPerfect) + 1e-9) return RhythmJudgement.perfect;
    if (absErrorSeconds <= math.max(great, minGreat) + 1e-9) return RhythmJudgement.great;
    if (absErrorSeconds <= math.max(good, minGood) + 1e-9) return RhythmJudgement.good;
    return RhythmJudgement.miss;
  }

  static double credit(RhythmJudgement j) => switch (j) {
        RhythmJudgement.perfect => 1.0,
        RhythmJudgement.great => 0.7,
        RhythmJudgement.good => 0.4,
        RhythmJudgement.miss => 0.0,
      };

  factory RhythmWindows.fromJson(Map<String, dynamic> j) => RhythmWindows(
        perfect: (j['perfect_ms'] as num).toDouble() / 1000,
        great: (j['great_ms'] as num).toDouble() / 1000,
        good: (j['good_ms'] as num).toDouble() / 1000,
        scale: (j['scale'] as num?)?.toDouble() ?? 1,
        bpm: (j['bpm'] as num?)?.toDouble(),
      );

  Map<String, dynamic> toJson() => {
        'perfect_ms': perfect * 1000,
        'great_ms': great * 1000,
        'good_ms': good * 1000,
        'scale': scale,
        'bpm': bpm,
      };
}

class RhythmResult {
  const RhythmResult({
    required this.windows,
    required this.noteIndex,
    required this.onset,
    required this.offset,
    required this.score,
    this.tendencyMs,
    this.clockTrusted = false,
  });

  /// Timing was judged against the calibrated recording clock; when false a
  /// global offset was estimated and removed, so [tendency] only reflects
  /// differences within the take and is not reported.
  final bool clockTrusted;

  final RhythmWindows windows;

  /// Reference note index for each judged (evaluable) note.
  final List<int> noteIndex;
  final List<RhythmJudgement> onset;
  final List<RhythmJudgement?> offset; // null when the onset was a MISS
  final double score; // 0..1

  /// Median signed onset error (ms) of the notes that were hit: negative =
  /// early (rushing), positive = late (dragging).
  final double? tendencyMs;

  static const tendencyThresholdMs = 25.0;

  /// 'rushing', 'dragging', 'steady' or 'none'.
  String get tendency {
    final t = tendencyMs;
    if (t == null || !clockTrusted) return 'none';
    if (t <= -tendencyThresholdMs) return 'rushing';
    if (t >= tendencyThresholdMs) return 'dragging';
    return 'steady';
  }

  Map<String, int> get counts => {
        for (final j in RhythmJudgement.values) j.name: onset.where((x) => x == j).length,
      };

  factory RhythmResult.fromJson(Map<String, dynamic> j) {
    RhythmJudgement byName(Object? n) => RhythmJudgement.values.firstWhere((v) => v.name == n, orElse: () => RhythmJudgement.miss);
    final notes = (j['notes'] as List? ?? const []).cast<Map>();
    return RhythmResult(
      windows: RhythmWindows.fromJson((j['windows'] as Map).cast<String, dynamic>()),
      noteIndex: [for (final n in notes) (n['index'] as num).toInt()],
      onset: [for (final n in notes) byName(n['onset'])],
      offset: [for (final n in notes) n['offset'] == null ? null : byName(n['offset'])],
      score: (j['score'] as num).toDouble(),
      tendencyMs: (j['tendency_ms'] as num?)?.toDouble(),
      clockTrusted: j['clock_trusted'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'score': score,
        'counts': counts,
        'tendency': tendency,
        'tendency_ms': tendencyMs,
        'clock_trusted': clockTrusted,
        'windows': windows.toJson(),
        'notes': [
          for (var i = 0; i < noteIndex.length; i++)
            {'index': noteIndex[i], 'onset': onset[i].name, 'offset': offset[i]?.name},
        ],
      };
}

/// Judges every evaluable reference note from note metrics measured on a
/// take that was aligned with a single global offset (so per-note timing
/// errors are kept).
RhythmResult judgeRhythm(List<ReferenceNote> refNotes, NoteMetrics notes, RhythmWindows w, {bool clockTrusted = false}) {
  final idx = <int>[];
  final on = <RhythmJudgement>[];
  final off = <RhythmJudgement?>[];
  final signed = <double>[];
  var credit = 0.0;
  for (final r in notes.perNote) {
    if (!r.evaluable) continue;
    idx.add(r.index);
    final e = r.onsetErrorMs;
    final jOn = e == null ? RhythmJudgement.miss : w.classify(e.abs() / 1000);
    on.add(jOn);
    if (jOn == RhythmJudgement.miss) {
      off.add(null);
      continue;
    }
    signed.add(e!);
    final dur = r.index < refNotes.length ? refNotes[r.index].duration : 0.0;
    final eo = r.offsetErrorMs;
    final jOff = eo == null
        ? RhythmJudgement.miss
        : w.classify(eo.abs() / 1000, minPerfect: 0.2 * dur, minGreat: 0.4 * dur, minGood: 0.6 * dur);
    off.add(jOff);
    credit += 0.7 * RhythmWindows.credit(jOn) + 0.3 * RhythmWindows.credit(jOff);
  }
  double? tendency;
  if (signed.isNotEmpty) {
    signed.sort();
    final m = signed.length ~/ 2;
    tendency = signed.length.isOdd ? signed[m] : (signed[m - 1] + signed[m]) / 2;
  }
  return RhythmResult(
    windows: w,
    noteIndex: idx,
    onset: on,
    offset: off,
    score: idx.isEmpty ? 0.0 : (credit / idx.length).clamp(0.0, 1.0),
    tendencyMs: tendency,
    clockTrusted: clockTrusted,
  );
}
