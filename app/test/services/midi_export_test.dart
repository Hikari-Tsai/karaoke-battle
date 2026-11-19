import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/midi_export.dart';
import 'package:karaoke_battle/state/beat_grid.dart';
import 'package:karaoke_battle/state/lyrics.dart';
import 'package:karaoke_battle/state/song_data.dart';

/// A minimal SMF reader: per track, (absolute tick, status/meta type, data).
List<List<(int, int, List<int>)>> parseTracks(Uint8List b) {
  expect(ascii.decode(b.sublist(0, 4)), 'MThd');
  final ntrk = (b[10] << 8) | b[11];
  var p = 14;
  final out = <List<(int, int, List<int>)>>[];
  int vlq() {
    var v = 0;
    while (true) {
      final c = b[p++];
      v = (v << 7) | (c & 0x7f);
      if (c & 0x80 == 0) return v;
    }
  }

  for (var t = 0; t < ntrk; t++) {
    expect(ascii.decode(b.sublist(p, p + 4)), 'MTrk');
    final len = (b[p + 4] << 24) | (b[p + 5] << 16) | (b[p + 6] << 8) | b[p + 7];
    p += 8;
    final end = p + len;
    var tick = 0;
    final ev = <(int, int, List<int>)>[];
    while (p < end) {
      tick += vlq();
      final st = b[p++];
      if (st == 0xff) {
        final type = b[p++];
        final n = vlq();
        ev.add((tick, 0xff00 | type, b.sublist(p, p + n)));
        p += n;
      } else {
        ev.add((tick, st, b.sublist(p, p + 2)));
        p += 2;
      }
    }
    out.add(ev);
  }
  return out;
}

/// Seconds at [tick] from the conductor track's tempo events.
double secondsAt(List<(int, int, List<int>)> conductor, int tick) {
  final tempos = [for (final e in conductor) if (e.$2 == 0xff51) (e.$1, (e.$3[0] << 16) | (e.$3[1] << 8) | e.$3[2])];
  var s = 0.0, last = 0, us = 500000;
  for (final (t, u) in tempos) {
    if (t >= tick) break;
    s += (t - last) / MelodyMidi.ppq * us / 1e6;
    last = t;
    us = u;
  }
  return s + (tick - last) / MelodyMidi.ppq * us / 1e6;
}

NoteList notes(List<(double, double, double)> n) => NoteList(
      Float64List.fromList([for (final e in n) e.$1]),
      Float64List.fromList([for (final e in n) e.$2]),
      Float64List.fromList([for (final e in n) e.$3]),
    );

void main() {
  test('without a grid: 120 BPM 4/4, notes at their exact times', () {
    final b = MelodyMidi.build(notes: notes([(0.5, 1.0, 60.2), (1.0, 1.75, 64.6)]), title: '歌');
    final tr = parseTracks(b);
    expect(tr, hasLength(2));
    expect(utf8.decode(tr[0].firstWhere((e) => e.$2 == 0xff03).$3), '歌');
    final on = [for (final e in tr[1]) if (e.$2 == 0x90) e];
    expect([for (final e in on) e.$3[0]], [60, 65]);
    expect([for (final e in on) e.$1], [480, 960]);
    // The repeated tick: the first note is released before the second starts.
    final at960 = [for (final e in tr[1]) if (e.$1 == 960 && e.$2 < 0xff00) e.$2];
    expect(at960, [0x80, 0x90]);
  });

  test('a drifting grid becomes a tempo map with bars on the downbeats', () {
    // Beats every 0.5 s then 0.6 s; downbeat at 1.2 s, 3 beats per bar.
    final times = [0.2, 0.7, 1.2, 1.7, 2.2, 2.8, 3.4, 4.0];
    final accents = [for (final t in times) t == 1.2 || t == 2.8];
    final grid = BeatGrid(times: times, accents: accents, beatsPerBar: 3);
    final b = MelodyMidi.build(
      notes: notes([(1.2, 1.7, 67), (2.8, 3.1, 69), (4.3, 4.6, 71)]),
      grid: grid,
      lyrics: [const LyricLine(1.2, 2.0, 'hello  world')],
    );
    final tr = parseTracks(b);
    final cond = tr[0];
    // Lead-in 0.2 s = 0.4 beat -> 3 32nds (rounded), plus 2 beats: 19/32.
    final sigs = [for (final e in cond) if (e.$2 == 0xff58) (e.$1, e.$3[0], e.$3[1])];
    expect(sigs.first, (0, 19, 5));
    final barTick = sigs[1].$1;
    expect(sigs[1].$2, 3);
    expect(secondsAt(cond, barTick), closeTo(1.2, 1e-4));
    for (final e in tr[1].where((e) => e.$2 == 0x90)) {
      final want = {67: 1.2, 69: 2.8, 71: 4.3}[e.$3[0]]!;
      expect(secondsAt(cond, e.$1), closeTo(want, 2e-3), reason: 'note ${e.$3[0]}');
    }
    // The second bar starts on the second downbeat (2.8 s).
    expect(secondsAt(cond, barTick + 3 * MelodyMidi.ppq), closeTo(2.8, 1e-4));
    final lyric = tr[1].firstWhere((e) => e.$2 == 0xff05);
    expect(utf8.decode(lyric.$3), 'hello world');
    expect(secondsAt(cond, lyric.$1), closeTo(1.2, 2e-3));
  });

  test('an even manual grid writes one tempo', () {
    final grid = BeatGrid.build(null, const TempoOverride(bpm: 100, firstBeat: 0.9), duration: 20);
    final b = MelodyMidi.build(notes: notes([(0.9, 1.5, 62), (12.3, 13, 62)]), grid: grid);
    final cond = parseTracks(b)[0];
    final tempos = [for (final e in cond) if (e.$2 == 0xff51) e];
    // The lead-in has its own tempo, then 100 BPM throughout.
    expect(tempos.length, lessThanOrEqualTo(2));
    expect((tempos.last.$3[0] << 16) | (tempos.last.$3[1] << 8) | tempos.last.$3[2], 600000);
    final on = [for (final e in parseTracks(b)[1]) if (e.$2 == 0x90) e.$1];
    expect(secondsAt(cond, on[1]), closeTo(12.3, 2e-3));
  });
}
