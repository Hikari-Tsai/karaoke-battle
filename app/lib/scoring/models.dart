/// Data classes (inputs, options, weights and results) for the scoring module.
///
/// Everything in this file is pure Dart: no Flutter imports, so the whole
/// scoring pipeline can run inside an isolate.
library;

import 'dart:math' as math;

import 'alignment.dart';
import 'rhythm.dart';

// ---------------------------------------------------------------------------
// Pitch helpers
// ---------------------------------------------------------------------------

/// Converts a frequency in Hz to a (fractional) MIDI note number.
double hzToMidi(double hz) => 69.0 + 12.0 * math.log(hz / 440.0) / math.ln2;

/// Converts a (fractional) MIDI note number to Hz.
double midiToHz(double midi) => 440.0 * math.pow(2.0, (midi - 69.0) / 12.0);

/// Signed chroma difference `a - b` wrapped into the range `(-6, 6]`
/// semitones (i.e. octave-invariant pitch deviation).
double chromaDelta(double a, double b) {
  var d = (a - b) % 12.0;
  if (d > 6.0) d -= 12.0;
  return d;
}

/// Unsigned chroma distance in semitones in `[0, 6]`.
double chromaDistance(double a, double b) => chromaDelta(a, b).abs();

// ---------------------------------------------------------------------------
// JSON helpers (private)
// ---------------------------------------------------------------------------

List<double> _doubleList(Object? v) {
  if (v == null) return const [];
  return (v as List).map((e) => (e as num).toDouble()).toList(growable: false);
}

double _d(Object? v, [double fallback = 0]) =>
    v == null ? fallback : (v as num).toDouble();

double? _dn(Object? v) => v == null ? null : (v as num).toDouble();

int _i(Object? v, [int fallback = 0]) =>
    v == null ? fallback : (v as num).toInt();

// ---------------------------------------------------------------------------
// Inputs
// ---------------------------------------------------------------------------

/// A reference note from the transcription engine (seconds, MIDI float).
class ReferenceNote {
  const ReferenceNote({
    required this.onset,
    required this.offset,
    required this.pitch,
  });

  /// Note start in seconds.
  final double onset;

  /// Note end in seconds.
  final double offset;

  /// Pitch as a fractional MIDI note number.
  final double pitch;

  /// Duration in seconds.
  double get duration => offset - onset;

  factory ReferenceNote.fromJson(Map<String, dynamic> json) => ReferenceNote(
    onset: _d(json['onset']),
    offset: _d(json['offset']),
    pitch: _d(json['pitch']),
  );

  Map<String, dynamic> toJson() => {
    'onset': onset,
    'offset': offset,
    'pitch': pitch,
  };
}

/// The reference transcription: a sorted, non-overlapping list of notes.
class ReferenceNotes {
  const ReferenceNotes({
    required this.notes,
    this.timestep = 0.01,
    this.language = '',
    this.model = '',
  });

  final double timestep;
  final String language;
  final String model;
  final List<ReferenceNote> notes;

  /// End time of the last note (0 when empty).
  double get endTime => notes.isEmpty ? 0.0 : notes.last.offset;

  factory ReferenceNotes.fromJson(Map<String, dynamic> json) => ReferenceNotes(
    timestep: _d(json['timestep'], 0.01),
    language: (json['language'] ?? '') as String,
    model: (json['model'] ?? '') as String,
    notes: ((json['notes'] ?? const []) as List)
        .map((e) => ReferenceNote.fromJson(e as Map<String, dynamic>))
        .toList(growable: false),
  );

  Map<String, dynamic> toJson() => {
    'timestep': timestep,
    'language': language,
    'model': model,
    'notes': notes.map((n) => n.toJson()).toList(growable: false),
  };
}

/// An F0 track: frame times (s), F0 in Hz (0 = unvoiced) and a confidence
/// value per frame.
class F0Track {
  const F0Track({
    required this.times,
    required this.f0,
    this.confidence = const [],
    this.hop = 0.016,
    this.sampleRate = 16000,
  });

  final double hop;
  final int sampleRate;
  final List<double> times;
  final List<double> f0;

  /// Per-frame confidence in `[0, 1]`; may be empty (treated as 1).
  final List<double> confidence;

  int get length => math.min(times.length, f0.length);

  factory F0Track.fromJson(Map<String, dynamic> json) => F0Track(
    hop: _d(json['hop'], 0.016),
    sampleRate: _i(json['sample_rate'], 16000),
    times: _doubleList(json['times']),
    f0: _doubleList(json['f0']),
    confidence: _doubleList(json['confidence']),
  );

