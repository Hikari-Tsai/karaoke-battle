/// The top-level scoring pipeline.
///
/// ## Pipeline
///
/// 1. Both F0 tracks are converted to semitone tracks (NaN = unvoiced) on a
///    uniform grid with the take's hop (default 16 ms). The reference track
///    is the reference F0 curve when given, else the note pitches sampled on
///    the grid.
/// 2. A global offset is found by cross-correlating the voicing indicators
///    (±`maxOffsetSeconds`).
/// 3. The chroma shift `k` (0..11) maximising Raw Chroma Accuracy on the
///    offset-aligned frames is estimated.
/// 4. The take is aligned to the reference with a Sakoe-Chiba DTW whose
///    ±`bandSeconds` band is centred on the offset diagonal (or with the
///    fixed offset when `alignmentMode == fixedOffset`). Non-diagonal DTW
///    steps carry a gap penalty (`stepPenalty`) so the warp cannot
///    cherry-pick single frames of a poor take; `k` is then re-estimated on
///    the aligned frames (final `k`), and the octave-exact shift (−24..24,
///    display only) is estimated the same way.
/// 5. Frame metrics, note metrics (reference-guided by default: every
///    reference note is evaluated on its own aligned span, see
///    `computeReferenceGuidedNoteMetrics`; or mir_eval-style matching of
///    notes segmented from the take F0 with `NoteSegmentation.fromTakeF0`),
///    technique metrics and the final score are computed. Whenever the
///    reference F0 curve is given, per-frame pitch targets, expected
///    onsets/offsets, the vibrato target and the stability baseline come
///    from the original vocal, so the original vocal itself scores 100.
///
/// ## Final score mapping (all sub-scores in `[0, 1]`, monotonic)
///
/// * pitch       = clamp((RCA − 0.2) / 0.75, 0, 1)
/// * rhythm      = 0.4·F1(onset) + 0.3·F1(onset+pitch+offset) + 0.3·timing,
///   timing = 0.5·clamp(1 − max(0, medOn − 20) / 150, 0, 1)
///          + 0.5·clamp(1 − max(0, medOff − 40) / 200, 0, 1)
///   with medOn/medOff the median |onset| / |offset| error in ms over
///   reference notes that have a take note (timing = 0 without any).
/// * stability   = clamp(1 − max(0, std − refStd) / 50, 0, 1), std = mean
///   over long reference notes (take voiced >= 50 %) of the std in cents of
///   the take pitch after removing the vibrato band, refStd = the same on
///   the reference F0 curve (0 without it); 0 when no long note is
///   analysable in the take; null (excluded) when the reference has no
///   long note.
/// * vibrato     = clamp(amount / target, 0, 1) where amount = mean over
///   long reference notes of the fraction of ~0.5 s analysis windows with
///   vibrato in the take (0..1); target = min(referenceAmount, vibratoTarget)
///   when the reference F0 is given, else vibratoTarget (0.4); null
///   (excluded) when the reference has no long note or the original uses
///   (almost) no vibrato (referenceAmount < 0.25).
/// * expression  = clamp(r / 0.8, 0, 1), r = Pearson correlation of the
///   aligned loudness curves; null when either curve is missing.
/// * long tone   = mean over long reference notes of the fraction of the
///   note where the take is voiced and within 50 cents of the target
///   (reference F0 curve where voiced, else the note pitch); null without
///   long reference notes.
/// * total = 100 · Σ(w_i·s_i) / Σ(w_i) over available sub-scores.
/// * rank: ≥97 SSS, ≥92 SS, ≥85 S, ≥75 A, ≥60 B, ≥40 C, else D.
library;

import 'dart:math' as math;

import 'alignment.dart';
import 'frame_metrics.dart';
import 'models.dart';
import 'note_metrics.dart';
import 'technique.dart';
import 'tracks.dart';

/// Scores a take against a reference. Deterministic and allocation-light.
class Scorer {
  const Scorer._();

