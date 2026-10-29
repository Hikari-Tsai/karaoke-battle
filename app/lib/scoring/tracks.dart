/// Helpers that turn the engine's inputs into semitone tracks on a uniform
/// frame grid, plus small signal utilities shared by the metric modules.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'models.dart';

/// Number of grid frames needed to cover `[0, endTime]` at [hop].
int gridLength(double endTime, double hop) =>
    endTime <= 0 || hop <= 0 ? 0 : (endTime / hop).ceil() + 1;

/// Converts an [F0Track] to semitones per original frame (NaN = unvoiced).
/// A frame is voiced when `f0 > 0` and its confidence (if present) is at
/// least [confidenceThreshold].
List<double> f0TrackToSemitones(
  F0Track track, {
  double confidenceThreshold = 0.4,
}) {
  final n = track.length;
  final out = Float64List(n);
  final hasConf = track.confidence.length >= n;
  for (var i = 0; i < n; i++) {
    final hz = track.f0[i];
    final conf = hasConf ? track.confidence[i] : 1.0;
    out[i] = (hz > 0 && conf >= confidenceThreshold && hz.isFinite)
        ? hzToMidi(hz)
        : double.nan;
  }
  return out;
}

/// Nearest-neighbour resampling of a (sorted-time) sequence onto the uniform
/// grid `t_g = g * hop`, `g < length`. Grid frames farther than [hop] from
/// any sample are NaN.
List<double> resampleNearest(
  List<double> times,
  List<double> values, {
  required int length,
  required double hop,
}) {
  final out = Float64List(length);
  final n = math.min(times.length, values.length);
  if (n == 0) {
    for (var g = 0; g < length; g++) {
      out[g] = double.nan;
    }
    return out;
  }
  var p = 0;
  for (var g = 0; g < length; g++) {
    final t = g * hop;
    while (p + 1 < n && (times[p + 1] - t).abs() <= (times[p] - t).abs()) {
      p++;
    }
    out[g] = (times[p] - t).abs() <= hop ? values[p] : double.nan;
  }
  return out;
}

/// Semitone track of an [F0Track] on the uniform grid.
List<double> f0TrackToGrid(
  F0Track track, {
  required double hop,
  int? length,
  double confidenceThreshold = 0.4,
}) {
  final semis = f0TrackToSemitones(
    track,
    confidenceThreshold: confidenceThreshold,
  );
  final n = track.length;
  final len = length ?? gridLength(n == 0 ? 0 : track.times[n - 1], hop);
  return resampleNearest(track.times, semis, length: len, hop: hop);
}

/// Noise gate: returns [take] with every frame whose loudness in [energy]
/// (nearest energy frame in time) is below [gateDb] set to unvoiced
/// (f0 = 0, confidence = 0). Frames outside the energy curve are kept.
F0Track applyNoiseGate(F0Track take, EnergyCurve energy, double gateDb) {
  final n = energy.length;
  if (n == 0) return take;
  final et = energy.times;
  final ed = energy.rmsDb;
  final f0 = List<double>.of(take.f0);
  final conf = take.confidence.isEmpty ? <double>[] : List<double>.of(take.confidence);
  var j = 0;
  for (var i = 0; i < f0.length && i < take.times.length; i++) {
    final t = take.times[i];
    if (t < et[0] - 0.05 || t > et[n - 1] + 0.05) continue;
    while (j + 1 < n && (et[j + 1] - t).abs() <= (et[j] - t).abs()) {
      j++;
    }
    if (ed[j] < gateDb) {
      f0[i] = 0;
      if (i < conf.length) conf[i] = 0;
    }
  }
  return F0Track(times: take.times, f0: f0, confidence: conf, hop: take.hop, sampleRate: take.sampleRate);
}

/// Samples note pitches on the uniform grid (frame `g` is voiced when
/// `g * hop` lies in `[onset, offset)` of a note).
List<double> notesToGrid(
  List<ReferenceNote> notes, {
  required double hop,
  required int length,
}) {
  final out = Float64List(length);
  for (var g = 0; g < length; g++) {
    out[g] = double.nan;
  }
  for (final n in notes) {
    final s = (n.onset / hop).ceil().clamp(0, length);
    final e = (n.offset / hop).ceil().clamp(0, length);
    for (var g = s; g < e; g++) {
      out[g] = n.pitch;
    }
  }
  return out;
}