  Map<String, dynamic> toJson() => {
    'hop': hop,
    'sample_rate': sampleRate,
    'times': times,
    'f0': f0,
    'confidence': confidence,
  };
}

/// A loudness curve: times (s) and RMS level in dB.
class EnergyCurve {
  const EnergyCurve({required this.times, required this.rmsDb});

  final List<double> times;
  final List<double> rmsDb;

  int get length => math.min(times.length, rmsDb.length);

  factory EnergyCurve.fromJson(Map<String, dynamic> json) => EnergyCurve(
    times: _doubleList(json['times']),
    rmsDb: _doubleList(json['rms_db']),
  );

  Map<String, dynamic> toJson() => {'times': times, 'rms_db': rmsDb};
}

/// Weights of the six sub-scores. They do not need to sum to 100: the total
/// is `100 * sum(w_i * s_i) / sum(w_i)` over the sub-scores that could be
/// evaluated (see [ScoreResult]).
class ScoringWeights {
  const ScoringWeights({
    this.pitch = 40,
    this.rhythm = 20,
    this.stability = 10,
    this.vibrato = 10,
    this.expression = 10,
    this.longTone = 10,
  });

  final double pitch;
  final double rhythm;
  final double stability;
  final double vibrato;
  final double expression;
  final double longTone;

  factory ScoringWeights.fromJson(Map<String, dynamic> json) => ScoringWeights(
    pitch: _d(json['pitch'], 40),
    rhythm: _d(json['rhythm'], 20),
    stability: _d(json['stability'], 10),
    vibrato: _d(json['vibrato'], 10),
    expression: _d(json['expression'], 10),
    longTone: _d(json['long_tone'], 10),
  );

  Map<String, dynamic> toJson() => {
    'pitch': pitch,
    'rhythm': rhythm,
    'stability': stability,
    'vibrato': vibrato,
    'expression': expression,
    'long_tone': longTone,
  };
}

/// How take notes are obtained for the note metrics.
enum NoteSegmentation {
  /// Evaluate each reference note on its own (aligned) span: conforming
  /// frames are voiced and within 50 cents of the target; onset/offset come
  /// from the conforming run. Robust to syllable-level reference notes that
  /// share a pitch (the default).
  referenceGuided,

  /// Segment the take F0 track into notes and run mir_eval-style bipartite
  /// matching (merges consecutive same-pitch syllables).
  fromTakeF0,
}

/// Tunable parameters of the pipeline. Defaults implement the project's
/// agreed design (see the README section of `scorer.dart`).
class ScoringOptions {
  const ScoringOptions({
    this.alignmentMode = AlignmentMode.dtw,
    this.noteSegmentation = NoteSegmentation.referenceGuided,
    this.bandSeconds = 1.0,
    this.stepPenalty = 0.5,
    this.maxOffsetSeconds = 2.0,
    this.confidenceThreshold = 0.4,
    this.hopSeconds,
    this.longNoteSeconds = 0.4,
    this.vibratoTarget = 0.4,
    this.tempoBpm,
    this.calibratedTiming = false,
  });

  /// DTW (default) or a single global offset from voicing cross-correlation.
  final AlignmentMode alignmentMode;

  /// Reference-guided (default) or take-F0-segmentation note metrics.
  final NoteSegmentation noteSegmentation;

  /// Half-width of the Sakoe-Chiba band in seconds.
  final double bandSeconds;

  /// Extra cost of a non-diagonal DTW step (gap penalty, see `alignDtw`).
  final double stepPenalty;

  /// Search range (+/-) for the global voicing offset in seconds.
  final double maxOffsetSeconds;

  /// Frames with confidence below this are treated as unvoiced.
  final double confidenceThreshold;

  /// Working frame hop; defaults to the take's hop.
  final double? hopSeconds;

  /// Minimum reference-note duration for "long tone" / vibrato / stability.
  final double longNoteSeconds;

  /// Vibrato amount (mean per-long-note fraction of analysis windows with
  /// vibrato, 0..1) that earns full vibrato marks; also caps the target
  /// taken from the reference F0 curve.
  final double vibratoTarget;

  /// Song tempo; scales the rhythm judgement windows (see rhythm.dart).
  /// Null = unknown (120 BPM windows).
  final double? tempoBpm;

  /// The take's timing is already latency-compensated with a measured
  /// latency: rhythm is judged against the track clock as recorded (so a
  /// take that is early or late as a whole shows up as rushing / dragging)
  /// unless the estimated global offset is implausibly large.
  final bool calibratedTiming;

