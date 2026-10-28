/// Technique metrics: vibrato, pitch stability, expression and long tones.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'alignment.dart';
import 'models.dart';
import 'tracks.dart';

/// Vibrato measurement of one analysis window.
class VibratoWindow {
  const VibratoWindow({
    required this.rateHz,
    required this.extentCents,
    required this.periodicity,
    required this.present,
  });

  /// Peak modulation frequency in Hz.
  final double rateHz;

  /// Peak-to-peak modulation extent in cents.
  final double extentCents;

  /// Energy of the detected sinusoid relative to the detrended variance.
  final double periodicity;

  /// Whether this window passes the rate/extent/periodicity criteria.
  final bool present;
}

/// Vibrato verdict for one sustained segment.
class SegmentVibrato {
  const SegmentVibrato({
    required this.present,
    this.rateHz,
    this.extentCents,
    this.windowFraction = 0,
  });

  final bool present;
  final double? rateHz;
  final double? extentCents;

  /// Fraction of analysis windows that detected vibrato.
  final double windowFraction;
}

/// Trig tables for the fine-grid DFT, cached per window length.
final Map<int, _DftTables> _dftCache = {};

class _DftTables {
  _DftTables(int n, double hop, double fMin, double fStep, int bins)
    : cos = Float64List(bins * n),
      sin = Float64List(bins * n),
      hann = Float64List(n) {
    for (var i = 0; i < n; i++) {
      hann[i] = n == 1 ? 1.0 : 0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1));
    }
    for (var b = 0; b < bins; b++) {
      final f = fMin + b * fStep;
      for (var i = 0; i < n; i++) {
        final ph = 2 * math.pi * f * i * hop;
        cos[b * n + i] = math.cos(ph);
        sin[b * n + i] = math.sin(ph);
      }
    }
  }
  final Float64List cos;
  final Float64List sin;
  final Float64List hann;
}

/// Analyses one window of a semitone track (no NaNs) for vibrato: linear
/// detrend, Hann window, then a direct DFT on a 0.05 Hz grid from 3 to 9 Hz.
/// The peak in `[minRateHz, maxRateHz]` gives the rate; its amplitude `A`
/// (semitones) gives the peak-to-peak extent `200 * A` cents; periodicity is
/// `(A^2 / 2) / var(detrended)`. Returns null when the window is too short
/// or flat.
VibratoWindow? analyzeVibratoWindow(
  List<double> x,
  double hop, {
  double minRateHz = 4.0,
  double maxRateHz = 8.0,
  double minExtentCents = 30.0,
  double maxExtentCents = 150.0,
  double minPeriodicity = 0.35,
}) {
  final n = x.length;
  if (n < 8 || hop <= 0) return null;
  const fMin = 3.0;
  const fMax = 9.0;
  const fStep = 0.05;
  final bins = ((fMax - fMin) / fStep).round() + 1;
  final key = n * 1000003 + (hop * 1e6).round();
  final tables = _dftCache.putIfAbsent(
    key,
    () => _DftTables(n, hop, fMin, fStep, bins),
  );

  // Linear detrend (least squares).
  var st = 0.0;
  var sx = 0.0;
  for (var i = 0; i < n; i++) {
    st += i;
    sx += x[i];
  }
  final mt = st / n;
  final mx = sx / n;
  var stt = 0.0;
  var stx = 0.0;
  for (var i = 0; i < n; i++) {
    stt += (i - mt) * (i - mt);
    stx += (i - mt) * (x[i] - mx);
  }
  final slope = stt == 0 ? 0.0 : stx / stt;
  final y = Float64List(n);
  var variance = 0.0;
  for (var i = 0; i < n; i++) {
    y[i] = x[i] - (mx + slope * (i - mt));
    variance += y[i] * y[i];
  }
  variance /= n;
  if (variance < 1e-10) return null;

  var sw = 0.0;
  for (var i = 0; i < n; i++) {
    sw += tables.hann[i];
  }
  var bestAmp = -1.0;
  var bestF = minRateHz;
  for (var b = 0; b < bins; b++) {
    final f = fMin + b * fStep;
    if (f < minRateHz - 1e-9 || f > maxRateHz + 1e-9) continue;
    var re = 0.0;
    var im = 0.0;
    final base = b * n;
    for (var i = 0; i < n; i++) {
      final v = y[i] * tables.hann[i];
      re += v * tables.cos[base + i];
      im += v * tables.sin[base + i];
    }
    final amp = 2.0 * math.sqrt(re * re + im * im) / sw;
    if (amp > bestAmp) {
      bestAmp = amp;
      bestF = f;
    }
  }
  final extent = 200.0 * bestAmp;
  final periodicity = (bestAmp * bestAmp / 2.0) / variance;
  final present =
      extent >= minExtentCents &&
      extent <= maxExtentCents &&
      periodicity >= minPeriodicity;
  return VibratoWindow(
    rateHz: bestF,
    extentCents: extent,
    periodicity: periodicity,
    present: present,
  );
}

