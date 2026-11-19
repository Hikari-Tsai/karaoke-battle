// Standard MIDI File export of a song's reference melody (the notes the
// MIDI guide plays), with a tempo map from the beat grid and the lyrics as
// lyric events, so it lines up with the song when dropped into a DAW.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../state/beat_grid.dart';
import '../state/lyrics.dart';
import '../state/song_data.dart';
import 'song_library.dart';

class MelodyMidi {
  static const ppq = 480;

  /// Loads the song's notes, beats, tempo override and lyrics and builds the
  /// file. Null when the song has no notes.
  static Future<Uint8List?> forSong(SongFiles f, {required String title}) async {
    final notes = await NoteList.load(f.notesJson);
    if (notes.isEmpty) return null;
    final lyrics = await _loadLyrics(f.lyricsJson);
    final end = math.max(notes.endTime, lyrics.isEmpty ? 0.0 : lyrics.last.end) + 1;
    final grid = BeatGrid.build(await DetectedBeats.load(f.beatsJson), await TempoOverride.load(f.tempoJson), duration: end);
    return build(notes: notes, grid: grid, lyrics: lyrics, title: title);
  }

  static Future<List<LyricLine>> _loadLyrics(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return const [];
      final l = Lyrics.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
      return l.primaryTrack?.shownLines ?? const [];
    } catch (_) {
      return const [];
    }
  }

  /// Format 1, two tracks: the conductor (title, tempo map, time signatures)
  /// and the melody (lyric events at each line start, then the notes).
  ///
  /// Every grid beat becomes a quarter note, so the tempo map follows the
  /// detected (possibly drifting) beats and the bars fall on the downbeats;
  /// the time before the first downbeat is a pickup bar. Without a grid the
  /// file runs at 120 BPM in 4/4. Notes keep their exact times either way.
  static Uint8List build({required NoteList notes, BeatGrid grid = BeatGrid.empty, List<LyricLine> lyrics = const [], String? title}) {
    final map = TickMap.fromGrid(grid);

    final conductor = <_Event>[];
    if (title != null && title.isNotEmpty) conductor.add(_Event(0, 0, _meta(0x03, utf8.encode(title))));
    for (final (tick, num, denPow) in map.signatures) {
      conductor.add(_Event(tick, 1, _meta(0x58, [num, denPow, 24, 8])));
    }
    for (final (tick, us) in map.tempos) {
      conductor.add(_Event(tick, 2, _meta(0x51, [(us >> 16) & 0xff, (us >> 8) & 0xff, us & 0xff])));
    }

    final melody = <_Event>[_Event(0, 0, _meta(0x03, utf8.encode('Melody')))];
    for (final l in lyrics) {
      final text = l.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty || l.start < 0) continue;
      melody.add(_Event(map.tick(l.start), 2, _meta(0x05, utf8.encode(text))));
    }
    final n = notes.length;
    for (var i = 0; i < n; i++) {
      final pitch = notes.pitch[i].round().clamp(0, 127);
      final on = map.tick(notes.onset[i]);
      var off = map.tick(notes.offset[i]);
      // The same key struck again before this one is released: end it there.
      for (var j = i + 1; j < n && notes.onset[j] < notes.offset[i]; j++) {
        if (notes.pitch[j].round().clamp(0, 127) == pitch) off = math.min(off, map.tick(notes.onset[j]));
      }
      if (off <= on) off = on + 1;
      melody.add(_Event(on, 3, [0x90, pitch, 100]));
      melody.add(_Event(off, 1, [0x80, pitch, 0]));
    }

    final out = BytesBuilder();
    out.add(ascii.encode('MThd'));
    out.add(_u32(6));
    out.add([0, 1, 0, 2, ppq >> 8, ppq & 0xff]);
    for (final t in [conductor, melody]) {
      out.add(_track(t));
    }
    return out.toBytes();
  }

  static List<int> _meta(int type, List<int> data) => [0xff, type, ..._vlq(data.length), ...data];

  static List<int> _track(List<_Event> events) {
    // Stable sort: ties keep their kind order (note-offs before lyrics
    // before note-ons, so a repeated note is released before it restarts).
    final sorted = [for (var i = 0; i < events.length; i++) (i, events[i])]
      ..sort((a, b) {
        final c = a.$2.tick.compareTo(b.$2.tick);
        if (c != 0) return c;
        final o = a.$2.order.compareTo(b.$2.order);
        return o != 0 ? o : a.$1.compareTo(b.$1);
      });
    final body = BytesBuilder();
    var last = 0;
    for (final (_, e) in sorted) {
      body.add(_vlq(e.tick - last));
      body.add(e.bytes);
      last = e.tick;
    }
    body.add([0x00, 0xff, 0x2f, 0x00]);
    final b = body.toBytes();
    return [...ascii.encode('MTrk'), ..._u32(b.length), ...b];
  }

  static List<int> _u32(int v) => [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];

  static List<int> _vlq(int v) {
    final out = <int>[v & 0x7f];
    v >>= 7;
    while (v > 0) {
      out.insert(0, (v & 0x7f) | 0x80);
      v >>= 7;
    }
    return out;
  }
}