  factory ScoringOptions.fromJson(Map<String, dynamic> json) => ScoringOptions(
    alignmentMode: AlignmentMode.values.firstWhere(
      (m) => m.name == (json['alignment_mode'] ?? 'dtw'),
      orElse: () => AlignmentMode.dtw,
    ),
    noteSegmentation: NoteSegmentation.values.firstWhere(
      (m) => m.name == (json['note_segmentation'] ?? 'referenceGuided'),
      orElse: () => NoteSegmentation.referenceGuided,
    ),
    bandSeconds: _d(json['band_seconds'], 1.0),
    stepPenalty: _d(json['step_penalty'], 0.5),
    maxOffsetSeconds: _d(json['max_offset_seconds'], 2.0),
    confidenceThreshold: _d(json['confidence_threshold'], 0.4),
    hopSeconds: _dn(json['hop_seconds']),
    longNoteSeconds: _d(json['long_note_seconds'], 0.4),
    vibratoTarget: _d(json['vibrato_target'], 0.4),
    tempoBpm: _dn(json['tempo_bpm']),
    calibratedTiming: json['calibrated_timing'] == true,
  );

  Map<String, dynamic> toJson() => {
    'alignment_mode': alignmentMode.name,
    'note_segmentation': noteSegmentation.name,
    'band_seconds': bandSeconds,
    'step_penalty': stepPenalty,
    'max_offset_seconds': maxOffsetSeconds,
    'confidence_threshold': confidenceThreshold,
    if (hopSeconds != null) 'hop_seconds': hopSeconds,
    'long_note_seconds': longNoteSeconds,
    'vibrato_target': vibratoTarget,
    if (tempoBpm != null) 'tempo_bpm': tempoBpm,
    if (calibratedTiming) 'calibrated_timing': true,
  };
}

/// Everything the scorer needs for one take.
class ScoringInput {
  const ScoringInput({
    required this.referenceNotes,
    required this.takeF0,
    this.referenceF0,
    this.referenceEnergy,
    this.takeEnergy,
    this.weights = const ScoringWeights(),
    this.options = const ScoringOptions(),
  });

  final ReferenceNotes referenceNotes;

  /// F0 of the original vocal stem (optional; used as the frame reference and
  /// for the reference vibrato fraction when present).
  final F0Track? referenceF0;
  final F0Track takeF0;
  final EnergyCurve? referenceEnergy;
  final EnergyCurve? takeEnergy;
  final ScoringWeights weights;
  final ScoringOptions options;

  factory ScoringInput.fromJson(Map<String, dynamic> json) => ScoringInput(
    referenceNotes: ReferenceNotes.fromJson(
      json['reference_notes'] as Map<String, dynamic>,
    ),
    referenceF0: json['reference_f0'] == null
        ? null
        : F0Track.fromJson(json['reference_f0'] as Map<String, dynamic>),
    takeF0: F0Track.fromJson(json['take_f0'] as Map<String, dynamic>),
    referenceEnergy: json['reference_energy'] == null
        ? null
        : EnergyCurve.fromJson(
            json['reference_energy'] as Map<String, dynamic>,
          ),
    takeEnergy: json['take_energy'] == null
        ? null
        : EnergyCurve.fromJson(json['take_energy'] as Map<String, dynamic>),
    weights: json['weights'] == null
        ? const ScoringWeights()
        : ScoringWeights.fromJson(json['weights'] as Map<String, dynamic>),
    options: json['options'] == null
        ? const ScoringOptions()
        : ScoringOptions.fromJson(json['options'] as Map<String, dynamic>),
  );

  Map<String, dynamic> toJson() => {
    'reference_notes': referenceNotes.toJson(),
    if (referenceF0 != null) 'reference_f0': referenceF0!.toJson(),
    'take_f0': takeF0.toJson(),
    if (referenceEnergy != null) 'reference_energy': referenceEnergy!.toJson(),
    if (takeEnergy != null) 'take_energy': takeEnergy!.toJson(),
    'weights': weights.toJson(),
    'options': options.toJson(),
  };
}

// ---------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------

/// mir_eval `melody` frame metrics, all in `[0, 1]`.
class FrameMetrics {
  const FrameMetrics({
    required this.rawPitchAccuracy,
    required this.rawChromaAccuracy,
    required this.voicingRecall,
    required this.voicingFalseAlarm,
    required this.overallAccuracy,
    this.rawPitchAccuracyOctaveExact = 0,
    this.referenceVoicedFrames = 0,
    this.totalFrames = 0,
  });

  /// RPA computed with the chroma shift `k` (octave-sensitive).
  final double rawPitchAccuracy;

