/// Transposition estimation and time alignment between a take and a
/// reference, both represented as semitone tracks on a common frame grid.
///
/// A *semitone track* is a `List<double>` of fractional MIDI pitches with
/// `double.nan` for unvoiced frames. All functions here are pure Dart.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// How the take is aligned to the reference.
enum AlignmentMode {
  /// Constrained (Sakoe-Chiba) dynamic time warping.
  dtw,

  /// A single global offset found by cross-correlating the voicing.
  fixedOffset,
}

/// Returns `true` when [v] is a voiced value of a semitone track.
bool isVoiced(double v) => !v.isNaN;

/// Local DTW cost between a take frame and a reference frame after shifting
/// the take by [shift] semitones:
/// `0` for unvoiced/unvoiced, `1` for a voicing mismatch and
/// `min(|dc|, 12 - |dc|) / 6` for two voiced frames (`dc` = chroma delta).
double localCost(double take, double ref, int shift) {
  final tn = take.isNaN;
  final rn = ref.isNaN;
  if (tn && rn) return 0.0;
  if (tn || rn) return 1.0;
  var d = (take + shift - ref) % 12.0;
  if (d > 6.0) d = 12.0 - d;
  return d / 6.0;
}

/// Estimates the global integer chroma shift `k` in `0..11` that maximises
/// Raw Chroma Accuracy (50-cent tolerance) between two *aligned* semitone
/// tracks ([take] and [ref] must have the same length; only frames voiced in
/// both are used). Ties resolve to the smallest `k`.
int estimateChromaShift(List<double> take, List<double> ref) {
  final n = math.min(take.length, ref.length);
  final hist = List<int>.filled(12, 0);
  for (var i = 0; i < n; i++) {
    final t = take[i];
    final r = ref[i];
    if (t.isNaN || r.isNaN) continue;
    // k* = round(ref - take) mod 12 makes this frame chroma-correct.
    final k = ((r - t).round() % 12 + 12) % 12;
    hist[k]++;
  }
  var best = 0;
  var bestCount = -1;
  for (var k = 0; k < 12; k++) {
    if (hist[k] > bestCount) {
      bestCount = hist[k];
      best = k;
    }
  }
  return best;
}

/// Estimates the octave-exact shift in `-24..24` that maximises Raw Pitch
/// Accuracy between two aligned semitone tracks. Ties resolve to the shift
/// with the smallest absolute value (then the negative one).
int estimateOctaveExactShift(
  List<double> take,
  List<double> ref, {
  int maxShift = 24,
}) {
  final n = math.min(take.length, ref.length);
  final hist = List<int>.filled(2 * maxShift + 1, 0);
  for (var i = 0; i < n; i++) {
    final t = take[i];
    final r = ref[i];
    if (t.isNaN || r.isNaN) continue;
    final k = (r - t).round();
    if (k < -maxShift || k > maxShift) continue;
    hist[k + maxShift]++;
  }
  var best = 0;
  var bestCount = -1;
  for (var a = 0; a <= maxShift; a++) {
    for (final k in a == 0 ? [0] : [-a, a]) {
      final c = hist[k + maxShift];
      if (c > bestCount) {
        bestCount = c;
        best = k;
      }
    }
  }
  return best;
}

/// Finds the global offset (in frames) of the take relative to the reference
/// by cross-correlating the mean-centred voicing indicators:
/// `take[j + offset] ~ ref[j]`. Ties resolve to the smallest |offset|.
int estimateVoicingOffsetFrames(
  List<double> take,
  List<double> ref, {
  required int maxOffsetFrames,
}) {
  final n = take.length;
  final m = ref.length;
  if (n == 0 || m == 0) return 0;
  final vt = Float64List(n);
  final vr = Float64List(m);
  var st = 0.0;
  var sr = 0.0;
  for (var i = 0; i < n; i++) {
    vt[i] = take[i].isNaN ? 0.0 : 1.0;
    st += vt[i];
  }
  for (var j = 0; j < m; j++) {
    vr[j] = ref[j].isNaN ? 0.0 : 1.0;
    sr += vr[j];
  }
  final mt = st / n;
  final mr = sr / m;
  for (var i = 0; i < n; i++) {
    vt[i] -= mt;
  }
  for (var j = 0; j < m; j++) {
    vr[j] -= mr;
  }
  var best = 0;
  var bestScore = double.negativeInfinity;
  for (var a = 0; a <= maxOffsetFrames; a++) {
    for (final off in a == 0 ? [0] : [-a, a]) {
      final jLo = math.max(0, -off);
      final jHi = math.min(m, n - off);
      if (jHi - jLo < 2) continue;
      var sum = 0.0;
      for (var j = jLo; j < jHi; j++) {
        sum += vt[j + off] * vr[j];
      }
      final score = sum / (jHi - jLo);
      if (score > bestScore) {
        bestScore = score;
        best = off;
      }
    }
  }
  return best;
}

