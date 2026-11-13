import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/state/ghost_notes.dart';
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
}