  /// RCA computed with the chroma shift `k`.
  final double rawChromaAccuracy;
  final double voicingRecall;
  final double voicingFalseAlarm;
  final double overallAccuracy;

  /// RPA computed with the octave-exact shift (display only).
  final double rawPitchAccuracyOctaveExact;
  final int referenceVoicedFrames;
  final int totalFrames;

  factory FrameMetrics.fromJson(Map<String, dynamic> json) => FrameMetrics(
    rawPitchAccuracy: _d(json['raw_pitch_accuracy']),
    rawChromaAccuracy: _d(json['raw_chroma_accuracy']),
    voicingRecall: _d(json['voicing_recall']),
    voicingFalseAlarm: _d(json['voicing_false_alarm']),
    overallAccuracy: _d(json['overall_accuracy']),
    rawPitchAccuracyOctaveExact: _d(json['raw_pitch_accuracy_octave_exact']),
    referenceVoicedFrames: _i(json['reference_voiced_frames']),
    totalFrames: _i(json['total_frames']),
  );

  Map<String, dynamic> toJson() => {
    'raw_pitch_accuracy': rawPitchAccuracy,
    'raw_chroma_accuracy': rawChromaAccuracy,
    'voicing_recall': voicingRecall,
    'voicing_false_alarm': voicingFalseAlarm,
    'overall_accuracy': overallAccuracy,
    'raw_pitch_accuracy_octave_exact': rawPitchAccuracyOctaveExact,
    'reference_voiced_frames': referenceVoicedFrames,
    'total_frames': totalFrames,
  };
}

/// Precision / recall / F1 of one note-matching criterion.
class PrecisionRecallF1 {
  const PrecisionRecallF1({
    required this.precision,
    required this.recall,
    required this.f1,
    required this.matches,
  });

  final double precision;
  final double recall;
  final double f1;
  final int matches;

  factory PrecisionRecallF1.fromCounts({
    required int matches,
    required int estimated,
    required int reference,
  }) {
    final p = estimated == 0 ? 0.0 : matches / estimated;
    final r = reference == 0 ? 0.0 : matches / reference;
    final f = (p + r) == 0 ? 0.0 : 2 * p * r / (p + r);
    return PrecisionRecallF1(precision: p, recall: r, f1: f, matches: matches);
  }

  factory PrecisionRecallF1.fromJson(Map<String, dynamic> json) =>
      PrecisionRecallF1(
        precision: _d(json['precision']),
        recall: _d(json['recall']),
        f1: _d(json['f1']),
        matches: _i(json['matches']),
      );

  Map<String, dynamic> toJson() => {
    'precision': precision,
    'recall': recall,
    'f1': f1,
    'matches': matches,
  };
}

/// A note segmented from the take F0 track. Times are in the take's own
/// timeline; [refOnset]/[refOffset] are the same instants mapped into the
/// reference timeline through the alignment.
class TakeNote {
  const TakeNote({
    required this.onset,
    required this.offset,
    required this.pitch,
    required this.refOnset,
    required this.refOffset,
    this.startFrame = 0,
    this.endFrame = 0,
  });

  final double onset;
  final double offset;

  /// Median MIDI pitch of the segment, *after* applying the chroma shift.
  final double pitch;
  final double refOnset;
  final double refOffset;

  /// Frame range `[startFrame, endFrame)` on the take grid.
  final int startFrame;
  final int endFrame;

  double get duration => offset - onset;

  TakeNote copyWith({double? pitch, double? refOnset, double? refOffset}) =>
      TakeNote(
        onset: onset,
        offset: offset,
        pitch: pitch ?? this.pitch,
        refOnset: refOnset ?? this.refOnset,
        refOffset: refOffset ?? this.refOffset,
        startFrame: startFrame,
        endFrame: endFrame,
      );

  factory TakeNote.fromJson(Map<String, dynamic> json) => TakeNote(
    onset: _d(json['onset']),
    offset: _d(json['offset']),
    pitch: _d(json['pitch']),
    refOnset: _d(json['ref_onset']),
    refOffset: _d(json['ref_offset']),
    startFrame: _i(json['start_frame']),
    endFrame: _i(json['end_frame']),
  );

  Map<String, dynamic> toJson() => {
    'onset': onset,
    'offset': offset,
    'pitch': pitch,
    'ref_onset': refOnset,
    'ref_offset': refOffset,
    'start_frame': startFrame,
    'end_frame': endFrame,
  };
}

