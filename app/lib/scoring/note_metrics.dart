/// Take-note segmentation and note-level transcription metrics
/// (mir_eval `transcription` definitions).
library;

import 'dart:math' as math;

import 'alignment.dart';
import 'models.dart';
import 'tracks.dart';

/// Segments a take semitone track (uniform grid, NaN = unvoiced) into notes.
///
/// Steps:
/// 1. voicing gaps of at most [gapSeconds] are bridged (longer gaps split);
/// 2. the track is median-filtered with [medianWindow] frames;
/// 3. inside each voiced run, a new note starts at frame `t` when all of the
///    next `ceil(jumpSustainSeconds / hop)` frames deviate by more than
///    [jumpSemitones] from the median of the previous [levelFrames] frames
///    of the current note;
/// 4. notes shorter than [minNoteSeconds] are dropped.
///
/// Returned notes have `pitch` = median semitone of the segment (unshifted)
/// and `refOnset`/`refOffset` equal to the take onset/offset; the caller maps
/// them through the alignment (see [mapTakeNotes]).
List<TakeNote> segmentTakeNotes(
  List<double> semis, {
  required double hop,
  double gapSeconds = 0.08,
  double jumpSemitones = 0.8,
  double jumpSustainSeconds = 0.06,
  double minNoteSeconds = 0.05,
  int medianWindow = 5,
  int levelFrames = 6,
}) {
  final maxGap = (gapSeconds / hop).floor();
  final x = medianFilter(bridgeGaps(semis, maxGap), medianWindow);
  final n = x.length;
  final jumpFrames = math.max(1, (jumpSustainSeconds / hop).ceil());
  final minFrames = math.max(1, (minNoteSeconds / hop).round());
  final notes = <TakeNote>[];

  void emit(int s, int e) {
    if (e - s < minFrames) return;
    final pitch = median(x.sublist(s, e));
    notes.add(
      TakeNote(
        onset: s * hop,
        offset: e * hop,
        pitch: pitch,
        refOnset: s * hop,
        refOffset: e * hop,
        startFrame: s,
        endFrame: e,
      ),
    );
  }

  var i = 0;
  while (i < n) {
    if (x[i].isNaN) {
      i++;
      continue;
    }
    var e = i;
    while (e < n && !x[e].isNaN) {
      e++;
    }
    var segStart = i;
    var t = i + 1;
    while (t < e) {
      if (e - t >= jumpFrames) {
        final level = median(x.sublist(math.max(segStart, t - levelFrames), t));
        var sustained = true;
        for (var q = t; q < t + jumpFrames; q++) {
          if ((x[q] - level).abs() <= jumpSemitones) {
            sustained = false;
            break;
          }
        }
        if (sustained) {
          emit(segStart, t);
          segStart = t;
        }
      }
      t++;
    }
    emit(segStart, e);
    i = e;
  }
  return notes;
}

/// Applies the chroma [shift] to the note pitches and maps onsets/offsets
/// into the reference timeline through [alignment].
List<TakeNote> mapTakeNotes(
  List<TakeNote> notes,
  AlignmentResult alignment,
  int shift,
) {
  return notes
      .map(
        (n) => n.copyWith(
          pitch: n.pitch + shift,
          refOnset: alignment.takeTimeToRefTime(n.onset),
          refOffset: alignment.takeTimeToRefTime(n.offset),
        ),
      )
      .toList(growable: false);
}