/// Result of aligning a take to a reference. The warping path is given as
/// two parallel index arrays ([pathTake], [pathRef]). [takeFrameForRef] is
/// the median projection of the path (one take index per reference frame,
/// `-1` when unmapped) and [refFrameForTake] is its inverse (gaps filled by
/// interpolation, unmapped ends `-1`).
class AlignmentResult {
  AlignmentResult({
    required this.mode,
    required this.hop,
    required this.offsetFrames,
    required this.takeLength,
    required this.refLength,
    required this.pathTake,
    required this.pathRef,
    required this.cost,
  }) : takeFrameForRef = _project(pathRef, pathTake, refLength),
       refFrameForTake = _invert(
         _project(pathRef, pathTake, refLength),
         takeLength,
       );

  /// Alignment with an empty path (used for degenerate inputs).
  factory AlignmentResult.empty({
    required AlignmentMode mode,
    required double hop,
    required int takeLength,
    required int refLength,
  }) => AlignmentResult(
    mode: mode,
    hop: hop,
    offsetFrames: 0,
    takeLength: takeLength,
    refLength: refLength,
    pathTake: Int32List(0),
    pathRef: Int32List(0),
    cost: 0,
  );

  final AlignmentMode mode;
  final double hop;

  /// Global offset in frames (`take ~ ref + offset`) from the voicing
  /// cross-correlation; the DTW band is centred on this diagonal.
  final int offsetFrames;
  final int takeLength;
  final int refLength;
  final Int32List pathTake;
  final Int32List pathRef;

  /// Accumulated DTW cost along the path (0 for fixed offset).
  final double cost;
  final Int32List takeFrameForRef;
  final Int32List refFrameForTake;

  /// Global offset in seconds.
  double get offsetSeconds => offsetFrames * hop;

  /// Number of path cells.
  int get pathLength => pathTake.length;

  /// For every value of [keys] (sorted, non-decreasing), the median of the
  /// corresponding [values]; `-1` where a key never occurs.
  static Int32List _project(Int32List keys, Int32List values, int length) {
    final out = Int32List(length);
    for (var i = 0; i < length; i++) {
      out[i] = -1;
    }
    var s = 0;
    while (s < keys.length) {
      var e = s;
      while (e + 1 < keys.length && keys[e + 1] == keys[s]) {
        e++;
      }
      final k = keys[s];
      if (k >= 0 && k < length) out[k] = values[(s + e) ~/ 2];
      s = e + 1;
    }
    return out;
  }

  /// Inverse of a non-decreasing partial map (`-1` = undefined); gaps between
  /// defined values are filled by linear interpolation, ends stay `-1`.
  static Int32List _invert(Int32List f, int length) {
    final out = Int32List(length);
    for (var i = 0; i < length; i++) {
      out[i] = -1;
    }
    var s = 0;
    while (s < f.length) {
      if (f[s] < 0) {
        s++;
        continue;
      }
      var e = s;
      while (e + 1 < f.length && f[e + 1] == f[s]) {
        e++;
      }
      final i = f[s];
      if (i >= 0 && i < length) out[i] = (s + e) ~/ 2;
      s = e + 1;
    }
    var prev = -1;
    for (var i = 0; i < length; i++) {
      if (out[i] >= 0) {
        if (prev >= 0 && i - prev > 1) {
          final a = out[prev];
          final b = out[i];
          for (var g = prev + 1; g < i; g++) {
            out[g] = (a + (b - a) * (g - prev) / (i - prev)).round();
          }
        }
        prev = i;
      }
    }
    return out;
  }

  /// Maps a take time (s) to the corresponding reference time (s).
  /// Frames outside the path are extrapolated with the global offset and
  /// clamped to the reference range.
  double takeTimeToRefTime(double t) {
    final refEnd = math.max(0, refLength - 1) * hop;
    if (takeLength == 0 || refLength == 0) {
      return (t - offsetFrames * hop).clamp(0.0, refEnd);
    }
    final i = (t / hop).round().clamp(0, takeLength - 1);
    final j = refFrameForTake[i];
    if (j < 0) {
      return _extrapolate(
        t,
        refFrameForTake,
        takeLength,
        -offsetFrames,
      ).clamp(0.0, refEnd);
    }
    // Sub-frame interpolation towards the neighbour on the same side.
    final frac = t / hop - i;
    final nb = frac >= 0 ? i + 1 : i - 1;
    if (nb >= 0 && nb < takeLength && refFrameForTake[nb] >= 0) {
      final jn = refFrameForTake[nb];
      return ((j + (jn - j) * frac.abs()) * hop).clamp(0.0, refEnd);
    }
    return ((j + frac) * hop).clamp(0.0, refEnd);
  }

