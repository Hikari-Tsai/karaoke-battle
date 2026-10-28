// Growable, flat storage for live pitch frames (appended every UI tick).
import 'dart:typed_data';

/// Colour category of a live frame relative to the reference note.
class PitchCategory {
  static const none = 0; // no reference note at that time
  static const good = 1; // |cents| <= 50
  static const near = 2; // |cents| <= 100
  static const off = 3; // beyond
}

class LiveTrace {
  LiveTrace([int capacity = 4096])
      : _time = Float32List(capacity),
        _midi = Float32List(capacity),
        _display = Float32List(capacity),
        _cents = Float32List(capacity),
        _cat = Uint8List(capacity);

  Float32List _time;
  Float32List _midi; // raw sung pitch (NaN = unvoiced; unvoiced frames are not stored)
  Float32List _display; // pitch used for drawing (octave-aligned when enabled)
  Float32List _cents; // deviation from the reference (NaN when no reference)
  Uint8List _cat;
  int _length = 0;

  int get length => _length;
  bool get isEmpty => _length == 0;

  double timeAt(int i) => _time[i];
  double midiAt(int i) => _midi[i];
  double displayAt(int i) => _display[i];
  double centsAt(int i) => _cents[i];
  int categoryAt(int i) => _cat[i];
  double get lastTime => _length == 0 ? double.nan : _time[_length - 1];

  void clear() => _length = 0;

  void add(double time, double midi, double display, double cents, int category) {
    if (_length == _time.length) _grow();
    final i = _length++;
    _time[i] = time;
    _midi[i] = midi;
    _display[i] = display;
    _cents[i] = cents;
    _cat[i] = category;
  }

  void _grow() {
    final n = _time.length * 2;
    _time = _copy(_time, n);
    _midi = _copy(_midi, n);
    _display = _copy(_display, n);
    _cents = _copy(_cents, n);
    final c = Uint8List(n);
    c.setRange(0, _length, _cat);
    _cat = c;
  }

  static Float32List _copy(Float32List src, int n) {
    final d = Float32List(n);
    d.setRange(0, src.length, src);
    return d;
  }

  /// First index with time >= t. Times are appended in increasing order
  /// (the engine's clock is monotonic), so a binary search is valid.
  int lowerBound(double t) {
    var lo = 0, hi = _length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_time[mid] < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
}