/// Per-reference-note report.
class NoteReport {
  const NoteReport({
    required this.index,
    required this.matchedOnset,
    required this.matched,
    required this.matchedOffset,
    this.takeNoteIndex,
    this.centsDeviation,
    this.onsetErrorMs,
    this.offsetErrorMs,
    this.overlapIoU = 0,
    this.voicedFraction = 0,
    this.pitchCoverage = 0,
    this.evaluable = true,
  });

  /// Index into `ReferenceNotes.notes`.
  final int index;

  /// Onset criterion: the take note (or conforming run) starts within 50 ms
  /// of the expected onset.
  final bool matchedOnset;

  /// The note was sung with the right pitch: reference-guided mode requires
  /// voiced-and-within-50-cents frames for at least 50 % of the span;
  /// segmentation mode requires an onset + pitch match.
  final bool matched;

  /// Matched under the onset + pitch + offset criterion.
  final bool matchedOffset;

  /// Index of the take note used for the error figures: the onset+pitch match
  /// when there is one, else the overlapping take note with the largest IoU.
  final int? takeNoteIndex;

  /// Median chroma-wise cents deviation of the take from the target
  /// (reference F0 curve where voiced, else the note pitch) over the note
  /// span; null when the take is unvoiced for the whole span.
  final double? centsDeviation;

  /// Take onset minus reference onset in ms (null without a take note).
  final double? onsetErrorMs;

  /// Take offset minus reference offset in ms (null without a take note).
  final double? offsetErrorMs;

  /// Intersection-over-union of the note spans (0 without a take note).
  final double overlapIoU;

  /// Fraction of the reference note span where the take is voiced.
  final double voicedFraction;

  /// Fraction of the reference note span where the take is voiced and
  /// within 50 cents of the target.
  final double pitchCoverage;

  /// False when the reference F0 curve is unvoiced for the whole span (the
  /// note cannot be observed); such notes are excluded from P/R/F1.
  final bool evaluable;

  factory NoteReport.fromJson(Map<String, dynamic> json) => NoteReport(
    index: _i(json['index']),
    matchedOnset: json['matched_onset'] == true,
    matched: json['matched'] == true,
    matchedOffset: json['matched_offset'] == true,
    takeNoteIndex: json['take_note_index'] == null
        ? null
        : _i(json['take_note_index']),
    centsDeviation: _dn(json['cents_deviation']),
    onsetErrorMs: _dn(json['onset_error_ms']),
    offsetErrorMs: _dn(json['offset_error_ms']),
    overlapIoU: _d(json['overlap_iou']),
    voicedFraction: _d(json['voiced_fraction']),
    pitchCoverage: _d(json['pitch_coverage']),
    evaluable: json['evaluable'] != false,
  );

  Map<String, dynamic> toJson() => {
    'index': index,
    'matched_onset': matchedOnset,
    'matched': matched,
    'matched_offset': matchedOffset,
    'take_note_index': takeNoteIndex,
    'cents_deviation': centsDeviation,
    'onset_error_ms': onsetErrorMs,
    'offset_error_ms': offsetErrorMs,
    'overlap_iou': overlapIoU,
    'voiced_fraction': voicedFraction,
    'pitch_coverage': pitchCoverage,
    'evaluable': evaluable,
  };
}

/// mir_eval `transcription` note metrics plus the per-note report.
class NoteMetrics {
  const NoteMetrics({
    required this.onset,
    required this.onsetPitch,
    required this.onsetPitchOffset,
    required this.perNote,
    required this.takeNotes,
    this.segmentation = NoteSegmentation.referenceGuided,
    this.falsePositives = 0,
    this.medianAbsOnsetErrorMs,
    this.medianAbsOffsetErrorMs,
  });

  final PrecisionRecallF1 onset;
  final PrecisionRecallF1 onsetPitch;
  final PrecisionRecallF1 onsetPitchOffset;
  final List<NoteReport> perNote;

  /// Notes segmented from the take F0 (informational in reference-guided
  /// mode, the matched notes in segmentation mode).
  final List<TakeNote> takeNotes;
  final NoteSegmentation segmentation;

  /// Reference-guided mode: sung regions that cover no reference note (plus
  /// notes sung with the wrong pitch); they count against precision.
  final int falsePositives;

  /// Median |onset error| over reference notes that have a take note.
  final double? medianAbsOnsetErrorMs;
  final double? medianAbsOffsetErrorMs;

