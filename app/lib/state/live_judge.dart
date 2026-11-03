// Real-time rhythm-game judgements while recording: the same tiers and the
// same timing + pitch combination as the replay pop-ups
// (JudgementMark.forNote), estimated from the live pitch frames. The live
// session feeds it the low-latency MPM frames (~0.07 s behind the sound), not
// SwiftF0's (~0.3 s); the replay keeps judging from the scored recording.
//
// For each reference note:
// * onset: the start of the first in-tune run (chroma within half a
//   semitone of the note, at least [minRunSeconds] long) that begins within
//   the note's GOOD window (not before the previous note ends); its error
//   gives PERFECT / GREAT / GOOD;
// * pitch: the median chroma deviation of the voiced frames over the
//   [pitchSeconds] after that onset (up to the note's end);
// * it is judged as soon as the frames up to the end of that pitch window
//   have arrived, so the pop-up comes up about 0.2 s after the singer comes
//   in. With no in-tune run by the end of the window it is a MISS, judged
//   when the search window closes.
// A pop-up is timed from the playback position it was judged at, so it plays
// its whole animation even when the frames arrive late. It is an estimate
// for the singer: the score is computed after the take from the whole
// recording.
import 'dart:math' as math;

import '../scoring/models.dart' show chromaDelta;
import '../scoring/rhythm.dart';
import '../ui/widgets/judgement_popups.dart';
import 'song_data.dart';

class LiveJudge {
  LiveJudge({required this.notes, required this.windows, this.pitchShift = 0});

  final NoteList notes;
  final RhythmWindows windows;

  /// Key shift in semitones (the sung pitch is compared with note + shift).
  double pitchShift;

  /// Pop-ups so far, sorted by time.
  final List<JudgementMark> marks = [];

  static const minRunSeconds = 0.04;
  static const maxGapSeconds = 0.05;
  static const pitchSeconds = 0.12;

  /// How long to wait for late frames (pitch tracking lags the playback by
  /// the audio latency plus the tracker's own delay) before judging with
  /// what has arrived.
  static const maxLagSeconds = 0.6;

  final _time = <double>[];
  final _midi = <double>[];
  double _lastFrame = double.negativeInfinity;
  int _next = 0;

  /// One pitch frame in track time; [midi] is NaN when unvoiced.
  void addFrame(double time, double midi) {
    if (time > _lastFrame) _lastFrame = time;
    if (midi.isNaN) return;
    _time.add(time);
    _midi.add(midi);
  }

  /// Judges every note whose frames have arrived (or whose wait for late
  /// frames has run out) at playback position [pos]; returns true when a
  /// pop-up was added.
  bool update(double pos) {
    var added = false;
    while (_next < notes.length) {
      final i = _next;
      final found = _findOnset(i);
      // Judged at the end of the pitch window after the onset, or when the
      // onset search closes without one.
      final at = found != null ? _pitchEnd(i, found) : _searchEnd(i);
      if (_lastFrame < at && pos < at + maxLagSeconds) break;
      _insert(_judge(i, found, at, math.max(at, pos)));
      _next++;
      added = true;
    }
    if (added) _prune();
    return added;
  }

  double _searchFrom(int i) {
    final onset = notes.onset[i];
    return math.max(onset - windows.good, i > 0 ? math.min(notes.offset[i - 1], onset) : double.negativeInfinity);
  }

  /// Latest start of an in-tune run that still counts as the onset.
  double _searchTo(int i) => math.min(notes.onset[i] + windows.good, notes.offset[i]);

  /// Frame time after which no onset run can be found any more.
  double _searchEnd(int i) => _searchTo(i) + minRunSeconds + maxGapSeconds;

  double _pitchEnd(int i, double found) => math.max(found + minRunSeconds, math.min(found + pitchSeconds, notes.offset[i]));

  /// Start of the first in-tune run of note [i] among the frames so far.
  double? _findOnset(int i) {
    final ref = notes.pitch[i] + pitchShift;
    final to = _searchTo(i);
    double? runStart;
    double lastIn = double.negativeInfinity;
    for (var k = _lowerBound(_searchFrom(i)); k < _time.length; k++) {
      final t = _time[k];
      if (t > to + minRunSeconds + maxGapSeconds) break;
      if (chromaDelta(_midi[k], ref).abs() <= 0.5) {
        if (runStart == null || t - lastIn > maxGapSeconds) {
          if (t > to) break;
          runStart = t;
        }
        lastIn = t;
        if (lastIn - runStart >= minRunSeconds - 1e-9) return runStart;
      } else {
        runStart = null;
      }
    }
    return null;
  }

  JudgementMark _judge(int i, double? found, double at, double shownAt) {
    final ref = notes.pitch[i] + pitchShift;
    final errMs = found == null ? null : (found - notes.onset[i]) * 1000;
    final timing = errMs == null ? 'miss' : windows.classify(errMs.abs() / 1000).name;
    final cents = <double>[];
    if (found != null) {
      for (var k = _lowerBound(found); k < _time.length && _time[k] <= at; k++) {
        cents.add(chromaDelta(_midi[k], ref) * 100);
      }
    }
    return JudgementMark.forNote(
      time: shownAt,
      midi: ref,
      timing: timing,
      onsetErrorMs: errMs,
      cents: cents.isEmpty ? null : _median(cents),
    );
  }

  void _insert(JudgementMark m) {
    var i = marks.length;
    while (i > 0 && marks[i - 1].time > m.time) {
      i--;
    }
    marks.insert(i, m);
  }

  /// Drops frames no pending note can look at any more.
  void _prune() {
    if (_next >= notes.length) {
      _time.clear();
      _midi.clear();
      return;
    }
    final keepFrom = notes.onset[_next] - windows.good - 1.0;
    final k = _lowerBound(keepFrom);
    if (k > 512) {
      _time.removeRange(0, k);
      _midi.removeRange(0, k);
    }
  }

  int _lowerBound(double t) {
    var lo = 0, hi = _time.length;
    while (lo < hi) {
      final m = (lo + hi) >> 1;
      if (_time[m] < t) {
        lo = m + 1;
      } else {
        hi = m;
      }
    }
    return lo;
  }

  static double _median(List<double> v) {
    v.sort();
    final m = v.length ~/ 2;
    return v.length.isOdd ? v[m] : (v[m - 1] + v[m]) / 2;
  }
}
