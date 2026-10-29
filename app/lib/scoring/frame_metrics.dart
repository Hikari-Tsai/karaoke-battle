/// Frame-level melody metrics (mir_eval `melody` definitions).
library;

import 'dart:math' as math;

import 'models.dart';

/// Computes the mir_eval melody metrics between an aligned take semitone
/// track and the reference semitone track (same grid, NaN = unvoiced).
///
/// * Voicing recall = frames voiced in both / frames voiced in the reference.
/// * Voicing false alarm = frames voiced in the take but not in the
///   reference / frames unvoiced in the reference.
/// * Raw pitch accuracy = reference-voiced frames where the take is voiced
///   and `|take + shift - ref| <= tolerance` / reference-voiced frames.
/// * Raw chroma accuracy = same with the chroma (octave-invariant) distance.
/// * Overall accuracy = frames that are either unvoiced in both, or voiced in
///   both with a correct chroma / all frames. (mir_eval uses raw pitch here;
///   this module is octave-invariant by design, so chroma is used.)
///
/// [alt] is an optional second target on the same grid (the reference notes
/// sampled on the grid): a reference-voiced frame also counts as correct when
/// the take is within [tolerance] of `alt[i]`. This lets a singer hold the
/// plain note where the original scoops or slides through it, while still
/// accepting a take that follows the original curve.
///
/// [octaveExactShift] is only used for [FrameMetrics.rawPitchAccuracyOctaveExact].
FrameMetrics computeFrameMetrics(
  List<double> take,
  List<double> ref, {
  required int shift,
  int octaveExactShift = 0,
  double tolerance = 0.5,
  List<double>? alt,
}) {
  final n = math.min(take.length, ref.length);
  var refVoiced = 0;
  var refUnvoiced = 0;
  var bothVoiced = 0;
  var falseAlarm = 0;
  var rpa = 0;
  var rca = 0;
  var rpaOct = 0;
  var correct = 0;
  for (var i = 0; i < n; i++) {
    final r = ref[i];
    final t = take[i];
    final rv = !r.isNaN;
    final tv = !t.isNaN;
    if (rv) {
      refVoiced++;
      if (tv) {
        bothVoiced++;
        final a = (alt != null && i < alt.length) ? alt[i] : double.nan;
        final hasAlt = !a.isNaN;
        if ((t + shift - r).abs() <= tolerance ||
            (hasAlt && (t + shift - a).abs() <= tolerance)) {
          rpa++;
        }
        if ((t + octaveExactShift - r).abs() <= tolerance ||
            (hasAlt && (t + octaveExactShift - a).abs() <= tolerance)) {
          rpaOct++;
        }
        if (chromaDistance(t + shift, r) <= tolerance ||
            (hasAlt && chromaDistance(t + shift, a) <= tolerance)) {
          rca++;
          correct++;
        }
      }
    } else {
      refUnvoiced++;
      if (tv) {
        falseAlarm++;
      } else {
        correct++;
      }
    }
  }
  double ratio(int a, int b) => b == 0 ? 0.0 : a / b;
  return FrameMetrics(
    rawPitchAccuracy: ratio(rpa, refVoiced),
    rawChromaAccuracy: ratio(rca, refVoiced),
    voicingRecall: ratio(bothVoiced, refVoiced),
    voicingFalseAlarm: ratio(falseAlarm, refUnvoiced),
    overallAccuracy: ratio(correct, n),
    rawPitchAccuracyOctaveExact: ratio(rpaOct, refVoiced),
    referenceVoicedFrames: refVoiced,
    totalFrames: n,
  );
}