  factory NoteMetrics.fromJson(Map<String, dynamic> json) => NoteMetrics(
    onset: PrecisionRecallF1.fromJson(json['onset'] as Map<String, dynamic>),
    onsetPitch: PrecisionRecallF1.fromJson(
      json['onset_pitch'] as Map<String, dynamic>,
    ),
    onsetPitchOffset: PrecisionRecallF1.fromJson(
      json['onset_pitch_offset'] as Map<String, dynamic>,
    ),
    perNote: ((json['per_note'] ?? const []) as List)
        .map((e) => NoteReport.fromJson(e as Map<String, dynamic>))
        .toList(growable: false),
    takeNotes: ((json['take_notes'] ?? const []) as List)
        .map((e) => TakeNote.fromJson(e as Map<String, dynamic>))
        .toList(growable: false),
    segmentation: NoteSegmentation.values.firstWhere(
      (m) => m.name == (json['segmentation'] ?? 'referenceGuided'),
      orElse: () => NoteSegmentation.referenceGuided,
    ),
    falsePositives: _i(json['false_positives']),
    medianAbsOnsetErrorMs: _dn(json['median_abs_onset_error_ms']),
    medianAbsOffsetErrorMs: _dn(json['median_abs_offset_error_ms']),
  );

  Map<String, dynamic> toJson() => {
    'segmentation': segmentation.name,
    'false_positives': falsePositives,
    'onset': onset.toJson(),
    'onset_pitch': onsetPitch.toJson(),
    'onset_pitch_offset': onsetPitchOffset.toJson(),
    'per_note': perNote.map((n) => n.toJson()).toList(growable: false),
    'take_notes': takeNotes.map((n) => n.toJson()).toList(growable: false),
    'median_abs_onset_error_ms': medianAbsOnsetErrorMs,
    'median_abs_offset_error_ms': medianAbsOffsetErrorMs,
  };
}

/// Vibrato / stability / expression / long-tone measurements.
class TechniqueMetrics {
  const TechniqueMetrics({
    required this.longReferenceNotes,
    required this.longTakeSegments,
    required this.vibratoSegments,
    required this.vibratoFraction,
    this.vibratoAmount = 0,
    this.referenceVibratoAmount,
    this.vibratoRateHz,
    this.vibratoExtentCents,
    this.referenceVibratoFraction,
    this.pitchStabilityCents,
    this.referencePitchStabilityCents,
    this.expressionCorrelation,
    this.longToneScore,
  });

  /// Number of reference notes at least `longNoteSeconds` long.
  final int longReferenceNotes;

  /// Long reference notes where the take is voiced for at least half of the
  /// span (the ones analysed for vibrato and stability).
  final int longTakeSegments;

  /// Long reference notes with detected vibrato in the take.
  final int vibratoSegments;

  /// `vibratoSegments / longReferenceNotes` (0 without long notes).
  final double vibratoFraction;

  /// Continuous vibrato amount: mean over long reference notes of the
  /// fraction of analysis windows with vibrato in the take (0..1).
  final double vibratoAmount;

  /// The same amount measured on the reference F0 curve (null without it).
  final double? referenceVibratoAmount;

  /// Median vibrato rate over vibrato segments (null without vibrato).
  final double? vibratoRateHz;

  /// Median peak-to-peak vibrato extent in cents (null without vibrato).
  final double? vibratoExtentCents;

  /// Same fraction measured on the reference F0 curve (null without it).
  final double? referenceVibratoFraction;

  /// Mean over analysed long notes of the std (cents) of the take pitch
  /// track after removing the vibrato band (null without analysed notes).
  final double? pitchStabilityCents;

  /// The same measurement on the reference F0 curve (null without it).
  final double? referencePitchStabilityCents;

  /// Pearson correlation between aligned take and reference loudness curves
  /// (null when either curve is missing).
  final double? expressionCorrelation;

  /// Mean over long reference notes of the fraction of the note where the
  /// take is voiced and within 50 cents (null without long notes).
  final double? longToneScore;

  factory TechniqueMetrics.fromJson(Map<String, dynamic> json) =>
      TechniqueMetrics(
        longReferenceNotes: _i(json['long_reference_notes']),
        longTakeSegments: _i(json['long_take_segments']),
        vibratoSegments: _i(json['vibrato_segments']),
        vibratoFraction: _d(json['vibrato_fraction']),
        vibratoAmount: _d(json['vibrato_amount']),
        referenceVibratoAmount: _dn(json['reference_vibrato_amount']),
        vibratoRateHz: _dn(json['vibrato_rate_hz']),
        vibratoExtentCents: _dn(json['vibrato_extent_cents']),
        referenceVibratoFraction: _dn(json['reference_vibrato_fraction']),
        pitchStabilityCents: _dn(json['pitch_stability_cents']),
        referencePitchStabilityCents: _dn(
          json['reference_pitch_stability_cents'],
        ),
        expressionCorrelation: _dn(json['expression_correlation']),
        longToneScore: _dn(json['long_tone_score']),
      );

