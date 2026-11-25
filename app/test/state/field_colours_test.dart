// Under the Resonance Field the pitch line's colours widen with the judging
// (green to a semitone each way), in the take's line as well as live.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/state/live_trace.dart';
import 'package:karaoke_battle/state/song_data.dart';
import 'package:karaoke_battle/state/take_trace.dart';
import 'package:karaoke_battle/state/tuning_wand.dart';

void main() {
  test('the colour bands widen with the lenience', () {
    expect([for (final c in [30.0, 70.0, 150.0]) PitchCategory.of(c)], [PitchCategory.good, PitchCategory.near, PitchCategory.off]);
    expect([for (final c in [-70.0, 100.0, 150.0, 250.0]) PitchCategory.of(c, lenience: 2)],
        [PitchCategory.good, PitchCategory.good, PitchCategory.near, PitchCategory.off]);
  });

  test("a take's line is coloured as wide as it was judged", () {
    final notes = NoteList(Float64List.fromList([0.0]), Float64List.fromList([1.0]), Float64List.fromList([60]));
    // 80 cents sharp all along.
    final f0 = F0Curve(Float64List.fromList([0.2, 0.5]), Float64List.fromList([60.8, 60.8]), Float64List.fromList([1, 1]));
    expect(buildTakeTrace(notes, f0).categoryAt(0), PitchCategory.near);
    expect(buildTakeTrace(notes, f0, lenience: 2).categoryAt(0), PitchCategory.good);
  });

  test("a score's lenience: the field's, else 1", () {
    expect(lenienceOfScore(null), 1);
    expect(lenienceOfScore({'total': 90}), 1);
    expect(lenienceOfScore({'field': {'lenience': 2}}), 2);
    expect(lenienceOfScore({'field': <String, dynamic>{}}), TakeField.lenience);
  });
}
