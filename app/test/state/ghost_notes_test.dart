import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/state/energy_curve.dart';
import 'package:karaoke_battle/state/ghost_notes.dart';
import 'package:karaoke_battle/state/lyrics.dart';
import 'package:karaoke_battle/state/note_edits.dart';
import 'package:karaoke_battle/state/song_data.dart';

void main() {
  // (pitch, seconds) laid end to end.
  List<(double, double, double)> lay(List<(double, double)> notes) {
    final out = <(double, double, double)>[];
    var t = 0.0;
    for (final (p, d) in notes) {
      out.add((t, t + d, p));
      t += d;
    }
    return out;
  }

  NoteList list(List<(double, double, double)> n) => NoteList(
        Float64List.fromList([for (final e in n) e.$1]),
        Float64List.fromList([for (final e in n) e.$2]),
        Float64List.fromList([for (final e in n) e.$3]),
      );

  // A melody around C4..A4 (60..69).
  final verse = [for (var i = 0; i < 20; i++) ((60 + (i * 3) % 10).toDouble(), 0.5)];

  test('an octave slip outside the range is a ghost; a melodic leap inside it is not', () {
    final n = list(lay([...verse.sublist(0, 10), (47.0, 0.2), ...verse.sublist(10)]));
    expect(findGhostNotes(n), [10]);
    // A repeated low phrase inside the song's range stays.
    final low = [for (var i = 0; i < 6; i++) (57.0, 0.5)];
    expect(findGhostNotes(list(lay([...verse, ...low, ...verse]))), isEmpty);
  });

  test('impossible pitches and far isolated notes are ghosts', () {
    final n = list([
      (0, 1, 34), // A#1: below any voice
      ...[for (final e in lay(verse)) (e.$1 + 10, e.$2 + 10, e.$3)],
      (60, 60.5, 45), // alone at the end, far below the range
    ]);
    expect(findGhostNotes(n), [0, n.length - 1]);
  });

  test('cleaning rewrites notes.json once, masks the spans, keeps take copies', () async {
    final dir = await Directory.systemTemp.createTemp('ghosts');
    try {
      final notes = '${dir.path}/notes.json';
      final take = Directory('${dir.path}/take1')..createSync();
      final n = lay([...verse.sublist(0, 10), (47.0, 0.2), ...verse.sublist(10)]);
      await File(notes).writeAsString(jsonEncode({
        'notes': [for (final e in n) {'onset': e.$1, 'offset': e.$2, 'pitch': e.$3}],
        'excluded_spans': [[100.0, 101.0]],
      }));
      expect(await cleanSongGhostNotes(notes, [take.path]), 1);
      final j = jsonDecode(await File(notes).readAsString()) as Map<String, dynamic>;
      expect((j['notes'] as List).length, n.length - 1);
      expect(j['ghosts_v'], ghostsVersion);
      expect((j['ghost_notes'] as List).single['pitch'], 47.0);
      expect(excludedSpansFromJson(j), [(100.0, 101.0), (n[10].$1, n[10].$2)]);
      // The take keeps what it was scored against (with the ghost).
      final kept = jsonDecode(await File('${take.path}/notes.json').readAsString()) as Map;
      expect((kept['notes'] as List).length, n.length);
      // Only once.
      expect(await cleanSongGhostNotes(notes, [take.path]), 0);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  // --- subtitle windows -----------------------------------------------------

  Lyrics subs(List<(double, double)> lines, {bool auto = false, LyricSource source = LyricSource.youtube, double offset = 0}) => Lyrics(tracks: [
        LyricTrack(lang: 'zh-TW', auto: auto, source: source, offset: offset, lines: [for (final l in lines) LyricLine(l.$1, l.$2, 'x')]),
      ]);

  test('subtitle windows: the uploader\'s lines, widened and merged', () {
    final w = subtitleWindows(subs([(10, 14), (15, 18), (40, 44)]));
    expect(w, [(10 - subtitleMargin, 18 + subtitleMargin), (40 - subtitleMargin, 44 + subtitleMargin)]);
    // The user's sync offset moves them.
    expect(subtitleWindows(subs([(10, 14)], offset: 2)), [(12 - subtitleMargin, 16 + subtitleMargin)]);
    // Automatic captions and lyrics that did not come with the video do not count.
    expect(subtitleWindows(subs([(10, 14)], auto: true)), isEmpty);
    for (final src in [LyricSource.whisper, LyricSource.aligned, LyricSource.imported, LyricSource.edited, LyricSource.manual]) {
      expect(subtitleWindows(subs([(10, 14)], source: src)), isEmpty);
    }
    expect(subtitleWindows(Lyrics.empty()), isEmpty);
  });

  test('notes outside every subtitle line are ghosts; the margin and held notes are kept', () {
    // Verse sung from 20 s to 30 s; subtitles show 20..30.
    final sung = [for (final e in lay(verse)) (e.$1 + 20, e.$2 + 20, e.$3)];
    final n = list([
      (5, 5.5, 64), // intro: an instrument read as a note, in the song's range
      (19, 19.4, 62), // pick-up, 1 s before the line appears: inside the margin
      ...sung,
      (31, 36, 65), // last note held long after the line is gone: starts inside the margin
      (45, 45.5, 63), // outro
    ]);
    final w = subtitleWindows(subs([(20, 30)]));
    expect(findGhostNotes(n, sungWindows: w), [0, n.length - 1]);
    // Without subtitles nothing here is a ghost.
    expect(findGhostNotes(n), isEmpty);
  });

  test('the subtitle rule is held back when it would remove too much', () {
    // Subtitles only cover the first verse of two: 50% would go.
    final first = lay(verse);
    final second = [for (final e in first) (e.$1 + 60, e.$2 + 60, e.$3)];
    final n = list([...first, ...second]);
    final w = subtitleWindows(subs([(0, 10)]));
    expect(notesOutsideWindows(n, w), isNull);
    expect(findGhostNotes(n, sungWindows: w), isEmpty);
    // A short stray passage (under the limit) does go.
    final stray = list([...first, (60, 61, 62)]);
    expect(notesOutsideWindows(stray, w), [first.length]);
  });

  test('cleaning uses lyrics.json, and adds only the subtitle rule to a song cleaned before', () async {
    final dir = await Directory.systemTemp.createTemp('ghosts');
    try {
      final notes = '${dir.path}/notes.json', lyrics = '${dir.path}/lyrics.json';
      final sung = [for (final e in lay(verse)) (e.$1 + 20, e.$2 + 20, e.$3)];
      final all = [(5.0, 5.5, 64.0), ...sung, (45.0, 45.5, 63.0)];
      Future<void> write(Map<String, dynamic> extra) => File(notes).writeAsString(jsonEncode({
            'notes': [for (final e in all) {'onset': e.$1, 'offset': e.$2, 'pitch': e.$3}],
            ...extra,
          }));
      Future<Map<String, dynamic>> read() async => jsonDecode(await File(notes).readAsString()) as Map<String, dynamic>;

      // No lyrics.json yet (the subtitles could not be fetched): pitch rules only.
      await write({});
      expect(await cleanSongGhostNotes(notes, const [], lyricsJson: lyrics), 0);
      var j = await read();
      expect(j['ghosts_v'], ghostsVersion);
      expect(j['ghosts_subs'], isNull);

      // The subtitles arrive: the song is cleaned again, with them.
      await File(lyrics).writeAsString(jsonEncode(subs([(20, 30)]).toJson()));
      expect(await cleanSongGhostNotes(notes, const [], lyricsJson: lyrics), 2);
      j = await read();
      expect(j['ghosts_subs'], true);
      expect((j['notes'] as List).length, sung.length);
      expect([for (final g in j['ghost_notes'] as List) (g as Map)['onset']], [5.0, 45.0]);
      expect(excludedSpansFromJson(j), [(5.0, 5.5), (45.0, 45.5)]);
      // Only once.
      expect(await cleanSongGhostNotes(notes, const [], lyricsJson: lyrics), 0);

      // A song cleaned by version 1 gets the subtitle rule and the new version.
      await write({'ghosts_v': 1});
      expect(await cleanSongGhostNotes(notes, const [], lyricsJson: lyrics), 2);
      j = await read();
      expect(j['ghosts_v'], ghostsVersion);
      expect(j['ghosts_subs'], true);

      // Held back (subtitles cover too little): nothing is removed, and it is tried again later.
      await File(lyrics).writeAsString(jsonEncode(subs([(20, 22)]).toJson()));
      await write({});
      expect(await cleanSongGhostNotes(notes, const [], lyricsJson: lyrics), 0);
      j = await read();
      expect((j['notes'] as List).length, all.length);
      expect(j['ghosts_subs'], isNull);
      await File(lyrics).writeAsString(jsonEncode(subs([(20, 30)]).toJson()));
      expect(await cleanSongGhostNotes(notes, const [], lyricsJson: lyrics), 2);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  // --- quiet notes ------------------------------------------------------------

  // An RMS curve (16 ms hops) that is [db(t)] at time t.
  EnergyData curve(double seconds, double Function(double t) db) {
    const hop = 0.016;
    final n = (seconds / hop).ceil();
    return EnergyData([for (var i = 0; i < n; i++) i * hop], [for (var i = 0; i < n; i++) db(i * hop)]);
  }

  test('note levels are the mean power of the stem under each note', () {
    final e = curve(4, (t) => t < 2 ? -20 : -40);
    final n = list([(0.5, 1.5, 60), (2.5, 3.5, 60), (1.0, 3.0, 60)]);
    final lv = noteLevelsDb(n, e);
    expect(lv[0], closeTo(-20, 0.01));
    expect(lv[1], closeTo(-40, 0.01));
    // Half loud, half quiet: the loud half carries the mean power (-23 dB).
    expect(lv[2], closeTo(-22.97, 0.2));
  });

  test('a note far below the median note level is a ghost, whatever its pitch', () {
    final sung = [for (final e in lay(verse)) (e.$1 + 20, e.$2 + 20, e.$3)];
    final n = list([(5, 5.5, 64), ...sung, (45, 45.5, 63)]);
    // The stem is at -20 dB while the verse is sung; the intro note is a leak
    // at -45 dB; the last note is soft singing at -28 dB.
    final lv = noteLevelsDb(n, curve(50, (t) => t < 10 ? -45 : t < 40 ? -20 : -28));
    expect(notesTooQuiet(n, lv), [0]);
    expect(findGhostNotes(n, levels: lv), [0]);
    expect(findGhostNotes(n), isEmpty);
    expect(notesTooQuiet(n, null), isNull);
  });

  test('the quiet-note rule is held back when a whole soft section would go', () {
    // A soft first verse 20 dB under a loud second one that is three times as long.
    final soft = lay(verse);
    final loud = [for (var k = 0; k < 3; k++) for (final e in soft) (e.$1 + 20 + 12 * k, e.$2 + 20 + 12 * k, e.$3)];
    final n = list([...soft, ...loud]);
    final lv = noteLevelsDb(n, curve(70, (t) => t < 15 ? -40 : -20));
    expect(notesTooQuiet(n, lv), isNull);
    expect(findGhostNotes(n, levels: lv), isEmpty);
  });

  // A 16-bit mono WAV at 8 kHz whose amplitude is [amp(t)].
  Future<void> writeWav(String path, double seconds, double Function(double t) amp) async {
    const sr = 8000;
    final n = (seconds * sr).round();
    final b = BytesBuilder();
    void u32(int v) => b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
    void u16(int v) => b.add((ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List());
    b.add('RIFF'.codeUnits);
    u32(36 + n * 2);
    b.add('WAVEfmt '.codeUnits);
    u32(16);
    u16(1);
    u16(1);
    u32(sr);
    u32(sr * 2);
    u16(2);
    u16(16);
    b.add('data'.codeUnits);
    u32(n * 2);
    final d = ByteData(n * 2);
    for (var i = 0; i < n; i++) {
      // A square wave: its RMS is its amplitude.
      d.setInt16(i * 2, ((i ~/ 10).isEven ? 1 : -1) * (amp(i / sr) * 32767).round(), Endian.little);
    }
    b.add(d.buffer.asUint8List());
    await File(path).writeAsBytes(b.toBytes());
  }

  test('cleaning reads vocals.wav; a song cleaned by version 1 gets the quiet-note rule once', () async {
    final dir = await Directory.systemTemp.createTemp('ghosts');
    try {
      final notes = '${dir.path}/notes.json', wav = '${dir.path}/vocals.wav';
      final sung = [for (final e in lay(verse)) (e.$1 + 20, e.$2 + 20, e.$3)];
      final all = [(5.0, 5.5, 64.0), ...sung];
      // Loud while the verse is sung, a faint leak before it.
      await writeWav(wav, 32, (t) => t < 10 ? 0.003 : 0.1);
      Future<void> write(Map<String, dynamic> extra) => File(notes).writeAsString(jsonEncode({
            'notes': [for (final e in all) {'onset': e.$1, 'offset': e.$2, 'pitch': e.$3}],
            ...extra,
          }));
      Future<Map<String, dynamic>> read() async => jsonDecode(await File(notes).readAsString()) as Map<String, dynamic>;

      await write({});
      expect(await cleanSongGhostNotes(notes, const [], vocalsWav: wav), 1);
      var j = await read();
      expect((j['ghost_notes'] as List).single['onset'], 5.0);
      expect(j['ghosts_v'], ghostsVersion);
      expect(await cleanSongGhostNotes(notes, const [], vocalsWav: wav), 0);

      await write({'ghosts_v': 1});
      expect(await cleanSongGhostNotes(notes, const [], vocalsWav: wav), 1);
      j = await read();
      expect(j['ghosts_v'], ghostsVersion);
      expect((j['notes'] as List).length, sung.length);

      // Without the stem (or an unreadable one) the other rules still run.
      await write({});
      expect(await cleanSongGhostNotes(notes, const [], vocalsWav: '${dir.path}/missing.wav'), 0);
      expect((await read())['ghosts_v'], ghostsVersion);
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