  /// Runs the whole pipeline (see the library documentation).
  static ScoreResult score(ScoringInput input) {
    final opt = input.options;
    final hop =
        opt.hopSeconds ?? (input.takeF0.hop > 0 ? input.takeF0.hop : 0.016);
    final refNotes = input.referenceNotes.notes;

    // --- 1. Semitone tracks on the uniform grid ---------------------------
    final takeSemis = f0TrackToGrid(
      input.takeF0,
      hop: hop,
      confidenceThreshold: opt.confidenceThreshold,
    );
    var refEnd = input.referenceNotes.endTime;
    final refF0 = input.referenceF0;
    if (refF0 != null && refF0.length > 0) {
      refEnd = math.max(refEnd, refF0.times[refF0.length - 1]);
    }
    final refLen = gridLength(refEnd, hop);
    final refSemis = (refF0 != null && refF0.length > 0)
        ? f0TrackToGrid(
            refF0,
            hop: hop,
            length: refLen,
            confidenceThreshold: opt.confidenceThreshold,
          )
        : notesToGrid(refNotes, hop: hop, length: refLen);

    // --- 2. Global offset, 3. initial chroma shift ------------------------
    final maxOff = (opt.maxOffsetSeconds / hop).round();
    final offset = estimateVoicingOffsetFrames(
      takeSemis,
      refSemis,
      maxOffsetFrames: maxOff,
    );
    final fixed = alignFixedOffset(
      takeSemis,
      refSemis,
      hop: hop,
      offsetFrames: offset,
    );
    final k0 = estimateChromaShift(
      fixed.alignTakeToRefGrid(takeSemis),
      refSemis,
    );

    // --- 4. Alignment and final shifts ------------------------------------
    final AlignmentResult alignment;
    if (opt.alignmentMode == AlignmentMode.dtw) {
      alignment = alignDtw(
        takeSemis,
        refSemis,
        hop: hop,
        bandFrames: (opt.bandSeconds / hop).round(),
        offsetFrames: offset,
        shift: k0,
        stepPenalty: opt.stepPenalty,
      );
    } else {
      alignment = fixed;
    }
    final alignedTake = alignment.alignTakeToRefGrid(takeSemis);
    final k = estimateChromaShift(alignedTake, refSemis);
    final octaveExact = estimateOctaveExactShift(alignedTake, refSemis);

    // --- 5a. Frame metrics -----------------------------------------------
    final frame = computeFrameMetrics(
      alignedTake,
      refSemis,
      shift: k,
      octaveExactShift: octaveExact,
    );

    // --- 5b. Note metrics -------------------------------------------------
    final hasRefCurve = refF0 != null && refF0.length > 0;
    final curve = hasRefCurve ? refSemis : null;
    final rawTakeNotes = segmentTakeNotes(takeSemis, hop: hop);
    final takeNotes = mapTakeNotes(rawTakeNotes, alignment, k);
    final NoteMetrics notes;
    if (opt.noteSegmentation == NoteSegmentation.referenceGuided) {
      notes = computeReferenceGuidedNoteMetrics(
        refNotes,
        alignedTake,
        curve,
        hop: hop,
        shift: k,
        takeNotes: takeNotes,
      );
    } else {
      notes = computeNoteMetrics(
        refNotes,
        takeNotes,
        alignedTake,
        hop: hop,
        shift: k,
      );
    }

    // --- 5c. Technique ----------------------------------------------------
    final maxGap = (0.08 / hop).floor();
    final takeLong = analyzeLongNotes(
      refNotes,
      bridgeGaps(takeSemis, maxGap),
      hop: hop,
      longNoteSeconds: opt.longNoteSeconds,
      timeMap: alignment.refTimeToTakeTime,
    );
    final refLong = hasRefCurve
        ? analyzeLongNotes(
            refNotes,
            bridgeGaps(refSemis, maxGap),
            hop: hop,
            longNoteSeconds: opt.longNoteSeconds,
          )
        : null;
    final longRefNotes = takeLong.longNotes;
    final longTone = longToneScore(
      refNotes,
      alignedTake,
      hop: hop,
      shift: k,
      refCurve: curve,
      longNoteSeconds: opt.longNoteSeconds,
    );
    double? expression;
    if (input.takeEnergy != null && input.referenceEnergy != null) {
      expression = expressionCorrelation(
        input.takeEnergy!,
        input.referenceEnergy!,
        alignment,
        refSemis,
      );
    }
    final technique = TechniqueMetrics(
      longReferenceNotes: longRefNotes,
      longTakeSegments: takeLong.analysed,
      vibratoSegments: takeLong.withVibrato,
      vibratoFraction: takeLong.fraction,
      vibratoAmount: takeLong.amount,
      referenceVibratoAmount: refLong?.amount,
      vibratoRateHz: takeLong.rates.isEmpty ? null : median(takeLong.rates),
      vibratoExtentCents: takeLong.extents.isEmpty
          ? null
          : median(takeLong.extents),
      referenceVibratoFraction: refLong?.fraction,
      pitchStabilityCents: takeLong.stabilities.isEmpty
          ? null
          : mean(takeLong.stabilities),
      referencePitchStabilityCents:
          (refLong == null || refLong.stabilities.isEmpty)
          ? null
          : mean(refLong.stabilities),
      expressionCorrelation: expression,
      longToneScore: longTone,
    );

    // --- 5d. Sub-scores and total ----------------------------------------
    final w = input.weights;
    final subScores = SubScores(
      pitch: SubScore(
        value: pitchScore(frame.rawChromaAccuracy),
        weight: w.pitch,
      ),
      rhythm: SubScore(value: rhythmScore(notes), weight: w.rhythm),
      stability: SubScore(
        value: longRefNotes == 0
            ? null
            : stabilityScore(
                technique.pitchStabilityCents,
                technique.referencePitchStabilityCents,
              ),
        weight: w.stability,
      ),
      vibrato: SubScore(
        value: longRefNotes == 0
            ? null
            : vibratoScore(
                technique.vibratoAmount,
                technique.referenceVibratoAmount,
                opt.vibratoTarget,
              ),
        weight: w.vibrato,
      ),
      expression: SubScore(
        value: expression == null ? null : expressionScore(expression),
        weight: w.expression,
      ),
      longTone: SubScore(value: longTone, weight: w.longTone),
    );
    final total = subScores.total;
    return ScoreResult(
      total: total,
      rank: rankForTotal(total),
      subScores: subScores,
      shift: k,
      octaveExactShift: octaveExact,
      frameMetrics: frame,
      noteMetrics: notes,
      technique: technique,
      alignment: alignment,
      weights: w,
      hop: hop,
    );
  }

