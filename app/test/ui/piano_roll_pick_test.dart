import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/state/song_data.dart';
import 'package:karaoke_battle/ui/sing/piano_roll.dart';

void main() {
  // Three notes over 10 s: C4 1-2 s, E4 4-6 s, C4 8-8.1 s (a short one).
  final notes = NoteList(Float64List.fromList([1, 4, 8]), Float64List.fromList([2, 6, 8.1]), Float64List.fromList([60, 64, 60]));
  PianoRollView view({double shift = 0}) =>
      PianoRollView(notes: notes, refF0: F0Curve.empty(), trace: null, minMidi: 55, maxMidi: 68, totalDuration: 10, pitchShift: shift, onSelectNote: (_) {});
  // 1046 px wide: 46 px of note names, then 100 px a second; 14 rows of 20 px.
  const size = Size(1046, 280);
  Offset at(double t, double midi) => Offset(46 + t * 100, 280 - (midi - 55 + 0.5) * 20);

  test('a click picks the note drawn under it', () {
    expect(view().noteAt(at(1.5, 60), size), 0);
    expect(view().noteAt(at(5, 64.3), size), 1, reason: 'within the row');
    expect(view().noteAt(at(5, 62), size), isNull, reason: 'two semitones off');
    expect(view().noteAt(at(3, 60), size), isNull, reason: 'between the notes');
    expect(view().noteAt(at(8.13, 60), size), 2, reason: 'a short note has a few pixels to spare');
    expect(view().noteAt(const Offset(20, 100), size), isNull, reason: 'the note names');
    expect(view(shift: 2).noteAt(at(5, 66), size), 1, reason: 'drawn in the key sung');
  });

  test('zoomed in, a click picks within the part in view', () {
    // 4 s from 3 s across the same 1000 px: 250 px a second.
    final v = PianoRollView(notes: notes, refF0: F0Curve.empty(), trace: null, minMidi: 55, maxMidi: 68, totalDuration: 10, viewStart: 3, viewSpan: 4, onSelectNote: (_) {});
    expect(v.noteAt(Offset(46 + (5 - 3) * 250, 280 - (64 - 55 + 0.5) * 20), size), 1);
    expect(v.noteAt(Offset(46 + (1.5 - 3) * 250 + 400, 280 - (60 - 55 + 0.5) * 20), size), isNull, reason: 't = 3.1 s, no note there');
  });

  testWidgets('clicking the roll reports the note', (tester) async {
    tester.view.physicalSize = const Size(1200, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    int? picked = -1;
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox.fromSize(
          size: size,
          child: PianoRollView(notes: notes, refF0: F0Curve.empty(), trace: null, minMidi: 55, maxMidi: 68, totalDuration: 10, onSelectNote: (i) => picked = i),
        ),
      ),
    ));
    final origin = tester.getTopLeft(find.byType(PianoRollView));
    await tester.tapAt(origin + at(5, 64));
    expect(picked, 1);
    await tester.tapAt(origin + at(3, 60));
    expect(picked, isNull);
  });
}
