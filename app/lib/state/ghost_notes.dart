// Ghost notes: notes the transcription found where nobody sang that melody,
// such as an octave slip, a bass or instrument note leaking into the vocal
// stem, or a breath read as a low note. They pull the song's range (and so
// the AI key change) off and cost the singer a MISS they cannot avoid.
//
// A note is a ghost when one of these holds (the song's main range is the
// 5th..95th percentile of sung time):
// * it is outside what a voice sings at all (below D2 or above E6);
// * it sits an octave or more away from the notes around it (the median
//   within 3 s on either side) AND outside the main range: real melodic
//   leaps stay inside the song's range, octave slips leave it;
// * it is isolated (fewer than 3 notes within 3 s) and more than 5
//   semitones outside the main range.
// Repeated low or high phrases inside the range are kept: they are melody.
//
// Cleaning rewrites notes.json once (marked with "ghosts_v"). Removed notes
// are listed under "ghost_notes" and their time spans join
// "excluded_spans", like a note deleted by hand, so the reference curve is
// masked there too. A take scored before the cleaning keeps the notes it
// was scored against (snapshotTakeNotes), so its replay still lines up.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'note_edits.dart';
import 'song_data.dart';

const ghostsVersion = 1;

const _minMidi = 38.0, _maxMidi = 88.0; // D2 .. E6
const _context = 3.0; // seconds either side
const _minNeighbours = 3;

/// Indices of the ghost notes in [n] (ascending).
List<int> findGhostNotes(NoteList n) {
  final len = n.length;
  if (len == 0) return const [];
  // Main range: 5th..95th percentile of sung time.
  // Main range from the notes a voice can sing at all.
  bool singable(double p) => p.isFinite && p >= _minMidi && p <= _maxMidi;
  final idx = [for (var i = 0; i < len; i++) if (n.offset[i] > n.onset[i] && singable(n.pitch[i])) i]
    ..sort((a, b) => n.pitch[a].compareTo(n.pitch[b]));
  final total = idx.fold(0.0, (s, i) => s + n.offset[i] - n.onset[i]);
  double quantile(double q) {
    var acc = 0.0;
    for (final i in idx) {
      acc += n.offset[i] - n.onset[i];
      if (acc >= q * total) return n.pitch[i];
    }
    return idx.isEmpty ? 60 : n.pitch[idx.last];
  }

  final lo = quantile(0.05), hi = quantile(0.95);
  final ghosts = <int>[];
  for (var i = 0; i < len; i++) {
    final p = n.pitch[i];
    if (!singable(p)) {
      ghosts.add(i);
      continue;
    }
    final around = <double>[
      for (var k = 0; k < len; k++)
        if (k != i && (n.onset[k] - n.onset[i]).abs() <= _context) n.pitch[k],
    ];
    if (around.length < _minNeighbours) {
      if (p < lo - 5 || p > hi + 5) ghosts.add(i);
      continue;
    }
    around.sort();
    final mid = around.length.isOdd
        ? around[around.length ~/ 2]
        : (around[around.length ~/ 2 - 1] + around[around.length ~/ 2]) / 2;
    if ((p - mid).abs() >= 12 && (p < lo - 0.5 || p > hi + 0.5)) ghosts.add(i);
  }
  return ghosts;
}

/// Removes the ghost notes from one notes.json, once. Returns how many were
/// removed (0 when there were none or the file was cleaned before).
Future<int> cleanGhostNotesFile(String path) async {
  final file = File(path);
  if (!await file.exists()) return 0;
  final j = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  if (j['ghosts_v'] == ghostsVersion) return 0;
  final list = (j['notes'] as List? ?? const []).cast<Map>();
  final n = NoteList(
    Float64List.fromList([for (final e in list) (e['onset'] as num).toDouble()]),
    Float64List.fromList([for (final e in list) (e['offset'] as num).toDouble()]),
    Float64List.fromList([for (final e in list) (e['pitch'] as num).toDouble()]),
  );
  final ghosts = findGhostNotes(n).toSet();
  j['ghosts_v'] = ghostsVersion;
  if (ghosts.isNotEmpty) {
    j['notes'] = [for (var i = 0; i < list.length; i++) if (!ghosts.contains(i)) list[i]];
    j['ghost_notes'] = [...(j['ghost_notes'] as List? ?? const []), for (final i in ghosts) list[i]];
    j['excluded_spans'] = [
      for (final s in excludedSpansFromJson(j)) [s.$1, s.$2],
      for (final i in ghosts) [n.onset[i], n.offset[i]],
    ];
  }
  final tmp = File('$path.part');
  await tmp.writeAsString(jsonEncode(j));
  await tmp.rename(path);
  return ghosts.length;
}

/// Keeps the notes each existing take was scored against in its own folder
/// (takes made from now on get theirs when they are scored).
Future<void> snapshotTakeNotes(String notesJson, Iterable<String> takeDirs) async {
  final src = File(notesJson);
  if (!await src.exists()) return;
  for (final d in takeDirs) {
    final dst = File('$d${Platform.pathSeparator}notes.json');
    if (await dst.exists() || !await Directory(d).exists()) continue;
    await src.copy(dst.path);
  }
}

/// Cleans a song's notes (and the pre-edit backup, so "restore original"
/// does not bring the ghosts back) after snapshotting them for its takes.
/// Returns the number of notes removed from notes.json. Never throws.
Future<int> cleanSongGhostNotes(String notesJson, Iterable<String> takeDirs) async {
  try {
    final f = File(notesJson);
    if (!await f.exists()) return 0;
    final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    if (j['ghosts_v'] == ghostsVersion) return 0;
    await snapshotTakeNotes(notesJson, takeDirs);
    final removed = await cleanGhostNotesFile(notesJson);
    await cleanGhostNotesFile(origNotesPath(notesJson));
    return removed;
  } catch (_) {
    return 0;
  }
}