  /// Maps a reference time (s) to the corresponding take time (s).
  double refTimeToTakeTime(double t) {
    final takeEnd = math.max(0, takeLength - 1) * hop;
    if (takeLength == 0 || refLength == 0) {
      return (t + offsetFrames * hop).clamp(0.0, takeEnd);
    }
    final j = (t / hop).round().clamp(0, refLength - 1);
    final i = takeFrameForRef[j];
    if (i < 0) {
      return _extrapolate(
        t,
        takeFrameForRef,
        refLength,
        offsetFrames,
      ).clamp(0.0, takeEnd);
    }
    final frac = t / hop - j;
    final nb = frac >= 0 ? j + 1 : j - 1;
    if (nb >= 0 && nb < refLength && takeFrameForRef[nb] >= 0) {
      final inb = takeFrameForRef[nb];
      return ((i + (inb - i) * frac.abs()) * hop).clamp(0.0, takeEnd);
    }
    return ((i + frac) * hop).clamp(0.0, takeEnd);
  }

  /// Extrapolates from the nearest mapped frame using the global offset.
  double _extrapolate(double t, Int32List map, int length, int offset) {
    final i = (t / hop).round().clamp(0, length - 1);
    // Find the nearest mapped frame on either side.
    var lo = i;
    while (lo >= 0 && map[lo] < 0) {
      lo--;
    }
    var hi = i;
    while (hi < length && map[hi] < 0) {
      hi++;
    }
    if (lo < 0 && hi >= length) return t + offset * hop;
    final anchor = (lo >= 0 && (hi >= length || i - lo <= hi - i)) ? lo : hi;
    return (map[anchor] + (i - anchor)) * hop + (t - i * hop);
  }

  /// Resamples a take-grid sequence onto the reference grid through the
  /// alignment (`out[j] = take[takeFrameForRef[j]]`, NaN when unmapped).
  List<double> alignTakeToRefGrid(List<double> take) {
    final out = Float64List(refLength);
    for (var j = 0; j < refLength; j++) {
      final i = takeFrameForRef[j];
      out[j] = (i >= 0 && i < take.length) ? take[i] : double.nan;
    }
    return out;
  }

  factory AlignmentResult.fromJson(Map<String, dynamic> json) =>
      AlignmentResult(
        mode: AlignmentMode.values.firstWhere(
          (m) => m.name == json['mode'],
          orElse: () => AlignmentMode.dtw,
        ),
        hop: (json['hop'] as num).toDouble(),
        offsetFrames: (json['offset_frames'] as num).toInt(),
        takeLength: (json['take_length'] as num).toInt(),
        refLength: (json['ref_length'] as num).toInt(),
        pathTake: Int32List.fromList(
          ((json['path_take'] ?? const []) as List)
              .map((e) => (e as num).toInt())
              .toList(),
        ),
        pathRef: Int32List.fromList(
          ((json['path_ref'] ?? const []) as List)
              .map((e) => (e as num).toInt())
              .toList(),
        ),
        cost: ((json['cost'] ?? 0) as num).toDouble(),
      );

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'hop': hop,
    'offset_frames': offsetFrames,
    'offset_seconds': offsetSeconds,
    'take_length': takeLength,
    'ref_length': refLength,
    'cost': cost,
    'path_take': pathTake.toList(growable: false),
    'path_ref': pathRef.toList(growable: false),
  };
}

/// Alignment with a single global offset: `take[j + offset] ~ ref[j]`.
AlignmentResult alignFixedOffset(
  List<double> take,
  List<double> ref, {
  required double hop,
  required int offsetFrames,
}) {
  final n = take.length;
  final m = ref.length;
  final jLo = math.max(0, -offsetFrames);
  final jHi = math.min(m, n - offsetFrames);
  final len = math.max(0, jHi - jLo);
  final pt = Int32List(len);
  final pr = Int32List(len);
  for (var c = 0; c < len; c++) {
    pr[c] = jLo + c;
    pt[c] = jLo + c + offsetFrames;
  }
  return AlignmentResult(
    mode: AlignmentMode.fixedOffset,
    hop: hop,
    offsetFrames: offsetFrames,
    takeLength: n,
    refLength: m,
    pathTake: pt,
    pathRef: pr,
    cost: 0,
  );
}