/// Maximum bipartite matching between reference notes and take notes.
///
/// A pair is a candidate when `|refOnset - onset| <= onsetTolerance`, when
/// [pitchTolerance] is given also `chromaDistance <= pitchTolerance`, and
/// when [checkOffset] also
/// `|refOffset - offset| <= max(offsetMinTolerance, offsetRatio * refDuration)`.
/// Returns, per reference note, the index of the matched take note or -1.
List<int> matchNotes(
  List<ReferenceNote> ref,
  List<TakeNote> take, {
  double onsetTolerance = 0.05,
  double? pitchTolerance,
  bool checkOffset = false,
  double offsetRatio = 0.2,
  double offsetMinTolerance = 0.05,
}) {
  const eps = 1e-9;
  final nr = ref.length;
  final nt = take.length;
  // Take notes sorted by reference-timeline onset for the sliding window.
  final order = List<int>.generate(nt, (i) => i)
    ..sort((a, b) => take[a].refOnset.compareTo(take[b].refOnset));
  final cand = List<List<int>>.generate(nr, (_) => <int>[]);
  var lo = 0;
  for (var r = 0; r < nr; r++) {
    final rn = ref[r];
    while (lo < nt &&
        take[order[lo]].refOnset < rn.onset - onsetTolerance - eps) {
      lo++;
    }
    for (var p = lo; p < nt; p++) {
      final t = take[order[p]];
      if (t.refOnset > rn.onset + onsetTolerance + eps) break;
      if (pitchTolerance != null &&
          chromaDistance(t.pitch, rn.pitch) > pitchTolerance + eps) {
        continue;
      }
      if (checkOffset) {
        final tol = math.max(offsetMinTolerance, offsetRatio * rn.duration);
        if ((t.refOffset - rn.offset).abs() > tol + eps) continue;
      }
      cand[r].add(order[p]);
    }
  }
  final matchTake = List<int>.filled(nt, -1);
  final matchRef = List<int>.filled(nr, -1);
  late List<bool> visited;
  bool augment(int r) {
    for (final t in cand[r]) {
      if (visited[t]) continue;
      visited[t] = true;
      if (matchTake[t] < 0 || augment(matchTake[t])) {
        matchTake[t] = r;
        matchRef[r] = t;
        return true;
      }
    }
    return false;
  }

  for (var r = 0; r < nr; r++) {
    if (cand[r].isEmpty) continue;
    visited = List<bool>.filled(nt, false);
    augment(r);
  }
  return matchRef;
}

/// Computes precision/recall/F1 for the three matching criteria and the
/// per-reference-note report.
///
/// [takeNotes] must already be mapped to the reference timeline and shifted
/// (see [mapTakeNotes]); [alignedTake] is the take semitone track on the
/// reference grid (unshifted) used for the per-note cents deviation.
NoteMetrics computeNoteMetrics(
  List<ReferenceNote> refNotes,
  List<TakeNote> takeNotes,
  List<double> alignedTake, {
  required double hop,
  required int shift,
  double onsetTolerance = 0.05,
  double pitchTolerance = 0.5,
  double offsetRatio = 0.2,
  double offsetMinTolerance = 0.05,
}) {
  final mOnset = matchNotes(
    refNotes,
    takeNotes,
    onsetTolerance: onsetTolerance,
  );
  final mPitch = matchNotes(
    refNotes,
    takeNotes,
    onsetTolerance: onsetTolerance,
    pitchTolerance: pitchTolerance,
  );
  final mFull = matchNotes(
    refNotes,
    takeNotes,
    onsetTolerance: onsetTolerance,
    pitchTolerance: pitchTolerance,
    checkOffset: true,
    offsetRatio: offsetRatio,
    offsetMinTolerance: offsetMinTolerance,
  );
  int count(List<int> m) => m.where((t) => t >= 0).length;
  PrecisionRecallF1 prf(List<int> m) => PrecisionRecallF1.fromCounts(
    matches: count(m),
    estimated: takeNotes.length,
    reference: refNotes.length,
  );

  final reports = <NoteReport>[];
  final absOnset = <double>[];
  final absOffset = <double>[];
  final gridLen = alignedTake.length;
  for (var r = 0; r < refNotes.length; r++) {
    final rn = refNotes[r];
    // Take note used for the error figures.
    var tIdx = mPitch[r];
    if (tIdx < 0) {
      var bestIoU = 0.0;
      for (var t = 0; t < takeNotes.length; t++) {
        final iou = _iou(rn, takeNotes[t]);
        if (iou > bestIoU) {
          bestIoU = iou;
          tIdx = t;
        }
      }
    }
    double? onsetErr;
    double? offsetErr;
    var iou = 0.0;
    if (tIdx >= 0) {
      final tn = takeNotes[tIdx];
      onsetErr = (tn.refOnset - rn.onset) * 1000.0;
      offsetErr = (tn.refOffset - rn.offset) * 1000.0;
      iou = _iou(rn, tn);
      absOnset.add(onsetErr.abs());
      absOffset.add(offsetErr.abs());
    }
    // Cents deviation over the note span on the aligned grid.
    final s = (rn.onset / hop).ceil().clamp(0, gridLen);
    final e = math.max(s + 1, (rn.offset / hop).ceil()).clamp(0, gridLen);
    final cents = <double>[];
    for (var g = s; g < e; g++) {
      final v = alignedTake[g];
      if (v.isNaN) continue;
      cents.add(chromaDelta(v + shift, rn.pitch) * 100.0);
    }
    final span = e - s;
    reports.add(
      NoteReport(
        index: r,
        matchedOnset: mOnset[r] >= 0,
        matched: mPitch[r] >= 0,
        matchedOffset: mFull[r] >= 0,
        takeNoteIndex: tIdx >= 0 ? tIdx : null,
        centsDeviation: cents.isEmpty ? null : median(cents),
        onsetErrorMs: onsetErr,
        offsetErrorMs: offsetErr,
        overlapIoU: iou,
        voicedFraction: span <= 0 ? 0.0 : cents.length / span,
      ),
    );
  }
  return NoteMetrics(
    onset: prf(mOnset),
    onsetPitch: prf(mPitch),
    onsetPitchOffset: prf(mFull),
    perNote: reports,
    takeNotes: takeNotes,
    segmentation: NoteSegmentation.fromTakeF0,
    medianAbsOnsetErrorMs: absOnset.isEmpty ? null : median(absOnset),
    medianAbsOffsetErrorMs: absOffset.isEmpty ? null : median(absOffset),
  );
}

