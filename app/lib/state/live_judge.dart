// Real-time rhythm-game judgements while recording, from onsets only: the
// engine's onset detector (spectral flux on ~21 ms windows every 5 ms,
// source = 2 frames) reports when the singer starts a syllable, and each
// reference note is judged on timing alone (PERFECT / GREAT / GOOD with
// FAST / LATE). No pitch estimate is waited for, so the pop-up comes up
// about one analysis window after the sound instead of ~0.2 s. HIGH / LOW is
// left to the replay, which judges from the scored recording.
//
// For each reference note:
// * its search window runs from the note onset minus the GOOD window to the
//   onset plus the GOOD window, cut halfway to the neighbouring notes' onsets
//   so one sung onset is not claimed by two notes;
// * the first detected onset inside the window judges the note at once;
// * with no onset by the end of the window it is a MISS when the singer was
//   silent, and no pop-up when they were singing (a note joined to the
//   previous one without a new syllable has no onset to detect).
// A pop-up is timed from the playback position it was judged at, so it plays
// its whole animation even when the frames arrive late. It is an estimate
// for the singer: the score is computed after the take from the whole
// recording.
import 'dart:math' as math;

import '../scoring/rhythm.dart';
import '../ui/widgets/judgement_popups.dart';
import 'song_data.dart';

class LiveJudge {
  LiveJudge({required this.notes, required this.windows, this.pitchShift = 0, this.levelFloorDb = -50});

  final NoteList notes;
  final RhythmWindows windows;

  /// Key shift in semitones (only moves where the pop-up is drawn).
  double pitchShift;

  /// Frames at or above this level count as singing (the noise gate when on).
  double levelFloorDb;

  /// Pop-ups so far, sorted by time.
  final List<JudgementMark> marks = [];

  /// How long to wait for late frames (they lag the playback by the audio
  /// latency plus one analysis window) before judging with what has arrived.
  static const maxLagSeconds = 0.6;

  final _onsets = <double>[];
  final _levelTime = <double>[];
  final _levelDb = <double>[];
  double _lastFrame = double.negativeInfinity;
  int _next = 0;

  /// One onset-detector frame in track time.
  void addFrame(double time, {required bool onset, required double levelDb}) {
    if (time > _lastFrame) _lastFrame = time;
    if (onset) _onsets.add(time);
    _levelTime.add(time);
    _levelDb.add(levelDb);
  }

  /// Judges every note whose onset has arrived (or whose window has closed)
  /// at playback position [pos]; returns true when a pop-up was added.
  bool update(double pos) {
    var added = false;
    while (_next < notes.length) {
      final i = _next;
      final from = _searchFrom(i), to = _searchTo(i);
      final found = _firstOnset(from, to);
      if (found == null && _lastFrame < to && pos < to + maxLagSeconds) break;
      final mark = _judge(i, found, math.max(found ?? to, pos), from, to);
      if (mark != null) {
        _insert(mark);
        added = true;
      }
      _next++;
    }
    _prune();
    return added;
  }

  double _searchFrom(int i) {
    final onset = notes.onset[i];
    final from = onset - windows.good;
    return i > 0 ? math.max(from, (notes.onset[i - 1] + onset) / 2) : from;
  }

  double _searchTo(int i) {
    final onset = notes.onset[i];
    final to = onset + windows.good;
    return i + 1 < notes.length ? math.min(to, (onset + notes.onset[i + 1]) / 2) : to;
  }

  double? _firstOnset(double from, double to) {
    final k = _lowerBound(_onsets, from);
    return k < _onsets.length && _onsets[k] <= to ? _onsets[k] : null;
  }

  JudgementMark? _judge(int i, double? found, double shownAt, double from, double to) {
    final midi = notes.pitch[i] + pitchShift;
    if (found == null) {
      if (_sangDuring(from, math.max(to, notes.onset[i]))) return null;
      return JudgementMark.forNote(time: shownAt, midi: midi, timing: 'miss');
    }
    final err = found - notes.onset[i];
    return JudgementMark.forNote(
      time: shownAt,
      midi: midi,
      timing: windows.classify(err.abs()).name,
      onsetErrorMs: err * 1000,
    );
  }

  bool _sangDuring(double from, double to) {
    for (var k = _lowerBound(_levelTime, from); k < _levelTime.length && _levelTime[k] <= to; k++) {
      if (_levelDb[k] >= levelFloorDb) return true;
    }
    return false;
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
      _onsets.clear();
      _levelTime.clear();
      _levelDb.clear();
      return;
    }
    final keepFrom = _searchFrom(_next) - 0.1;
    final k = _lowerBound(_levelTime, keepFrom);
    if (k > 1024) {
      _levelTime.removeRange(0, k);
      _levelDb.removeRange(0, k);
    }
    final o = _lowerBound(_onsets, keepFrom);
    if (o > 64) _onsets.removeRange(0, o);
  }

  static int _lowerBound(List<double> v, double t) {
    var lo = 0, hi = v.length;
    while (lo < hi) {
      final m = (lo + hi) >> 1;
      if (v[m] < t) {
        lo = m + 1;
      } else {
        hi = m;
      }
    }
    return lo;
  }
}
