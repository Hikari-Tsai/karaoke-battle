// User corrections to the transcribed notes: change a note's pitch or delete
// a ghost note. Position and duration never change. Edits are saved back to
// notes.json (the first edit keeps a notes.orig.json backup) together with
// the time spans of deleted notes, which are then also excluded from the
// reference F0 curve (display and scoring), so a ghost does not keep
// counting through the curve.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'song_data.dart';

typedef TimeSpan = (double start, double end);

/// The spans of deleted notes stored in notes.json.
List<TimeSpan> excludedSpansFromJson(Map<String, dynamic> j) => [
      for (final e in (j['excluded_spans'] as List? ?? const []))
        if (e is List && e.length == 2) ((e[0] as num).toDouble(), (e[1] as num).toDouble()),
    ];

bool inSpans(List<TimeSpan> spans, double t) {
  for (final s in spans) {
    if (t >= s.$1 && t < s.$2) return true;
  }
  return false;
}

/// Marks the reference curve unvoiced inside [spans] (in place).
void maskCurve(F0Curve curve, List<TimeSpan> spans) {
  if (spans.isEmpty) return;
  for (var i = 0; i < curve.length; i++) {
    if (inSpans(spans, curve.times[i])) curve.midi[i] = double.nan;
  }
}

NoteList _copy(NoteList n, {int? skip, int? at, double? pitch}) {
  final len = n.length - (skip == null ? 0 : 1);
  final on = Float64List(len), off = Float64List(len), pi = Float64List(len);
  var j = 0;
  for (var i = 0; i < n.length; i++) {
    if (i == skip) continue;
    on[j] = n.onset[i];
    off[j] = n.offset[i];
    pi[j] = i == at ? pitch! : n.pitch[i];
    j++;
  }
  return NoteList(on, off, pi);
}

/// [n] with note [i]'s pitch replaced (used for live drag previews).
NoteList noteWithPitch(NoteList n, int i, double pitch) => _copy(n, at: i, pitch: pitch);

/// Note edits with undo. Pure in-memory; see [saveNoteEdits] for disk.
class NoteEditor {
  NoteEditor(this.notes, [List<TimeSpan> excluded = const []]) : excluded = List.of(excluded);

  NoteList notes;
  final List<TimeSpan> excluded;
  final List<(NoteList, List<TimeSpan>)> _undo = [];

  bool get canUndo => _undo.isNotEmpty;

  void _push() => _undo.add((notes, List.of(excluded)));

  /// Sets note [i]'s pitch (MIDI, may be fractional).
  void setPitch(int i, double pitch) {
    if (i < 0 || i >= notes.length || notes.pitch[i] == pitch) return;
    _push();
    notes = _copy(notes, at: i, pitch: pitch.clamp(0.0, 127.0));
  }

  /// Deletes note [i] and excludes its time span from the reference curve.
  void delete(int i) {
    if (i < 0 || i >= notes.length) return;
    _push();
    excluded.add((notes.onset[i], notes.offset[i]));
    notes = _copy(notes, skip: i);
  }

  /// Reverts the last edit; returns false when there is nothing to undo.
  bool undo() {
    if (_undo.isEmpty) return false;
    final (n, ex) = _undo.removeLast();
    notes = n;
    excluded
      ..clear()
      ..addAll(ex);
    return true;
  }
}

String origNotesPath(String notesJson) => notesJson.replaceFirst(RegExp(r'\.json$'), '.orig.json');

/// Writes [notes] and [excluded] into [notesJson], keeping its other fields.
/// The first save keeps the untouched file as notes.orig.json.
Future<void> saveNoteEdits(String notesJson, NoteList notes, List<TimeSpan> excluded) async {
  final file = File(notesJson);
  final orig = File(origNotesPath(notesJson));
  if (!await orig.exists() && await file.exists()) await file.copy(orig.path);
  final j = await file.exists() ? jsonDecode(await file.readAsString()) as Map<String, dynamic> : <String, dynamic>{};
  j['notes'] = [
    for (var i = 0; i < notes.length; i++) {'onset': notes.onset[i], 'offset': notes.offset[i], 'pitch': notes.pitch[i]},
  ];
  j['excluded_spans'] = [for (final s in excluded) [s.$1, s.$2]];
  j['edited'] = true;
  await file.writeAsString(jsonEncode(j));
}

/// Restores the transcription as it was before any edit. Returns false when
/// there is no backup (never edited).
Future<bool> restoreOriginalNotes(String notesJson) async {
  final orig = File(origNotesPath(notesJson));
  if (!await orig.exists()) return false;
  await orig.copy(notesJson);
  await orig.delete();
  return true;
}

Future<bool> hasNoteEdits(String notesJson) => File(origNotesPath(notesJson)).exists();