  Map<String, dynamic> toJson() => {
    'long_reference_notes': longReferenceNotes,
    'long_take_segments': longTakeSegments,
    'vibrato_segments': vibratoSegments,
    'vibrato_fraction': vibratoFraction,
    'vibrato_amount': vibratoAmount,
    'reference_vibrato_amount': referenceVibratoAmount,
    'vibrato_rate_hz': vibratoRateHz,
    'vibrato_extent_cents': vibratoExtentCents,
    'reference_vibrato_fraction': referenceVibratoFraction,
    'pitch_stability_cents': pitchStabilityCents,
    'reference_pitch_stability_cents': referencePitchStabilityCents,
    'expression_correlation': expressionCorrelation,
    'long_tone_score': longToneScore,
  };
}

/// One weighted sub-score. [value] is in `[0, 1]` or null when the component
/// could not be evaluated (it is then excluded from the total).
class SubScore {
  const SubScore({required this.value, required this.weight});

  final double? value;
  final double weight;

  /// `value * weight`, or null when unavailable.
  double? get points => value == null ? null : value! * weight;

  factory SubScore.fromJson(Map<String, dynamic> json) =>
      SubScore(value: _dn(json['value']), weight: _d(json['weight']));

  Map<String, dynamic> toJson() => {
    'value': value,
    'weight': weight,
    'points': points,
  };
}

/// The six sub-scores.
class SubScores {
  const SubScores({
    required this.pitch,
    required this.rhythm,
    required this.stability,
    required this.vibrato,
    required this.expression,
    required this.longTone,
  });

  final SubScore pitch;
  final SubScore rhythm;
  final SubScore stability;
  final SubScore vibrato;
  final SubScore expression;
  final SubScore longTone;

  List<SubScore> get all => [
    pitch,
    rhythm,
    stability,
    vibrato,
    expression,
    longTone,
  ];

  /// `100 * sum(w_i * s_i) / sum(w_i)` over available sub-scores.
  double get total {
    var num = 0.0;
    var den = 0.0;
    for (final s in all) {
      if (s.value == null || s.weight <= 0) continue;
      num += s.value! * s.weight;
      den += s.weight;
    }
    if (den == 0) return 0;
    return (100.0 * num / den).clamp(0.0, 100.0);
  }

  /// Sub-score values on a 0..100 scale keyed by name (null = unavailable).
  Map<String, double?> toFlatJson() => {
    'pitch': _pct(pitch),
    'rhythm': _pct(rhythm),
    'stability': _pct(stability),
    'vibrato': _pct(vibrato),
    'expression': _pct(expression),
    'long_tone': _pct(longTone),
  };

  static double? _pct(SubScore s) => s.value == null ? null : s.value! * 100.0;

  factory SubScores.fromJson(Map<String, dynamic> json) => SubScores(
    pitch: SubScore.fromJson(json['pitch'] as Map<String, dynamic>),
    rhythm: SubScore.fromJson(json['rhythm'] as Map<String, dynamic>),
    stability: SubScore.fromJson(json['stability'] as Map<String, dynamic>),
    vibrato: SubScore.fromJson(json['vibrato'] as Map<String, dynamic>),
    expression: SubScore.fromJson(json['expression'] as Map<String, dynamic>),
    longTone: SubScore.fromJson(json['long_tone'] as Map<String, dynamic>),
  );

  Map<String, dynamic> toJson() => {
    'pitch': pitch.toJson(),
    'rhythm': rhythm.toJson(),
    'stability': stability.toJson(),
    'vibrato': vibrato.toJson(),
    'expression': expression.toJson(),
    'long_tone': longTone.toJson(),
  };
}

/// Rank letters, best first.
const List<String> rankLetters = ['SSS', 'SS', 'S', 'A', 'B', 'C', 'D'];

/// Version of the score scale written to score.json (`scale`). 2 is the
/// DAM-like scale of [damLikeTotal]; files without it hold raw totals.
const int scoreScaleVersion = 2;

/// Maps the raw weighted total (0..100) onto a scale comparable to DAM
/// 精密採点 (national averages around 80, 90 = good, 95+ = very good):
/// `0.55·raw + 45` from raw 20 up, `2.8·raw` below (both 56 at raw 20), so
/// 0 stays 0 for a take that was not sung and 100 stays 100. See
/// docs/SCORING.md, "Score scale".
double damLikeTotal(double raw) {
  final r = raw.clamp(0.0, 100.0);
  return r < 20 ? 2.8 * r : 0.55 * r + 45;
}