  /// `clamp((rca − 0.2) / 0.75, 0, 1)`.
  static double pitchScore(double rca) => ((rca - 0.2) / 0.75).clamp(0.0, 1.0);

  /// `0.4·F1(onset) + 0.3·F1(onset+pitch+offset) + 0.3·timing`.
  static double rhythmScore(NoteMetrics n) {
    var timing = 0.0;
    if (n.medianAbsOnsetErrorMs != null) {
      final on = (1 - math.max(0.0, n.medianAbsOnsetErrorMs! - 20) / 150).clamp(
        0.0,
        1.0,
      );
      final off =
          (1 - math.max(0.0, (n.medianAbsOffsetErrorMs ?? 1e9) - 40) / 200)
              .clamp(0.0, 1.0);
      timing = 0.5 * on + 0.5 * off;
    }
    return (0.4 * n.onset.f1 + 0.3 * n.onsetPitchOffset.f1 + 0.3 * timing)
        .clamp(0.0, 1.0);
  }

  /// `clamp(1 − max(0, std − refStd) / 50, 0, 1)` with `refStd` the
  /// reference's own stability (0 without a reference F0 curve); 0 when
  /// [stdCents] is null (no analysable long note in the take).
  static double stabilityScore(double? stdCents, [double? refStdCents]) =>
      stdCents == null
      ? 0.0
      : (1 - math.max(0.0, stdCents - (refStdCents ?? 0.0)) / 50).clamp(
          0.0,
          1.0,
        );

  /// Reference vibrato amounts below this are treated as "the song does not
  /// call for vibrato" (full marks): judging a singer against one marginal
  /// vibrato note of the original would be noise.
  static const double minReferenceVibratoAmount = 0.25;

  /// `clamp(amount / target, 0, 1)` with
  /// `target = min(referenceAmount, targetAmount)`, or `targetAmount` without
  /// a reference curve. Returns null (component excluded) when the reference
  /// amount is below [minReferenceVibratoAmount].
  static double? vibratoScore(
    double amount,
    double? referenceAmount,
    double targetAmount,
  ) {
    final double target;
    if (referenceAmount == null) {
      target = targetAmount;
    } else if (referenceAmount < minReferenceVibratoAmount) {
      target = 0.0;
    } else {
      target = math.min(referenceAmount, targetAmount);
    }
    if (target <= 0) return null;
    return (amount / target).clamp(0.0, 1.0);
  }

  /// `clamp(r / 0.8, 0, 1)`.
  static double expressionScore(double r) => (r / 0.8).clamp(0.0, 1.0);
}