/// Detects vibrato on a sustained segment `[start, end)` of a semitone track
/// (gaps must already be bridged). Sliding windows of about
/// [windowSeconds] (capped at the segment length) with a hop of
/// [windowHopSeconds] are analysed; the segment has vibrato when at least
/// [minWindowFraction] of its windows pass. Rate/extent are the medians over
/// passing windows.
SegmentVibrato detectVibrato(
  List<double> semis,
  int start,
  int end,
  double hop, {
  double windowSeconds = 0.512,
  double windowHopSeconds = 0.128,
  double minWindowFraction = 0.4,
}) {
  final len = end - start;
  final win = math.min(len, math.max(8, (windowSeconds / hop).round()));
  final step = math.max(1, (windowHopSeconds / hop).round());
  if (len < 8) return const SegmentVibrato(present: false);
  final rates = <double>[];
  final extents = <double>[];
  var windows = 0;
  for (var s = start; s + win <= end; s += step) {
    final w = <double>[];
    var ok = true;
    for (var g = s; g < s + win; g++) {
      final v = semis[g];
      if (v.isNaN) {
        ok = false;
        break;
      }
      w.add(v);
    }
    windows++;
    if (!ok) continue;
    final r = analyzeVibratoWindow(w, hop);
    if (r != null && r.present) {
      rates.add(r.rateHz);
      extents.add(r.extentCents);
    }
    if (s + win == end) break;
  }
  if (windows == 0) return const SegmentVibrato(present: false);
  final frac = rates.length / windows;
  final present = rates.isNotEmpty && frac >= minWindowFraction;
  return SegmentVibrato(
    present: present,
    rateHz: present ? median(rates) : null,
    extentCents: present ? median(extents) : null,
    windowFraction: frac,
  );
}

/// Pitch stability of a segment `[start, end)`: the standard deviation in
/// cents of the pitch track around its median after removing the vibrato
/// band with a moving average of one vibrato period ([vibratoRateHz], or
/// 6 Hz when no vibrato was detected). Returns null without voiced frames.
double? pitchStabilityCents(
  List<double> semis,
  int start,
  int end,
  double hop, {
  double? vibratoRateHz,
}) {
  final vals = <double>[];
  for (var g = start; g < end; g++) {
    if (!semis[g].isNaN) vals.add(semis[g]);
  }
  if (vals.isEmpty) return null;
  final m = median(vals);
  final cents = vals.map((v) => (v - m) * 100.0).toList(growable: false);
  final period = 1.0 / ((vibratoRateHz ?? 6.0) * hop);
  var win = math.max(1, period.round());
  if (win.isEven) win++;
  final smooth = movingAverage(cents, win);
  return standardDeviation(smooth);
}

/// Long-tone score: mean over reference notes at least [longNoteSeconds]
/// long of the fraction of the note where the take is voiced and within
/// [toleranceSemitones] chroma-wise (after [shift]) of the target. With
/// [refCurve] (the reference F0 on the same grid) the target is the curve
/// where voiced and only reference-voiced frames count (notes without any
/// are skipped); otherwise the target is the note pitch over the whole
/// span. Returns null when there is no evaluable long reference note.
double? longToneScore(
  List<ReferenceNote> refNotes,
  List<double> alignedTake, {
  required double hop,
  required int shift,
  List<double>? refCurve,
  double longNoteSeconds = 0.4,
  double toleranceSemitones = 0.5,
}) {
  final fractions = <double>[];
  final len = alignedTake.length;
  for (final n in refNotes) {
    if (n.duration < longNoteSeconds) continue;
    final s = (n.onset / hop).ceil().clamp(0, len);
    final e = math.max(s + 1, (n.offset / hop).ceil()).clamp(0, len);
    var good = 0;
    var total = 0;
    for (var g = s; g < e; g++) {
      final double target;
      if (refCurve != null) {
        if (refCurve[g].isNaN) continue;
        target = refCurve[g];
      } else {
        target = n.pitch;
      }
      total++;
      final v = alignedTake[g];
      if (v.isNaN) continue;
      if (chromaDistance(v + shift, target) <= toleranceSemitones) good++;
    }
    if (total > 0) fractions.add(good / total);
  }
  return fractions.isEmpty ? null : mean(fractions);
}