class _Event {
  _Event(this.tick, this.order, this.bytes);
  final int tick;
  final int order;
  final List<int> bytes;
}

/// Seconds to ticks along a beat grid: piecewise linear between the grid's
/// points (one quarter note per beat), extended with the last segment's rate.
class TickMap {
  TickMap._(this._times, this._ticks, this._rateAfter, this.tempos, this.signatures);

  final List<double> _times;
  final List<int> _ticks;
  final double _rateAfter; // ticks per second past the last point

  /// (tick, microseconds per quarter), consecutive duplicates dropped.
  final List<(int, int)> tempos;

  /// (tick, numerator, denominator as a power of two).
  final List<(int, int, int)> signatures;

  static const _ppq = MelodyMidi.ppq;

  factory TickMap.fromGrid(BeatGrid grid) {
    final perBar = grid.beatsPerBar.clamp(1, 16);
    final times = <double>[], accents = <bool>[];
    for (var i = 0; i < grid.times.length; i++) {
      if (grid.times[i] < 0 || (times.isNotEmpty && grid.times[i] <= times.last)) continue;
      times.add(grid.times[i]);
      accents.add(i < grid.accents.length && grid.accents[i]);
    }
    if (times.length < 2) {
      // No usable grid: 120 BPM, 4/4 from the start.
      return TickMap._(const [0.0], const [0], 2.0 * _ppq, const [(0, 500000)], [(0, perBar, 2)]);
    }
    // Extend the grid back towards 0 s so the lead-in is at most one beat.
    final period = times[1] - times[0];
    while (times.first - period > 1e-3) {
      times.insert(0, times.first - period);
      accents.insert(0, false);
    }
    // The lead-in before the first beat, in 32nd notes at that beat's tempo
    // (its own tempo event makes it last exactly that long).
    final lead = times.first < 1e-3 ? 0 : math.max(1, (times.first / period * 8).round());
    final t0 = lead * _ppq ~/ 8;
    final pts = <double>[], ks = <int>[];
    if (lead > 0) {
      pts.add(0);
      ks.add(0);
    }
    for (var i = 0; i < times.length; i++) {
      pts.add(lead == 0 && i == 0 ? 0.0 : times[i]);
      ks.add(t0 + i * _ppq);
    }

    final tempos = <(int, int)>[];
    for (var i = 0; i + 1 < pts.length; i++) {
      final quarters = (ks[i + 1] - ks[i]) / _ppq;
      final us = ((pts[i + 1] - pts[i]) * 1e6 / quarters).round().clamp(1, 0xffffff);
      if (tempos.isEmpty || tempos.last.$2 != us) tempos.add((ks[i], us));
    }

    // Bars from the first downbeat (counted in whole bars after it); the
    // lead-in and the beats before it form a pickup bar.
    var a = accents.indexOf(true);
    a = a < 0 ? 0 : a % perBar;
    final pickup32 = lead + 8 * a;
    final signatures = <(int, int, int)>[];
    if (pickup32 > 0) {
      var num = pickup32, pow = 5;
      while (num.isEven && pow > 2) {
        num ~/= 2;
        pow--;
      }
      signatures.add((0, num, pow));
    }
    signatures.add((t0 + a * _ppq, perBar, 2));

    final n = pts.length;
    final rate = (ks[n - 1] - ks[n - 2]) / (pts[n - 1] - pts[n - 2]);
    return TickMap._(pts, ks, rate, tempos, signatures);
  }

  int tick(double t) {
    if (t <= 0) return 0;
    var lo = 0, hi = _times.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_times[mid] <= t) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    if (lo == _times.length - 1) return (_ticks[lo] + (t - _times[lo]) * _rateAfter).round();
    final f = (t - _times[lo]) / (_times[lo + 1] - _times[lo]);
    return (_ticks[lo] + f * (_ticks[lo + 1] - _ticks[lo])).round();
  }
}
