// Real-time rhythm-game judgements while recording: the same tiers and the
// same timing + pitch combination as the replay pop-ups
// (JudgementMark.forNote), estimated from the live pitch frames.
//
// For each reference note, once the frames up to its judgement time have
// arrived:
// * onset: the start of the first in-tune run (chroma within half a
//   semitone of the note, at least [minRunSeconds] long) that begins within
//   the note's GOOD window (not before the previous note ends); its error
//   gives PERFECT / GREAT / GOOD, no such run is a MISS;
// * pitch: the median chroma deviation of the voiced frames from the onset
//   to the judgement time.
// The judgement time is [pitchSeconds] after the onset (the GOOD window if
// that is longer, the note's end if it is shorter), so the pop-up comes up
// shortly after each note starts. It is an estimate for the singer: the
// score is computed after the take from the whole recording.
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
  static const pitchSeconds = 0.3;

  /// How long to wait for late frames (pitch tracking lags the playback)
  /// before judging with what has arrived.
  static const maxLagSeconds = 0.3;

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

  double judgeTime(int i) {
    final dur = notes.offset[i] - notes.onset[i];
    return notes.onset[i] + math.max(windows.good, math.min(dur, pitchSeconds));
  }

  /// Judges every note whose judgement time has been reached at playback
  /// position [pos]; returns true when a pop-up was added.
  bool update(double pos) {
    var added = false;
    while (_next < notes.length) {
      final at = judgeTime(_next);
      if (_lastFrame < at && pos < at + maxLagSeconds) break;
      _insert(_judge(_next, at));
      _next++;
      added = true;
    }
    if (added) _prune();
    return added;
  }

  JudgementMark _judge(int i, double at) {
    final onset = notes.onset[i], offset = notes.offset[i];
    final ref = notes.pitch[i] + pitchShift;
    final from = math.max(onset - windows.good, i > 0 ? math.min(notes.offset[i - 1], onset) : double.negativeInfinity);
    final to = math.min(onset + windows.good, offset);
    double? runStart;
    double? found;
    double lastIn = double.negativeInfinity;
    for (var k = _lowerBound(from); k < _time.length; k++) {
      final t = _time[k];
      if (t > to + minRunSeconds + maxGapSeconds) break;
      if (chromaDelta(_midi[k], ref).abs() <= 0.5) {
        if (runStart == null || t - lastIn > maxGapSeconds) {
          if (t > to) break;
          runStart = t;
        }
        lastIn = t;
        if (lastIn - runStart >= minRunSeconds - 1e-9) {
          found = runStart;
          break;
        }
      } else {
        runStart = null;
      }
    }
    final errMs = found == null ? null : (found - onset) * 1000;
    final timing = errMs == null ? 'miss' : windows.classify(errMs.abs() / 1000).name;
    final cents = <double>[];
    final end = math.min(at, offset);
    for (var k = _lowerBound(onset); k < _time.length && _time[k] <= end; k++) {
      cents.add(chromaDelta(_midi[k], ref) * 100);
    }
    return JudgementMark.forNote(
      time: at,
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
