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
//
// Only the singer counts. With speakers the track leaks into the mic and its
// onsets fall right on the notes, so a silent singer used to collect PERFECTs.
// Every frame carries the level the speakers were playing into it, and the
// judge learns how much of that reaches the mic (the coupling: a low
// percentile of mic level minus playback level over the last few seconds,
// which the singer's own voice only ever raises) and the room's noise floor.
// A frame is "singing" only when the mic is [marginDb] above that expected
// background, and an onset counts only when singing follows it within
// [confirmSeconds]. With headphones the coupling is tiny and nothing changes.
// A pop-up is timed from the playback position it was judged at, so it plays
// its whole animation even when the frames arrive late. It is an estimate
// for the singer: the score is computed after the take from the whole
// recording.
import 'dart:collection';
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

  /// How far above the expected background (room noise plus the track
  /// leaking from the speakers) the mic must be to count as singing.
  static const marginDb = 8.0;

  /// An onset counts when a singing frame follows it within this time.
  static const confirmSeconds = 0.08;

  /// Highest room-noise floor believed (louder means the singer never paused).
  static const maxNoiseFloorDb = -45.0;

  /// Span the background is learned over, and how often it is refreshed.
  static const backgroundSeconds = 15.0;
  static const _statsEvery = 50, _statsMinFrames = 100, _couplingMinFrames = 50;

  /// Pop-ups so far, sorted by time.
  final List<JudgementMark> marks = [];

  /// How long to wait for late frames (they lag the playback by the audio
  /// latency plus one analysis window) before judging with what has arrived.
  static const maxLagSeconds = 0.6;

  final _onsets = <double>[];
  final _levelTime = <double>[];
  final _sing = <bool>[];
  double _lastFrame = double.negativeInfinity;
  int _next = 0;

  // Background model (see the header).
  final _recent = ListQueue<(double, double, double)>(); // (time, mic dB, playback dB)
  int _sinceStats = 0;
  double? _noiseDb, _couplingDb;

  /// One onset-detector frame in track time: [levelDb] is the mic level and
  /// [playbackDb] what the speakers played into this frame (-140 = nothing).
  void addFrame(double time, {required bool onset, required double levelDb, double playbackDb = -140}) {
    if (time > _lastFrame) _lastFrame = time;
    if (onset) _onsets.add(time);
    _levelTime.add(time);
    _sing.add(_isSinging(time, levelDb, playbackDb));
  }

  bool _isSinging(double time, double levelDb, double playbackDb) {
    _recent.addLast((time, levelDb, playbackDb));
    while (_recent.first.$1 < time - backgroundSeconds) {
      _recent.removeFirst();
    }
    if (_recent.length >= _statsMinFrames && (_noiseDb == null || ++_sinceStats >= _statsEvery)) {
      _sinceStats = 0;
      _updateBackground();
    }
    if (levelDb < levelFloorDb) return false;
    final noise = _noiseDb;
    if (noise == null) return true;
    var bg = _dbToPower(noise);
    final c = _couplingDb;
    if (c != null && playbackDb > -100) bg += _dbToPower(playbackDb + c);
    return levelDb >= 10 * math.log(bg) / math.ln10 + marginDb;
  }

  void _updateBackground() {
    final mic = [for (final r in _recent) r.$2];
    // Capped: a "floor" this loud is the singer holding on, not the room.
    _noiseDb = math.min(_percentile(mic, 0.05), maxNoiseFloorDb);
    final play = [for (final r in _recent) r.$3];
    final mid = _percentile(play, 0.5);
    final diff = [
      for (final r in _recent)
        if (r.$3 >= mid && r.$3 > -60) r.$2 - r.$3,
    ];
    _couplingDb = diff.length >= _couplingMinFrames ? _percentile(diff, 0.2) : null;
  }

  static double _dbToPower(double db) => math.pow(10, db / 10).toDouble();

  static double _percentile(List<double> v, double q) {
    v.sort();
    return v[((v.length - 1) * q).round()];
  }

  /// Judges every note whose onset has arrived (or whose window has closed)
  /// at playback position [pos]; returns true when a pop-up was added.
  bool update(double pos) {
    var added = false;
    while (_next < notes.length) {
      final i = _next;
      final from = _searchFrom(i), to = _searchTo(i);
      final timedOut = pos >= to + maxLagSeconds;
      final (found, pending) = _firstSungOnset(from, to, timedOut);
      if (pending || (found == null && _lastFrame < to && !timedOut)) break;
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

  /// The first onset in [from, to] the singer made (a singing frame follows
  /// it within [confirmSeconds]); pending while that cannot be told yet.
  (double?, bool) _firstSungOnset(double from, double to, bool timedOut) {
    for (var k = _lowerBound(_onsets, from); k < _onsets.length && _onsets[k] <= to; k++) {
      final t = _onsets[k];
      if (_sangDuring(t, t + confirmSeconds)) return (t, false);
      if (_lastFrame < t + confirmSeconds && !timedOut) return (null, true);
    }
    return (null, false);
  }

  JudgementMark? _judge(int i, double? found, double shownAt, double from, double to) {
    final midi = notes.pitch[i] + pitchShift;
    if (found == null) {
      if (_sangDuring(from, math.max(to, notes.onset[i]))) return null;
      return JudgementMark.forNote(time: shownAt, midi: midi, timing: 'miss', anchor: notes.onset[i]);
    }
    final err = found - notes.onset[i];
    return JudgementMark.forNote(
      time: shownAt,
      midi: midi,
      timing: windows.classify(err.abs()).name,
      onsetErrorMs: err * 1000,
      anchor: notes.onset[i],
    );
  }

  bool _sangDuring(double from, double to) {
    for (var k = _lowerBound(_levelTime, from); k < _levelTime.length && _levelTime[k] <= to; k++) {
      if (_sing[k]) return true;
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
      _sing.clear();
      return;
    }
    final keepFrom = _searchFrom(_next) - 0.1;
    final k = _lowerBound(_levelTime, keepFrom);
    if (k > 1024) {
      _levelTime.removeRange(0, k);
      _sing.removeRange(0, k);
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