double _iou(ReferenceNote r, TakeNote t) =>
    _spanIoU(r.onset, r.offset, t.refOnset, t.refOffset);

double _spanIoU(double a0, double a1, double b0, double b1) {
  final inter = math.min(a1, b1) - math.max(a0, b0);
  if (inter <= 0) return 0.0;
  final union = math.max(a1, b1) - math.min(a0, b0);
  return union <= 0 ? 0.0 : inter / union;
}

/// A run of conforming frames `[start, end)` on the reference grid.
class ConformingRun {
  const ConformingRun(this.start, this.end);
  final int start;
  final int end;
}

/// Finds, inside the window `[ws, we)`, the run of frames of [track] that
/// are voiced and within [tolerance] semitones (chroma-wise, after [shift])
/// of the target, bridging non-conforming gaps of at most [bridgeFrames],
/// and returns the run with the largest overlap with the note span `[s, e)`
/// (null when no run overlaps it). The target of a frame inside the span is
/// [curve] where voiced (the reference F0), else [pitch]; outside the span
/// it is always [pitch].
ConformingRun? findConformingRun(
  List<double> track,
  int shift,
  double pitch,
  List<double>? curve,
  int s,
  int e,
  int ws,
  int we, {
  double tolerance = 0.5,
  int bridgeFrames = 3,
}) {
  if (we <= ws) return null;
  final n = we - ws;
  final conform = List<bool>.filled(n, false);
  for (var g = ws; g < we; g++) {
    final v = track[g];
    if (v.isNaN) continue;
    // Inside the note span the take may follow either the reference curve
    // (ornaments, scoops) or the plain note pitch; outside the span only the
    // note pitch continues, so a neighbouring note never counts as this one.
    final inSpan = g >= s && g < e;
    var ok = chromaDistance(v + shift, pitch) <= tolerance;
    if (!ok && inSpan && curve != null && !curve[g].isNaN) {
      ok = chromaDistance(v + shift, curve[g]) <= tolerance;
    }
    conform[g - ws] = ok;
  }
  // Bridge short non-conforming gaps between conforming frames.
  var i = 0;
  while (i < n) {
    if (conform[i]) {
      i++;
      continue;
    }
    var j = i;
    while (j < n && !conform[j]) {
      j++;
    }
    if (i > 0 && j < n && j - i <= bridgeFrames) {
      for (var g = i; g < j; g++) {
        conform[g] = true;
      }
    }
    i = j;
  }
  ConformingRun? best;
  var bestOverlap = 0;
  i = 0;
  while (i < n) {
    if (!conform[i]) {
      i++;
      continue;
    }
    var j = i;
    while (j < n && conform[j]) {
      j++;
    }
    final a = ws + i;
    final b = ws + j;
    final int overlap = math.min(b, e) - math.max(a, s);
    if (overlap > bestOverlap) {
      bestOverlap = overlap;
      best = ConformingRun(a, b);
    }
    i = j;
  }
  return best;
}

