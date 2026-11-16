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
//   semitones outside the main range;
// * the video came with its own subtitles (written by the uploader, not
//   YouTube's automatic captions) and the note lies outside every subtitle
//   line, with [subtitleMargin] seconds allowed before and after each line
//   because subtitles appear and disappear a little early or late. A note
//   that reaches into a line's window at all is kept, so a held last note
//   survives. When this would remove more than [maxSubtitleLoss] of the sung
//   time, the subtitles are taken to be incomplete or out of sync and the
//   rule is not used;
// * the separated vocal stem is much quieter under the note than under the
//   song's notes in general: more than [quietNoteDb] below the median note
//   level. That is accompaniment leaking into the stem, not singing (in the
//   songs measured, sung notes stay within about 8 dB of the median and
//   leaks sit 15 to 30 dB below it). It needs no subtitles. When it would
//   remove more than [maxQuietLoss] of the sung time (a song with a very
//   soft section) the rule is not used.
// Repeated low or high phrases inside the range are kept: they are melody.
//
// Cleaning rewrites notes.json once (marked with "ghosts_v"; "ghosts_subs"
// says the subtitle rule was applied, so a song whose subtitles arrive
// later is cleaned again with them). Removed notes
// are listed under "ghost_notes" and their time spans join
// "excluded_spans", like a note deleted by hand, so the reference curve is
// masked there too. A take scored before the cleaning keeps the notes it
// was scored against (snapshotTakeNotes), so its replay still lines up.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'energy_curve.dart';
import 'lyrics.dart';
import 'note_edits.dart';
import 'song_data.dart';

const ghostsVersion = 2;

/// Seconds a note may come before a subtitle line appears or after it goes.
const subtitleMargin = 1.5;

/// Largest share of the sung time the subtitle rule may remove.
const maxSubtitleLoss = 0.25;

/// A note this many dB below the median note level of the vocal stem is a
/// leak, not singing.
const quietNoteDb = 15.0;

/// Largest share of the sung time the quiet-note rule may remove.
const maxQuietLoss = 0.10;

const _minMidi = 38.0, _maxMidi = 88.0; // D2 .. E6
const _context = 3.0; // seconds either side
const _minNeighbours = 3;

