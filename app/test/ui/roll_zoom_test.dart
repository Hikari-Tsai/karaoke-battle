import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/state/song_data.dart';
import 'package:karaoke_battle/ui/sing/piano_roll.dart';

void main() {
  // Low verse (55-60) for 10 s, then a high chorus (70-76).
  final notes = NoteList(
    Float64List.fromList([0, 2, 4, 6, 10, 12, 14]),
    Float64List.fromList([2, 4, 6, 8, 12, 14, 16]),
    Float64List.fromList([55, 58, 60, 57, 70, 76, 72]),
  );

  test('centre covers all notes in the window when they fit', () {
    expect(zoomTargetCenter(notes, 0, 0, 8, 12), 57.5); // 55..60
    expect(zoomTargetCenter(notes, 2, 0, 8, 12), 59.5); // follows the key shift
  });

  test('centre falls back to the median when the notes do not fit', () {
    expect(zoomTargetCenter(notes, 0, 0, 16, 8), 60);
  });

  test('no notes in the window keeps the previous centre', () {
    expect(zoomTargetCenter(notes, 0, 8.5, 9.5, 12), isNull);
  });

  test('range is clamped inside the whole-song range', () {
    const full = (min: 52.0, max: 79.0);
    expect(zoomedRange(full, 57.5, 8), (min: 53.5, max: 61.5));
    expect(zoomedRange(full, 53, 8), (min: 52.0, max: 60.0));
    expect(zoomedRange(full, 78, 8), (min: 71.0, max: 79.0));
    expect(zoomedRange(full, 60, 40), full); // span wider than the song
  });

  test('essential range covers nearby notes and the recent voice', () {
    expect(essentialPitchRange(notes, 0, 0, 3, const []), (lo: 55.0, hi: 58.0));
    expect(essentialPitchRange(notes, 0, 0, 3, const [64.0, double.nan]), (lo: 55.0, hi: 64.0));
    expect(essentialPitchRange(notes, 0, 8.5, 9.5, const []), isNull);
  });

  test('follow target widens beyond the preferred span only when needed', () {
    // Fits in 8 semitones with 1.5 margins: keep the preferred span.
    expect(followTarget((lo: 55, hi: 60), 8, 27), (span: 8.0, center: 57.5));
    // 70..76 plus a sung 64: needs 12 + 3 = 15 semitones.
    expect(followTarget((lo: 64, hi: 76), 8, 27), (span: 15.0, center: 70.0));
    // Never wider than the whole song.
    expect(followTarget((lo: 40, hi: 90), 8, 27)!.span, 27);
    expect(followTarget(null, 8, 27), isNull);
  });
}