/// Constrained DTW between a take and a reference semitone track.
///
/// The Sakoe-Chiba band of half-width [bandFrames] is centred on the diagonal
/// `i = j + offsetFrames`. Steps are `(1,1)`, `(1,0)` and `(0,1)` with the
/// local cost of [localCost] (the take is shifted by [shift] semitones).
/// The path may start on any in-band cell of the first row/column and end on
/// any in-band cell of the last row/column (ties prefer the longest path).
/// Non-diagonal steps `(1,0)` and `(0,1)` cost an extra [stepPenalty] (a gap
/// penalty that stops the warp from cherry-picking single lucky frames of a
/// poor take; tempo drift of a few percent only needs a few such steps per
/// 100 frames, so it is practically free for real timing deviations).
AlignmentResult alignDtw(
  List<double> take,
  List<double> ref, {
  required double hop,
  required int bandFrames,
  int offsetFrames = 0,
  int shift = 0,
  double stepPenalty = 0.0,
}) {
  final n = take.length;
  final m = ref.length;
  if (n == 0 || m == 0) {
    return AlignmentResult.empty(
      mode: AlignmentMode.dtw,
      hop: hop,
      takeLength: n,
      refLength: m,
    );
  }
  final b = math.max(0, bandFrames);
  final w = 2 * b + 1;
  final off = offsetFrames;
  final acc = Float64List(n * w);
  final bp = Uint8List(n * w); // 0 start, 1 diag, 2 up (i-1,j), 3 left (i,j-1)
  final inf = double.infinity;

  // Row i covers j in [i - off - b, i - off + b]; slot = j - (i - off - b).
  for (var i = 0; i < n; i++) {
    final base = i - off - b;
    final jl = math.max(0, base);
    final jh = math.min(m - 1, i - off + b);
    final row = i * w;
    final prevRow = row - w;
    final prevBase = base - 1;
    final prevJl = math.max(0, prevBase);
    final prevJh = math.min(m - 1, i - 1 - off + b);
    final ti = take[i];
    for (var j = jl; j <= jh; j++) {
      final c = localCost(ti, ref[j], shift);
      final idx = row + (j - base);
      if (i == 0 || j == 0) {
        acc[idx] = c;
        bp[idx] = 0;
        continue;
      }
      var best = inf;
      var from = 0;
      if (i > 0 && prevJl <= prevJh) {
        if (j - 1 >= prevJl && j - 1 <= prevJh) {
          final v = acc[prevRow + (j - 1 - prevBase)];
          if (v < best) {
            best = v;
            from = 1;
          }
        }
        if (j >= prevJl && j <= prevJh) {
          final v = acc[prevRow + (j - prevBase)] + stepPenalty;
          if (v < best) {
            best = v;
            from = 2;
          }
        }
      }
      if (j - 1 >= jl) {
        final v = acc[idx - 1] + stepPenalty;
        if (v < best) {
          best = v;
          from = 3;
        }
      }
      if (best == inf) {
        // Unreachable inside the band (only happens after empty rows).
        acc[idx] = c;
        bp[idx] = 0;
      } else {
        acc[idx] = best + c;
        bp[idx] = from;
      }
    }
    // Mark out-of-band slots as unreachable.
    for (var j = base; j < jl; j++) {
      acc[row + (j - base)] = inf;
    }
    for (var j = jh + 1; j <= i - off + b; j++) {
      acc[row + (j - base)] = inf;
    }
  }

  // Free end: best cell on the last row or last column within the band.
  var endI = -1;
  var endJ = -1;
  var endCost = inf;
  void consider(int i, int j) {
    final base = i - off - b;
    if (j < base || j > i - off + b || j < 0 || j >= m) return;
    final v = acc[i * w + (j - base)];
    if (v < endCost || (v == endCost && i + j > endI + endJ)) {
      endCost = v;
      endI = i;
      endJ = j;
    }
  }

  {
    final i = n - 1;
    final jl = math.max(0, i - off - b);
    final jh = math.min(m - 1, i - off + b);
    for (var j = jl; j <= jh; j++) {
      consider(i, j);
    }
    final j = m - 1;
    final il = math.max(0, j + off - b);
    final ih = math.min(n - 1, j + off + b);
    for (var ii = il; ii <= ih; ii++) {
      consider(ii, j);
    }
  }
  if (endI < 0) {
    return AlignmentResult.empty(
      mode: AlignmentMode.dtw,
      hop: hop,
      takeLength: n,
      refLength: m,
    );
  }

  // Backtrack.
  final revT = <int>[];
  final revR = <int>[];
  var i = endI;
  var j = endJ;
  while (true) {
    revT.add(i);
    revR.add(j);
    final base = i - off - b;
    final from = bp[i * w + (j - base)];
    if (from == 0) break;
    if (from == 1) {
      i--;
      j--;
    } else if (from == 2) {
      i--;
    } else {
      j--;
    }
  }
  final len = revT.length;
  final pt = Int32List(len);
  final pr = Int32List(len);
  for (var c = 0; c < len; c++) {
    pt[c] = revT[len - 1 - c];
    pr[c] = revR[len - 1 - c];
  }
  return AlignmentResult(
    mode: AlignmentMode.dtw,
    hop: hop,
    offsetFrames: off,
    takeLength: n,
    refLength: m,
    pathTake: pt,
    pathRef: pr,
    cost: endCost,
  );
}