/// Reference-guided note metrics (the default [NoteSegmentation]).
///
/// Every reference note is evaluated on its own span `[s, e)` of the
/// reference grid using the aligned take:
/// * conforming frame = take voiced and within [pitchTolerance] (chroma-wise,
///   after [shift]) of the reference F0 curve or of the note pitch (either
///   is accepted, so holding the plain note through the original's scoop or
///   slide is correct; without a curve only the note pitch applies);
/// * `matched` (pitch) = conforming frames cover at least [coverageThreshold]
///   of the span;
/// * the sung onset/offset are the bounds of the conforming run (gaps of up
///   to 3 frames bridged) with the largest overlap with the span, searched in
///   `[onset - extensionSeconds, offset + extensionSeconds]` clipped to the
///   neighbouring notes' spans (the window only extends into rests);
/// * the expected onset/offset are measured the same way on the reference
///   F0 curve when [refCurve] is given (so the original vocal itself scores
///   perfectly), else they are the note onset/offset;
/// * `matchedOnset` = |onset error| <= [onsetTolerance];
///   `matchedOffset` = onset + pitch + |offset error| <=
///   `max(offsetMinTolerance, offsetRatio * duration)`.
///
/// With [refCurve], coverage and voicing are measured over the frames where
/// the reference itself is voiced (a note without any is not `evaluable`
/// and is excluded from P/R/F1), so the original vocal scores perfectly.
///
/// Precision uses as the estimated-note count the reference notes with a
/// conforming run or at least half of the span voiced (notes sung, right or
/// wrong) plus [NoteMetrics.falsePositives]: voiced runs of at least
/// [minNoteSeconds] lying outside every note span (± [onsetTolerance]) and,
/// with [refCurve], outside the reference's own voiced frames.
NoteMetrics computeReferenceGuidedNoteMetrics(
  List<ReferenceNote> refNotes,
  List<double> alignedTake,
  List<double>? refCurve, {
  required double hop,
  required int shift,
  List<TakeNote> takeNotes = const [],
  double onsetTolerance = 0.05,
  double pitchTolerance = 0.5,
  double offsetRatio = 0.2,
  double offsetMinTolerance = 0.05,
  double extensionSeconds = 0.1,
  double coverageThreshold = 0.5,
  double minNoteSeconds = 0.05,
}) {
  const eps = 1e-9;
  final len = alignedTake.length;
  final n = refNotes.length;
  final ext = (extensionSeconds / hop).round();
  final tolFrames = (onsetTolerance / hop).round();
  final minFrames = math.max(1, (minNoteSeconds / hop).round());
  final covered = List<bool>.filled(len, false);
  final reports = <NoteReport>[];
  final absOnset = <double>[];
  final absOffset = <double>[];
  var estimated = 0;
  var evaluable = 0;
  var mOnset = 0;
  var mPitch = 0;
  var mFull = 0;
  int frame(double t) => (t / hop).ceil().clamp(0, len);
  if (refCurve != null) {
    for (var g = 0; g < len; g++) {
      if (!refCurve[g].isNaN) covered[g] = true;
    }
  }

  for (var r = 0; r < n; r++) {
    final rn = refNotes[r];
    final s = frame(rn.onset);
    final e = math.max(s + 1, frame(rn.offset)).clamp(0, len);
    for (
      var g = math.max(0, s - tolFrames);
      g < math.min(len, e + tolFrames);
      g++
    ) {
      covered[g] = true;
    }
    // The search window extends into rests only, never into a neighbouring
    // note's span: a slide between two notes belongs to the transition, and
    // an early entry into note B shows up as a short offset on note A.
    var ws = math.max(0, s - ext);
    var we = math.min(len, e + ext);
    if (r > 0) ws = math.max(ws, frame(refNotes[r - 1].offset));
    if (r + 1 < n) we = math.min(we, frame(refNotes[r + 1].onset));
    final takeRun = findConformingRun(
      alignedTake,
      shift,
      rn.pitch,
      refCurve,
      s,
      e,
      ws,
      we,
      tolerance: pitchTolerance,
    );
    var expectedOnset = rn.onset;
    var expectedOffset = rn.offset;
    if (refCurve != null) {
      final refRun = findConformingRun(
        refCurve,
        0,
        rn.pitch,
        refCurve,
        s,
        e,
        ws,
        we,
        tolerance: pitchTolerance,
      );
      if (refRun != null) {
        expectedOnset = refRun.start * hop;
        expectedOffset = refRun.end * hop;
      }
    }
    var conformCount = 0;
    var voicedCount = 0;
    var span = 0;
    final cents = <double>[];
    for (var g = s; g < e; g++) {
      if (refCurve != null && refCurve[g].isNaN) {
        continue; // only reference-voiced frames
      }
      span++;
      final v = alignedTake[g];
      if (v.isNaN) continue;
      voicedCount++;
      // Deviation from the closest accepted target (curve or note pitch).
      var d = chromaDelta(v + shift, rn.pitch);
      if (refCurve != null) {
        final dc = chromaDelta(v + shift, refCurve[g]);
        if (dc.abs() < d.abs()) d = dc;
      }
      cents.add(d * 100.0);
      if (d.abs() <= pitchTolerance) conformCount++;
    }
    final isEvaluable = span > 0;
    final coverage = span <= 0 ? 0.0 : conformCount / span;
    final voicedFraction = span <= 0 ? 0.0 : voicedCount / span;
    double? onsetErr;
    double? offsetErr;
    var iou = 0.0;
    if (takeRun != null) {
      onsetErr = (takeRun.start * hop - expectedOnset) * 1000.0;
      offsetErr = (takeRun.end * hop - expectedOffset) * 1000.0;
      iou = _spanIoU(
        expectedOnset,
        expectedOffset,
        takeRun.start * hop,
        takeRun.end * hop,
      );
      absOnset.add(onsetErr.abs());
      absOffset.add(offsetErr.abs());
    }
    final matchedOnset =
        onsetErr != null && onsetErr.abs() <= onsetTolerance * 1000 + eps;
    final matched = coverage >= coverageThreshold;
    final offTol =
        math.max(offsetMinTolerance, offsetRatio * rn.duration) * 1000;
    final matchedOffset =
        matchedOnset &&
        matched &&
        offsetErr != null &&
        offsetErr.abs() <= offTol + eps;
    if (isEvaluable) {
      evaluable++;
      if (takeRun != null || voicedFraction >= 0.5) estimated++;
      if (matchedOnset) mOnset++;
      if (matchedOnset && matched) mPitch++;
      if (matchedOffset) mFull++;
    }
    int? takeIdx;
    var bestIoU = 0.0;
    for (var t = 0; t < takeNotes.length; t++) {
      final v = _iou(rn, takeNotes[t]);
      if (v > bestIoU) {
        bestIoU = v;
        takeIdx = t;
      }
    }
    reports.add(
      NoteReport(
        index: r,
        matchedOnset: matchedOnset,
        matched: matched,
        matchedOffset: matchedOffset,
        takeNoteIndex: takeIdx,
        centsDeviation: cents.isEmpty ? null : median(cents),
        onsetErrorMs: onsetErr,
        offsetErrorMs: offsetErr,
        overlapIoU: iou,
        voicedFraction: voicedFraction,
        pitchCoverage: coverage,
        evaluable: isEvaluable,
      ),
    );
  }
  // False positives: voiced runs outside every (extended) note span.
  var fp = 0;
  var g = 0;
  while (g < len) {
    if (alignedTake[g].isNaN || covered[g]) {
      g++;
      continue;
    }
    var h = g;
    while (h < len && !alignedTake[h].isNaN && !covered[h]) {
      h++;
    }
    if (h - g >= minFrames) fp++;
    g = h;
  }
  estimated += fp;
  PrecisionRecallF1 prf(int m) => PrecisionRecallF1.fromCounts(
    matches: m,
    estimated: estimated,
    reference: evaluable,
  );
  return NoteMetrics(
    onset: prf(mOnset),
    onsetPitch: prf(mPitch),
    onsetPitchOffset: prf(mFull),
    perNote: reports,
    takeNotes: takeNotes,
    segmentation: NoteSegmentation.referenceGuided,
    falsePositives: fp,
    medianAbsOnsetErrorMs: absOnset.isEmpty ? null : median(absOnset),
    medianAbsOffsetErrorMs: absOffset.isEmpty ? null : median(absOffset),
  );
}
