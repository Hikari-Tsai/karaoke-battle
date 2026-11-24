/// The top-level scoring pipeline.
///
/// ## Pipeline
///
/// 1. Both F0 tracks are converted to semitone tracks (NaN = unvoiced) on a
///    uniform grid with the take's hop (default 16 ms). The reference track
///    is the reference F0 curve when given (with the note pitches accepted as
///    an alternative target per frame), else the note pitches sampled on
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
/// * pitch       = clamp((RCA − 0.15) / 0.6, 0, 1)
/// * rhythm      = mean per-note credit of rhythm-game style judgements
///   (PERFECT / GREAT / GOOD / MISS on onset 70 % and offset 30 %, windows
///   scaled by tempo), measured on the globally offset take; see rhythm.dart.
/// * stability   = clamp(1 − max(0, std − refStd) / 80, 0, 1), std = mean
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
/// * expression  = clamp(r / 0.6, 0, 1), r = Pearson correlation of the
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
import 'rhythm.dart';
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
    var takeSemis = f0TrackToGrid(
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
    final noteSemis = notesToGrid(refNotes, hop: hop, length: refLen);
    final refSemis = (refF0 != null && refF0.length > 0)
        ? f0TrackToGrid(
            refF0,
            hop: hop,
            length: refLen,
            confidenceThreshold: opt.confidenceThreshold,
          )
        : noteSemis;

    // --- 2. Global offset, 3. initial chroma shift ------------------------
    final maxOff = (opt.maxOffsetSeconds / hop).round();
    var offset = estimateVoicingOffsetFrames(
      takeSemis,
      refSemis,
      maxOffsetFrames: maxOff,
    );
    // Notes fixed by the Tuning Wand: sung exactly as the reference. The
    // take as sung is kept, so what the wand does not touch (the loudness,
    // the other long notes) is judged on it as before.
    final sungSemis = takeSemis;
    final sungOffset = offset;
    final perfect = perfectNoteIndices(refNotes, opt.perfectSpans);
    if (opt.perfectSpans.isNotEmpty) {
      takeSemis = applyPerfectSpans(takeSemis, refSemis, opt.perfectSpans, hop: hop, offsetFrames: offset, calibratedTiming: opt.calibratedTiming, alt: noteSemis);
      offset = estimateVoicingOffsetFrames(takeSemis, refSemis, maxOffsetFrames: maxOff);
    }
    final fixed = alignFixedOffset(
      takeSemis,
      refSemis,
      hop: hop,
      offsetFrames: offset,
    );
    final pitchTol = 0.5 * opt.lenience;
    final k0 = estimateChromaShift(
      fixed.alignTakeToRefGrid(takeSemis),
      refSemis,
      tolerance: pitchTol,
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
    final k = estimateChromaShift(alignedTake, refSemis, tolerance: pitchTol);
    final octaveExact = estimateOctaveExactShift(alignedTake, refSemis);

    // --- 5a. Frame metrics -----------------------------------------------
    // With a reference curve the note grid is a second accepted target, so a
    // take that holds the plain note through the original's scoops is correct.
    final frame = computeFrameMetrics(
      alignedTake,
      refSemis,
      shift: k,
      octaveExactShift: octaveExact,
      tolerance: pitchTol,
      alt: identical(refSemis, noteSemis) ? null : noteSemis,
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
        pitchTolerance: pitchTol,
      );
    } else {
      notes = computeNoteMetrics(
        refNotes,
        takeNotes,
        alignedTake,
        hop: hop,
        shift: k,
        pitchTolerance: pitchTol,
      );
    }

    // --- 5b'. Rhythm judgements --------------------------------------------
    // Timing is judged on the take aligned by a single global offset (the
    // latency / late start of the whole take), not on the DTW path, which
    // would absorb per-note timing errors. The search window covers the
    // GOOD window.
    final windows = RhythmWindows.forTempo(opt.tempoBpm).widened(opt.lenience);
    // With a measured latency the recorded timing is trusted (offset 0) so
    // whole-take rushing / dragging counts; a large estimated offset means
    // the calibration does not fit (e.g. another device) -> use the estimate.
    final trustClock = opt.calibratedTiming && (offset * hop).abs() <= rhythmClockToleranceSeconds;
    final timingAlign = trustClock ? alignFixedOffset(takeSemis, refSemis, hop: hop, offsetFrames: 0) : fixed;
    final fixedTake = timingAlign.alignTakeToRefGrid(takeSemis);
    final timingNotes = computeReferenceGuidedNoteMetrics(
      refNotes,
      fixedTake,
      curve,
      hop: hop,
      shift: k,
      extensionSeconds: windows.good + 0.02,
      pitchTolerance: pitchTol,
    );
    final rhythm = judgeRhythm(refNotes, timingNotes, windows, clockTrusted: trustClock, perfect: perfect);

    // With the wand: the alignment of the take as sung, for what the wand
    // leaves as it was.
    AlignmentResult? sungAlignment;
    if (perfect.isNotEmpty) {
      final f = alignFixedOffset(sungSemis, refSemis, hop: hop, offsetFrames: sungOffset);
      sungAlignment = opt.alignmentMode == AlignmentMode.dtw
          ? alignDtw(
              sungSemis,
              refSemis,
              hop: hop,
              bandFrames: (opt.bandSeconds / hop).round(),
              offsetFrames: sungOffset,
              shift: estimateChromaShift(f.alignTakeToRefGrid(sungSemis), refSemis, tolerance: pitchTol),
              stepPenalty: opt.stepPenalty,
            )
          : f;
    }

    // --- 5c. Technique ----------------------------------------------------
    final maxGap = (0.08 / hop).floor();
    var takeLong = analyzeLongNotes(
      refNotes,
      bridgeGaps(takeSemis, maxGap),
      hop: hop,
      longNoteSeconds: opt.longNoteSeconds,
      timeMap: alignment.refTimeToTakeTime,
    );
    if (sungAlignment != null) {
      // The long notes as sung; a tuned one keeps the steadier (and the
      // more vibrato) of how it was sung and of the original.
      final sung = analyzeLongNotes(
        refNotes,
        bridgeGaps(sungSemis, maxGap),
        hop: hop,
        longNoteSeconds: opt.longNoteSeconds,
        timeMap: sungAlignment.refTimeToTakeTime,
      );
      takeLong = bestOfLongNotes(sung, takeLong, perfect, refNotes, opt.longNoteSeconds);
    }
    final refLong = hasRefCurve
        ? analyzeLongNotes(
            refNotes,
            bridgeGaps(refSemis, maxGap),
            hop: hop,
            longNoteSeconds: opt.longNoteSeconds,
          )
        : null;
    final longRefNotes = takeLong.longNotes;
    final refStability = <int, double?>{
      for (final d in refLong?.details ?? const <LongNoteDetail>[])
        d.index: d.stabilityCents,
    };
    final longTone = longToneScore(
      refNotes,
      alignedTake,
      hop: hop,
      shift: k,
      refCurve: curve,
      longNoteSeconds: opt.longNoteSeconds,
      toleranceSemitones: pitchTol,
    );
    double? expression;
    if (input.takeEnergy != null && input.referenceEnergy != null) {
      // The wand does not change the loudness: judged as sung.
      expression = expressionCorrelation(
        input.takeEnergy!,
        input.referenceEnergy!,
        sungAlignment ?? alignment,
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
      longNotes: [
        for (final d in takeLong.details)
          d.withReference(refStability[d.index]),
      ],
    );

    // --- 5d. Sub-scores and total ----------------------------------------
    final w = input.weights;
    var subScores = SubScores(
      pitch: SubScore(
        value: pitchScore(frame.rawChromaAccuracy),
        weight: w.pitch,
      ),
      rhythm: SubScore(value: rhythm.score, weight: w.rhythm),
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
      longTone: SubScore(value: longTone == null ? null : longToneSubScore(longTone), weight: w.longTone),
    );
    // Every note tuned with the wand: full marks, also for what is judged on
    // the song as a whole (the loudness contour, the overall steadiness).
    final allTuned = refNotes.isNotEmpty && perfect.length >= refNotes.length;
    if (allTuned) {
      SubScore full(SubScore x) => SubScore(value: x.value == null ? null : 1.0, weight: x.weight);
      subScores = SubScores(
        pitch: full(subScores.pitch),
        rhythm: full(subScores.rhythm),
        stability: full(subScores.stability),
        vibrato: full(subScores.vibrato),
        expression: full(subScores.expression),
        longTone: full(subScores.longTone),
      );
    }
    final raw = subScores.total;
    final total = allTuned ? 100.0 : scaledTotal(raw);
    return ScoreResult(
      total: total,
      rank: rankForTotal(total),
      rawTotal: raw,
      subScores: subScores,
      shift: k,
      octaveExactShift: octaveExact,
      frameMetrics: frame,
      noteMetrics: notes,
      technique: technique,
      alignment: alignment,
      weights: w,
      hop: hop,
      rhythm: rhythm,
    );
  }

  /// The take grid with the frames of each [spans] note replaced by the
  /// reference (unvoiced where it is), in the singer's octave, at the time
  /// the rhythm judgement expects it: the track clock when the latency is
  /// calibrated and the take sits within the tolerance, else shifted by the
  /// take's global offset [offsetFrames].
  ///
  /// Where the reference is silent inside the note (the original's pitch
  /// was not caught there), the note's own pitch ([alt]) fills in, so even a
  /// note the singer left out is sung all through.
  static List<double> applyPerfectSpans(
    List<double> take,
    List<double> ref,
    List<(double, double)> spans, {
    required double hop,
    required int offsetFrames,
    required bool calibratedTiming,
    List<double>? alt,
  }) {
    final fixed = alignFixedOffset(take, ref, hop: hop, offsetFrames: offsetFrames);
    // take ~ ref - octave (see estimateOctaveExactShift)
    final octave = estimateOctaveExactShift(fixed.alignTakeToRefGrid(take), ref);
    final trust = calibratedTiming && (offsetFrames * hop).abs() <= rhythmClockToleranceSeconds;
    final shift = trust ? 0 : offsetFrames;
    final out = List<double>.of(take, growable: true);
    for (final (on, off) in spans) {
      final j0 = math.max(0, (on / hop).round()), j1 = math.min(ref.length, (off / hop).round());
      for (var j = j0; j < j1; j++) {
        final t = j + shift;
        if (t < 0) continue;
        while (out.length <= t) {
          out.add(double.nan);
        }
        final target = !ref[j].isNaN ? ref[j] : (alt != null && j < alt.length ? alt[j] : double.nan);
        out[t] = target.isNaN ? double.nan : target - octave;
      }
    }
    return out;
  }

  /// Long notes with the wand: [sung] (the take as sung) for every long note,
  /// except that a tuned one ([perfect]) keeps the steadier stability and the
  /// larger vibrato amount of [sung] and [tuned] (so a wand never costs).
  static LongNoteAnalysis bestOfLongNotes(LongNoteAnalysis sung, LongNoteAnalysis tuned, Set<int> perfect, List<ReferenceNote> refNotes, double longNoteSeconds) {
    final longIdx = [for (var i = 0; i < refNotes.length; i++) if (refNotes[i].duration >= longNoteSeconds) i];
    final amounts = [
      for (var k = 0; k < sung.amounts.length; k++)
        k < longIdx.length && perfect.contains(longIdx[k]) && k < tuned.amounts.length ? math.max(sung.amounts[k], tuned.amounts[k]) : sung.amounts[k],
    ];
    final sungBy = {for (final d in sung.details) d.index: d};
    final tunedBy = {for (final d in tuned.details) d.index: d};
    final details = <LongNoteDetail>[];
    for (final i in longIdx) {
      final a = sungBy[i], b = tunedBy[i];
      if (!perfect.contains(i)) {
        if (a != null) details.add(a);
        continue;
      }
      final sa = a?.stabilityCents, sb = b?.stabilityCents;
      final best = sa == null ? b : (sb == null ? a : (sa <= sb ? a : b));
      if (best != null) details.add(LongNoteDetail(index: i, stabilityCents: best.stabilityCents, vibrato: (a?.vibrato ?? false) || (b?.vibrato ?? false)));
    }
    final stabilities = [for (final d in details) ?d.stabilityCents];
    return LongNoteAnalysis(
      longNotes: sung.longNotes,
      analysed: details.length,
      withVibrato: details.where((d) => d.vibrato).length,
      rates: sung.rates,
      extents: sung.extents,
      stabilities: stabilities,
      amounts: amounts,
      details: details,
    );
  }

  /// The indices of [notes] made perfect: those starting where one of
  /// [spans] does (to the millisecond).
  static Set<int> perfectNoteIndices(List<ReferenceNote> notes, List<(double, double)> spans) {
    if (spans.isEmpty) return const {};
    return {
      for (var i = 0; i < notes.length; i++)
        if (spans.any((s) => (s.$1 - notes[i].onset).abs() < 0.002)) i,
    };
  }

  /// Largest estimated global offset still blamed on the singer when the
  /// latency is calibrated (beyond it the calibration is assumed stale).
  static const double rhythmClockToleranceSeconds = 0.15;

  /// `clamp((rca − 0.15) / 0.6, 0, 1)`: full marks from 75% of the sung
  /// frames in tune (lenient on purpose, see docs/SCORING.md 5).
  static double pitchScore(double rca) => ((rca - 0.15) / 0.6).clamp(0.0, 1.0);

  /// `clamp(achieved / 0.8, 0, 1)`: holding long notes for 80% of their
  /// length is enough.
  static double longToneSubScore(double achieved) => (achieved / 0.8).clamp(0.0, 1.0);

  /// Former rhythm formula (F1 + median timing), kept for comparison:
  /// `0.4·F1(onset) + 0.3·F1(onset+pitch+offset) + 0.3·timing`.
  /// The rhythm sub-score now comes from [judgeRhythm].
  static double legacyRhythmScore(NoteMetrics n) {
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

  /// `clamp(1 − max(0, std − refStd) / 80, 0, 1)` with `refStd` the
  /// reference's own stability (0 without a reference F0 curve); 0 when
  /// [stdCents] is null (no analysable long note in the take).
  static double stabilityScore(double? stdCents, [double? refStdCents]) =>
      stdCents == null
      ? 0.0
      : (1 - math.max(0.0, stdCents - (refStdCents ?? 0.0)) / 80).clamp(
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

  /// `clamp(r / 0.6, 0, 1)`.
  static double expressionScore(double r) => (r / 0.6).clamp(0.0, 1.0);
}