/// Monotonic rank mapping on the DAM-like scale:
/// `>= 98 SSS, >= 95 SS, >= 91 S, >= 86 A, >= 78 B, >= 67 C, else D`.
String rankForTotal(double total) {
  if (total >= 98) return 'SSS';
  if (total >= 95) return 'SS';
  if (total >= 91) return 'S';
  if (total >= 86) return 'A';
  if (total >= 78) return 'B';
  if (total >= 67) return 'C';
  return 'D';
}

/// Total, rank and raw total of a score.json map. Files written before the
/// DAM-like scale (no `scale` field) are converted, so old and new takes
/// compare fairly.
({double total, String rank, double raw}) readScoreTotal(Map<String, dynamic> j) {
  final t = (j['total'] as num?)?.toDouble() ?? 0;
  if (j['scale'] == scoreScaleVersion) {
    return (total: t, rank: (j['rank'] as String?) ?? rankForTotal(t), raw: (j['raw_total'] as num?)?.toDouble() ?? t);
  }
  final total = damLikeTotal(t);
  return (total: total, rank: rankForTotal(total), raw: t);
}

/// [j] with total, rank, raw_total and scale on the current scale.
Map<String, dynamic> upgradeScoreJson(Map<String, dynamic> j) {
  final s = readScoreTotal(j);
  return {...j, 'total': s.total, 'rank': s.rank, 'raw_total': s.raw, 'scale': scoreScaleVersion};
}

/// The complete result of [Scorer.score].
class ScoreResult {
  const ScoreResult({
    required this.total,
    required this.rank,
    required this.subScores,
    this.rawTotal,
    required this.shift,
    required this.octaveExactShift,
    required this.frameMetrics,
    required this.noteMetrics,
    required this.technique,
    required this.alignment,
    required this.weights,
    this.hop = 0.016,
    this.rhythm,
  });

  /// Rhythm-game style judgements behind the rhythm sub-score (null when
  /// read back from an older score.json).
  final RhythmResult? rhythm;

  /// Final score in `[0, 100]` on the DAM-like scale ([damLikeTotal]).
  final double total;

  /// The weighted sub-score total before [damLikeTotal].
  final double? rawTotal;

  /// Rank letter (see [rankForTotal]).
  final String rank;
  final SubScores subScores;

  /// Global chroma shift `k` in `0..11` applied to the take (semitones).
  final int shift;

  /// Octave-exact shift in `-24..24` (display only).
  final int octaveExactShift;
  final FrameMetrics frameMetrics;
  final NoteMetrics noteMetrics;
  final TechniqueMetrics technique;
  final AlignmentResult alignment;
  final ScoringWeights weights;

  /// Working frame hop in seconds.
  final double hop;

  factory ScoreResult.fromJson(Map<String, dynamic> json) => _fromJson(json, readScoreTotal(json));

  static ScoreResult _fromJson(Map<String, dynamic> json, ({double total, String rank, double raw}) t) => ScoreResult(
    total: t.total,
    rank: t.rank,
    rawTotal: t.raw,
    subScores: SubScores.fromJson(json['sub_scores'] as Map<String, dynamic>),
    shift: _i(json['shift']),
    octaveExactShift: _i(json['octave_exact_shift']),
    frameMetrics: FrameMetrics.fromJson(
      json['frame_metrics'] as Map<String, dynamic>,
    ),
    noteMetrics: NoteMetrics.fromJson(
      json['note_metrics'] as Map<String, dynamic>,
    ),
    technique: TechniqueMetrics.fromJson(
      json['technique'] as Map<String, dynamic>,
    ),
    alignment: AlignmentResult.fromJson(
      json['alignment'] as Map<String, dynamic>,
    ),
    weights: ScoringWeights.fromJson(json['weights'] as Map<String, dynamic>),
    hop: _d(json['hop'], 0.016),
    rhythm: json['rhythm'] is Map ? RhythmResult.fromJson((json['rhythm'] as Map).cast<String, dynamic>()) : null,
  );

  Map<String, dynamic> toJson() => {
    'total': total,
    'rank': rank,
    'raw_total': ?rawTotal,
    'scale': scoreScaleVersion,
    'sub_scores': subScores.toJson(),
    'sub_scores_flat': subScores.toFlatJson(),
    'shift': shift,
    'octave_exact_shift': octaveExactShift,
    'frame_metrics': frameMetrics.toJson(),
    'note_metrics': noteMetrics.toJson(),
    'technique': technique.toJson(),
    'alignment': alignment.toJson(),
    'weights': weights.toJson(),
    'hop': hop,
    if (rhythm != null) 'rhythm': rhythm!.toJson(),
  };
}
