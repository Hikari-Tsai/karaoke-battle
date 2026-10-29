import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/state/note_edits.dart';
import 'package:karaoke_battle/state/song_data.dart';

NoteList notes() => NoteList(
      Float64List.fromList([0, 1, 2]),
      Float64List.fromList([1, 2, 3]),
      Float64List.fromList([60.2, 62, 64]),
    );

void main() {
  test('pitch changes keep position and duration; undo restores', () {
    final e = NoteEditor(notes());
    e.setPitch(1, 63);
    expect(e.notes.pitch, [60.2, 63, 64]);
    expect(e.notes.onset, [0, 1, 2]);
    expect(e.notes.offset, [1, 2, 3]);
    expect(e.undo(), isTrue);
    expect(e.notes.pitch, [60.2, 62, 64]);
    expect(e.undo(), isFalse);
  });

  test('delete removes the note and excludes its span; undo brings both back', () {
    final e = NoteEditor(notes());
    e.delete(0);
    expect(e.notes.length, 2);
    expect(e.notes.onset.first, 1);
    expect(e.excluded, [(0.0, 1.0)]);
    e.undo();
    expect(e.notes.length, 3);
    expect(e.excluded, isEmpty);
  });

  test('masking blanks the reference curve inside deleted spans only', () {
    final c = F0Curve(Float64List.fromList([0.5, 1.5, 2.5]), Float64List.fromList([60, 62, 64]), Float64List.fromList([1, 1, 1]));
    maskCurve(c, [(1.0, 2.0)]);
    expect(c.midi[0], 60);
    expect(c.midi[1].isNaN, isTrue);
    expect(c.midi[2], 64);
  });

  test('save keeps other fields, backs up the original, restore brings it back', () async {
    final dir = await Directory.systemTemp.createTemp('notes_edit');
    final path = '${dir.path}/notes.json';
    final original = {'model': 'game-large', 'notes': [{'onset': 0, 'offset': 1, 'pitch': 60.2}, {'onset': 1, 'offset': 2, 'pitch': 62}]};
    await File(path).writeAsString(jsonEncode(original));

    final e = NoteEditor(NoteList.fromJson(original));
    e.delete(1);
    e.setPitch(0, 61);
    await saveNoteEdits(path, e.notes, e.excluded);

    final saved = jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
    expect(saved['model'], 'game-large');
    expect((saved['notes'] as List).length, 1);
    expect(NoteList.fromJson(saved).pitch, [61]);
    expect(excludedSpansFromJson(saved), [(1.0, 2.0)]);
    expect(await hasNoteEdits(path), isTrue);

    expect(await restoreOriginalNotes(path), isTrue);
    final back = jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
    expect((back['notes'] as List).length, 2);
    expect(excludedSpansFromJson(back), isEmpty);
    expect(await hasNoteEdits(path), isFalse);
    await dir.delete(recursive: true);
  });
}
