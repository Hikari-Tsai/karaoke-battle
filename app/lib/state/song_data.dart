// Loaders for notes.json / ref_f0.json / take_f0.json into compact display
// structures, plus pitch helpers shared by the painter and the HUD.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

double hzToMidi(double hz) => 69.0 + 12.0 * math.log(hz / 440.0) / math.ln2;
double midiToHz(double midi) => 440.0 * math.pow(2.0, (midi - 69.0) / 12.0);

const _noteNames = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];

/// "C4", "F#3" for a MIDI number (rounded).
String noteName(double midi) {
  if (midi.isNaN || midi.isInfinite) return '—';
  final n = midi.round();
  final octave = (n ~/ 12) - 1;
  return '${_noteNames[n % 12]}$octave';
}

/// Moves [midi] to the octave closest to [ref].
double foldToOctaveOf(double midi, double ref) => midi + 12.0 * ((ref - midi) / 12.0).round();

/// A reference note (seconds, MIDI float). Immutable, stored in flat arrays
/// for painting.
class NoteList {
  NoteList(this.onset, this.offset, this.pitch);
  final Float64List onset;
  final Float64List offset;
  final Float64List pitch;

  int get length => onset.length;
  bool get isEmpty => onset.isEmpty;

  double get minPitch => pitch.isEmpty ? 60 : pitch.reduce(math.min);
  double get maxPitch => pitch.isEmpty ? 72 : pitch.reduce(math.max);
  double get endTime => offset.isEmpty ? 0 : offset.last;

  static NoteList empty() => NoteList(Float64List(0), Float64List(0), Float64List(0));

  static NoteList fromJson(Map<String, dynamic> j) {
    final raw = (j['notes'] as List? ?? const []);
    final items = <(double, double, double)>[];
    for (final e in raw) {
      final m = e as Map<String, dynamic>;
      final on = (m['onset'] as num).toDouble();
      final off = (m['offset'] as num).toDouble();
      final pitch = (m['pitch'] as num).toDouble();
      if (off > on && pitch > 0) items.add((on, off, pitch));
    }
    items.sort((a, b) => a.$1.compareTo(b.$1));
    final n = items.length;
    final on = Float64List(n), off = Float64List(n), pi = Float64List(n);
    for (var i = 0; i < n; i++) {
      on[i] = items[i].$1;
      off[i] = items[i].$2;
      pi[i] = items[i].$3;
    }
    return NoteList(on, off, pi);
  }

  static Future<NoteList> load(String path) async {
    final f = File(path);
    if (!await f.exists()) return empty();
    try {
      return fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return empty();
    }
  }

  /// Index of the note sounding at [t] (onset <= t < offset), or -1.
  int indexAt(double t) {
    final i = _lastOnsetBefore(t);
    if (i < 0) return -1;
    return t < offset[i] ? i : -1;
  }

  /// Index of the first note whose offset is >= t (for window painting).
  int firstVisible(double t) {
    final i = _lastOnsetBefore(t);
    return i < 0 ? 0 : i;
  }

  int _lastOnsetBefore(double t) {
    var lo = 0, hi = onset.length - 1, ans = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (onset[mid] <= t) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  /// Reference pitch at [t], or NaN when no note sounds. Looks slightly ahead
  /// and behind (tolerance seconds) so that colouring is forgiving at edges.
  double pitchAt(double t, {double tolerance = 0.05}) {
    var i = indexAt(t);
    if (i >= 0) return pitch[i];
    i = _lastOnsetBefore(t);
    if (i >= 0 && t - offset[i] <= tolerance) return pitch[i];
    if (i + 1 < length && onset[i + 1] - t <= tolerance) return pitch[i + 1];
    return double.nan;
  }
}

/// An F0 curve stored as MIDI (NaN = unvoiced) on a time grid.
class F0Curve {
  F0Curve(this.times, this.midi, this.confidence);
  final Float64List times;
  final Float64List midi;
  final Float64List confidence;

  int get length => times.length;
  bool get isEmpty => times.isEmpty;

  static F0Curve empty() => F0Curve(Float64List(0), Float64List(0), Float64List(0));

  static F0Curve fromJson(Map<String, dynamic> j, {double confidenceThreshold = 0.0, double timeOffset = 0}) {
    final t = (j['times'] as List? ?? const []);
    final f = (j['f0'] as List? ?? const []);
    final c = (j['confidence'] as List? ?? const []);
    final hop = (j['hop'] as num?)?.toDouble() ?? 0.016;
    final n = math.min(f.length, t.isEmpty ? f.length : t.length);
    final times = Float64List(n), midi = Float64List(n), conf = Float64List(n);
    for (var i = 0; i < n; i++) {
      times[i] = (t.isEmpty ? i * hop : (t[i] as num).toDouble()) + timeOffset;
      final hz = (f[i] as num).toDouble();
      final cc = i < c.length ? (c[i] as num).toDouble() : 1.0;
      conf[i] = cc;
      midi[i] = (hz > 0 && cc >= confidenceThreshold) ? hzToMidi(hz) : double.nan;
    }
    return F0Curve(times, midi, conf);
  }

  static Future<F0Curve> load(String path, {double confidenceThreshold = 0.0, double timeOffset = 0}) async {
    final f = File(path);
    if (!await f.exists()) return empty();
    try {
      return fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>,
          confidenceThreshold: confidenceThreshold, timeOffset: timeOffset);
    } catch (_) {
      return empty();
    }
  }

  /// First index with time >= t.
  int lowerBound(double t) {
    var lo = 0, hi = times.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (times[mid] < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
}