/// The time windows singing is expected in, from the subtitles the video
/// came with: every line of the uploader's own YouTube tracks (as shown,
/// with the user's sync offset), widened by [margin] on both sides and
/// merged. Empty when the song has no such subtitles (automatic captions,
/// recognised, pasted, imported or typed lyrics do not count).
List<TimeSpan> subtitleWindows(Lyrics lyrics, {double margin = subtitleMargin}) {
  final spans = <TimeSpan>[
    for (final t in lyrics.tracks)
      if (t.source == LyricSource.youtube && !t.auto)
        for (final l in t.shownLines)
          if (l.end > l.start) (l.start - margin, l.end + margin),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  final out = <TimeSpan>[];
  for (final s in spans) {
    if (out.isNotEmpty && s.$1 <= out.last.$2) {
      if (s.$2 > out.last.$2) out[out.length - 1] = (out.last.$1, s.$2);
    } else {
      out.add(s);
    }
  }
  return out;
}

/// Indices of the notes in [n] that reach into none of [windows] (sorted by
/// start, not overlapping). Null when the rule does not apply: there are no
/// windows, or the notes outside them are more than [maxSubtitleLoss] of
/// the sung time.
List<int>? notesOutsideWindows(NoteList n, List<TimeSpan> windows) {
  if (windows.isEmpty) return null;
  final out = <int>[];
  var total = 0.0, lost = 0.0;
  for (var i = 0; i < n.length; i++) {
    final d = n.offset[i] - n.onset[i];
    if (d <= 0) continue;
    total += d;
    var inside = false;
    for (final w in windows) {
      if (w.$1 >= n.offset[i]) break;
      if (n.onset[i] < w.$2 && n.offset[i] > w.$1) {
        inside = true;
        break;
      }
    }
    if (!inside) {
      out.add(i);
      lost += d;
    }
  }
  if (total <= 0 || lost / total > maxSubtitleLoss) return null;
  return out;
}

/// The level of the vocal stem under each note of [n], in dB: the mean power
/// of [energy] (an RMS curve of vocals.wav) over the note.
List<double> noteLevelsDb(NoteList n, EnergyData energy) {
  final t = energy.times, e = energy.rmsDb;
  if (t.length < 2) return List.filled(n.length, double.nan);
  final hop = t[1] - t[0], t0 = t[0];
  return [
    for (var i = 0; i < n.length; i++)
      () {
        var a = ((n.onset[i] - t0) / hop).floor(), b = ((n.offset[i] - t0) / hop).ceil();
        a = a.clamp(0, e.length - 1);
        b = b.clamp(a + 1, e.length);
        var acc = 0.0;
        for (var k = a; k < b; k++) {
          acc += math.pow(10, e[k] / 10);
        }
        final p = acc / (b - a);
        return p > 0 ? 10 * math.log(p) / math.ln10 : -120.0;
      }(),
  ];
}

/// Indices of the notes whose [levels] (see [noteLevelsDb]) are more than
/// [quietNoteDb] below the median note level. Null when the rule does not
/// apply: no levels, or the quiet notes are more than [maxQuietLoss] of the
/// sung time.
List<int>? notesTooQuiet(NoteList n, List<double>? levels) {
  if (levels == null || levels.length != n.length) return null;
  final valid = [for (var i = 0; i < n.length; i++) if (n.offset[i] > n.onset[i] && levels[i].isFinite) levels[i]]..sort();
  if (valid.isEmpty) return null;
  final median = valid.length.isOdd ? valid[valid.length ~/ 2] : (valid[valid.length ~/ 2 - 1] + valid[valid.length ~/ 2]) / 2;
  final out = <int>[];
  var total = 0.0, lost = 0.0;
  for (var i = 0; i < n.length; i++) {
    final d = n.offset[i] - n.onset[i];
    if (d <= 0 || !levels[i].isFinite) continue;
    total += d;
    if (levels[i] < median - quietNoteDb) {
      out.add(i);
      lost += d;
    }
  }
  if (total <= 0 || lost / total > maxQuietLoss) return null;
  return out;
}

/// Indices of the ghost notes in [n] (ascending). [sungWindows] are the
/// song's [subtitleWindows], when it has any; [levels] the vocal stem's
/// level under each note ([noteLevelsDb]), when it could be read.
List<int> findGhostNotes(NoteList n, {List<TimeSpan> sungWindows = const [], List<double>? levels}) {
  final len = n.length;
  if (len == 0) return const [];
  final outside = <int>[...?notesOutsideWindows(n, sungWindows), ...?notesTooQuiet(n, levels)];
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
  if (outside.isEmpty) return ghosts;
  return ({...ghosts, ...outside}.toList()..sort());
}

/// True when a decoded notes.json needs no cleaning: done with these rules,
/// and with the subtitles if the song has any ([windows]).
bool _cleaned(Map<String, dynamic> j, List<TimeSpan> windows) =>
    j['ghosts_v'] == ghostsVersion && (windows.isEmpty || j['ghosts_subs'] == true);

/// Removes the ghost notes from one notes.json, once. Returns how many were
/// removed (0 when there were none or the file was cleaned before).
/// [vocalEnergy] is the RMS curve of the song's vocals.wav, for the quiet-note
/// rule.
Future<int> cleanGhostNotesFile(String path, {List<TimeSpan> windows = const [], EnergyData? vocalEnergy}) async {
  final file = File(path);
  if (!await file.exists()) return 0;
  final j = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  if (_cleaned(j, windows)) return 0;
  final list = (j['notes'] as List? ?? const []).cast<Map>();
  final n = NoteList(
    Float64List.fromList([for (final e in list) (e['onset'] as num).toDouble()]),
    Float64List.fromList([for (final e in list) (e['offset'] as num).toDouble()]),
    Float64List.fromList([for (final e in list) (e['pitch'] as num).toDouble()]),
  );
  // A file cleaned before only gets the rules it has not had: version 1 had
  // the pitch rules (running them again on what is left would shift the main
  // range and eat a little more each time), this version adds the quiet-note
  // rule, and the subtitle rule waits for subtitles.
  final version = j['ghosts_v'] is num ? (j['ghosts_v'] as num).toInt() : 0;
  final outside = notesOutsideWindows(n, windows);
  if (version == ghostsVersion && outside == null) return 0;
  final levels = vocalEnergy == null || version == ghostsVersion ? null : noteLevelsDb(n, vocalEnergy);
  final ghosts = version >= 1
      ? {...?outside, ...?notesTooQuiet(n, levels)}
      : findGhostNotes(n, sungWindows: windows, levels: levels).toSet();
  j['ghosts_v'] = ghostsVersion;
  // Marked only when the subtitle rule was really used: when it was held
  // back (too much would go), a later sync fix of the subtitles gets
  // another try.
  if (outside != null) j['ghosts_subs'] = true;
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

/// The [subtitleWindows] of a lyrics.json; none when it is missing or
/// unreadable.
Future<List<TimeSpan>> subtitleWindowsOfFile(String? lyricsJson) async {
  if (lyricsJson == null) return const [];
  try {
    final f = File(lyricsJson);
    if (!await f.exists()) return const [];
    return subtitleWindows(Lyrics.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>));
  } catch (_) {
    return const [];
  }
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
/// [lyricsJson] is the song's lyrics.json, for the subtitle rule, and
/// [vocalsWav] its separated vocal stem, for the quiet-note rule. Returns the
/// number of notes removed from notes.json. Never throws.
Future<int> cleanSongGhostNotes(String notesJson, Iterable<String> takeDirs, {String? lyricsJson, String? vocalsWav}) async {
  try {
    final f = File(notesJson);
    if (!await f.exists()) return 0;
    final windows = await subtitleWindowsOfFile(lyricsJson);
    final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    if (_cleaned(j, windows)) return 0;
    await snapshotTakeNotes(notesJson, takeDirs);
    // The stem is only read when the quiet-note rule is still to run.
    final energy = vocalsWav == null || j['ghosts_v'] == ghostsVersion ? null : await wavEnergyCurve(vocalsWav);
    final removed = await cleanGhostNotesFile(notesJson, windows: windows, vocalEnergy: energy);
    await cleanGhostNotesFile(origNotesPath(notesJson), windows: windows, vocalEnergy: energy);
    return removed;
  } catch (_) {
    return 0;
  }
}