/// Linear interpolation of a sorted-time curve at [t]; NaN outside the
/// curve's time range.
double interpolateLinear(List<double> times, List<double> values, double t) {
  final n = math.min(times.length, values.length);
  if (n == 0 || t < times[0] || t > times[n - 1]) return double.nan;
  var lo = 0;
  var hi = n - 1;
  while (hi - lo > 1) {
    final mid = (lo + hi) >> 1;
    if (times[mid] <= t) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  final dt = times[hi] - times[lo];
  if (dt <= 0) return values[lo];
  final a = (t - times[lo]) / dt;
  return values[lo] + (values[hi] - values[lo]) * a;
}

/// Median of a non-empty list (returns NaN for an empty list).
double median(List<double> values) {
  if (values.isEmpty) return double.nan;
  final s = List<double>.from(values)..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : 0.5 * (s[n ~/ 2 - 1] + s[n ~/ 2]);
}

/// Mean of a list (NaN when empty).
double mean(List<double> values) {
  if (values.isEmpty) return double.nan;
  var s = 0.0;
  for (final v in values) {
    s += v;
  }
  return s / values.length;
}

/// Population standard deviation (NaN when empty).
double standardDeviation(List<double> values) {
  if (values.isEmpty) return double.nan;
  final m = mean(values);
  var s = 0.0;
  for (final v in values) {
    s += (v - m) * (v - m);
  }
  return math.sqrt(s / values.length);
}

/// Fills unvoiced gaps of at most [maxGapFrames] frames that lie between two
/// voiced frames by linear interpolation.
List<double> bridgeGaps(List<double> x, int maxGapFrames) {
  final out = Float64List.fromList(x);
  final n = out.length;
  var i = 0;
  while (i < n) {
    if (!out[i].isNaN) {
      i++;
      continue;
    }
    var e = i;
    while (e < n && out[e].isNaN) {
      e++;
    }
    final gap = e - i;
    if (i > 0 && e < n && gap <= maxGapFrames) {
      final a = out[i - 1];
      final b = out[e];
      for (var g = i; g < e; g++) {
        out[g] = a + (b - a) * (g - i + 1) / (gap + 1);
      }
    }
    i = e;
  }
  return out;
}

/// Median filter with an odd [window], applied inside voiced runs only
/// (the window shrinks near run boundaries; NaNs are preserved).
List<double> medianFilter(List<double> x, int window) {
  final n = x.length;
  final out = Float64List(n);
  final half = math.max(0, window ~/ 2);
  var i = 0;
  while (i < n) {
    if (x[i].isNaN) {
      out[i] = double.nan;
      i++;
      continue;
    }
    var e = i;
    while (e < n && !x[e].isNaN) {
      e++;
    }
    final buf = <double>[];
    for (var g = i; g < e; g++) {
      final lo = math.max(i, g - half);
      final hi = math.min(e, g + half + 1);
      buf
        ..clear()
        ..addAll(x.getRange(lo, hi))
        ..sort();
      final m = buf.length;
      out[g] = m.isOdd ? buf[m ~/ 2] : 0.5 * (buf[m ~/ 2 - 1] + buf[m ~/ 2]);
    }
    i = e;
  }
  return out;
}

/// Centred moving average with a window of [window] frames (edges shrink).
List<double> movingAverage(List<double> x, int window) {
  final n = x.length;
  final out = Float64List(n);
  final half = math.max(0, window ~/ 2);
  for (var i = 0; i < n; i++) {
    final lo = math.max(0, i - half);
    final hi = math.min(n, i + half + 1);
    var s = 0.0;
    for (var g = lo; g < hi; g++) {
      s += x[g];
    }
    out[i] = s / (hi - lo);
  }
  return out;
}

/// Pearson correlation of two equal-length lists (NaN when degenerate).
double pearson(List<double> a, List<double> b) {
  final n = math.min(a.length, b.length);
  if (n < 2) return double.nan;
  var ma = 0.0;
  var mb = 0.0;
  for (var i = 0; i < n; i++) {
    ma += a[i];
    mb += b[i];
  }
  ma /= n;
  mb /= n;
  var sab = 0.0;
  var saa = 0.0;
  var sbb = 0.0;
  for (var i = 0; i < n; i++) {
    final da = a[i] - ma;
    final db = b[i] - mb;
    sab += da * db;
    saa += da * da;
    sbb += db * db;
  }
  if (saa <= 0 || sbb <= 0) return double.nan;
  return sab / math.sqrt(saa * sbb);
}
