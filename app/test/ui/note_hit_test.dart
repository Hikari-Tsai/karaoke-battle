import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/state/song_data.dart';
import 'package:karaoke_battle/ui/sing/piano_roll.dart';

void main() {
  // Roll 846 x 260 px: gutter 46 + 800 px plot; 13 rows (60..72) of 20 px.
  // Window 8 s with the playhead at 30 % (t0 = pos - 2.4 s): 100 px per second.
  final notes = NoteList(
    Float64List.fromList([2.4, 3.4, 5.4]),
    Float64List.fromList([3.4, 4.4, 6.4]),
    Float64List.fromList([60, 66, 72]),
  );
  int? hit(Offset p, {double shift = 0}) => hitTestNote(
        notes,
        const Size(846, 260),
        p,
        minMidi: 60,
        maxMidi: 72,
        position: 2.4,
        windowSeconds: 8,
        pitchShift: shift,
      );

  test('hits the note under the pointer', () {
    // Note 0: t 2.4..3.4 -> x 286..386, midi 60 -> y = 260 - 0.5/13*260 = 250.
    expect(hit(const Offset(330, 250)), 0);
    // Note 1: x 386..486, midi 66 -> y = 260 - 6.5/13*260 = 130.
    expect(hit(const Offset(430, 130)), 1);
    // Note 2: x 586..686, midi 72 -> y = 10.
    expect(hit(const Offset(600, 12)), 2);
  });

  test('misses empty space, the key gutter and shifted rows', () {
    expect(hit(const Offset(330, 130)), isNull);
    expect(hit(const Offset(20, 250)), isNull);
    // With a +2 key shift the note is drawn two rows higher.
    expect(hit(const Offset(330, 250), shift: 2), isNull);
    expect(hit(const Offset(330, 210), shift: 2), 0);
  });

  test('row height', () {
    expect(rollRowHeight(260, 60, 72), 20);
  });
}