/// Pearson correlation between the take and reference loudness curves,
/// evaluated on reference frames that are voiced in the reference, with the
/// take curve read at the aligned take time. Returns null when fewer than
/// [minFrames] frames are available or a curve is constant.
double? expressionCorrelation(
  EnergyCurve takeEnergy,
  EnergyCurve refEnergy,
  AlignmentResult alignment,
  List<double> refSemis, {
  int minFrames = 10,
}) {
  final a = <double>[];
  final b = <double>[];
  final m = math.min(refSemis.length, alignment.refLength);
  for (var j = 0; j < m; j++) {
    if (refSemis[j].isNaN) continue;
    final tr = j * alignment.hop;
    final tt = alignment.refTimeToTakeTime(tr);
    final er = interpolateLinear(refEnergy.times, refEnergy.rmsDb, tr);
    final et = interpolateLinear(takeEnergy.times, takeEnergy.rmsDb, tt);
    if (er.isNaN || et.isNaN) continue;
    a.add(et);
    b.add(er);
  }
  if (a.length < minFrames) return null;
  final r = pearson(a, b);
  return r.isNaN ? null : r;
}

/// Vibrato and stability statistics over the long reference notes of one
/// track (take or reference).
class LongNoteAnalysis {
  const LongNoteAnalysis({
    required this.longNotes,
    required this.analysed,
    required this.withVibrato,
    required this.rates,
    required this.extents,
    required this.stabilities,
    required this.amounts,
  });

  /// Reference notes at least `longNoteSeconds` long.
  final int longNotes;

  /// Long notes where the track is voiced for at least half of the span.
  final int analysed;

  /// Analysed notes with detected vibrato.
  final int withVibrato;
  final List<double> rates;
  final List<double> extents;
  final List<double> stabilities;

  /// Per long note: fraction of analysis windows with vibrato (0 when the
  /// note could not be analysed).
  final List<double> amounts;

  /// `withVibrato / longNotes` (0 without long notes).
  double get fraction => longNotes == 0 ? 0.0 : withVibrato / longNotes;

  /// Mean of [amounts] (0 without long notes).
  double get amount => amounts.isEmpty ? 0.0 : mean(amounts);
}

/// Runs vibrato detection and stability measurement on every reference note
/// at least [longNoteSeconds] long. [bridged] is the gap-bridged, unfiltered
/// semitone track of the analysed signal on its own grid; [timeMap] maps a
/// reference time to that grid's time (identity for the reference itself),
/// so the take is analysed on its own unwarped frames.
LongNoteAnalysis analyzeLongNotes(
  List<ReferenceNote> refNotes,
  List<double> bridged, {
  required double hop,
  double longNoteSeconds = 0.4,
  double Function(double)? timeMap,
  double minVoicedFraction = 0.5,
}) {
  var longNotes = 0;
  var analysed = 0;
  var vib = 0;
  final rates = <double>[];
  final extents = <double>[];
  final stabilities = <double>[];
  final amounts = <double>[];
  final len = bridged.length;
  for (final n in refNotes) {
    if (n.duration < longNoteSeconds) continue;
    longNotes++;
    amounts.add(0);
    final t0 = timeMap == null ? n.onset : timeMap(n.onset);
    final t1 = timeMap == null ? n.offset : timeMap(n.offset);
    // Same convention as the grid sampling: frame g belongs to the note
    // when g * hop lies in [onset, offset).
    final s = (t0 / hop - 1e-6).ceil().clamp(0, len);
    final e = (t1 / hop - 1e-6).ceil().clamp(0, len);
    if (e - s < 2) continue;
    var voiced = 0;
    for (var g = s; g < e; g++) {
      if (!bridged[g].isNaN) voiced++;
    }
    if (voiced < minVoicedFraction * (e - s)) continue;
    analysed++;
    final v = detectVibrato(bridged, s, e, hop);
    amounts[amounts.length - 1] = v.windowFraction;
    if (v.present) {
      vib++;
      rates.add(v.rateHz!);
      extents.add(v.extentCents!);
    }
    final st = pitchStabilityCents(
      bridged,
      s,
      e,
      hop,
      vibratoRateHz: v.present ? v.rateHz : null,
    );
    if (st != null) stabilities.add(st);
  }
  return LongNoteAnalysis(
    longNotes: longNotes,
    analysed: analysed,
    withVibrato: vib,
    rates: rates,
    extents: extents,
    stabilities: stabilities,
    amounts: amounts,
  );
}
