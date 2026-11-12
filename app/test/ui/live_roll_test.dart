// Live singing on the piano roll: pop-ups follow their note, and the roll
// paints the playhead marker and the in-tune fill without errors.
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/state/live_trace.dart';
import 'package:karaoke_battle/state/song_data.dart';
import 'package:karaoke_battle/ui/sing/piano_roll.dart';
import 'package:karaoke_battle/ui/widgets/judgement_popups.dart';

void main() {
  Future<double> popupLeft(WidgetTester tester, {required bool follow}) async {
    final pos = ValueNotifier<double>(1.2);
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(
          width: 646,
          height: 400,
          child: JudgementLayer(
            position: pos,
            marks: const [JudgementMark(time: 1.15, tier: 'perfect', midi: 60, anchor: 1.0)],
            minMidi: 48,
            maxMidi: 72,
            followNotes: follow,
          ),
        ),
      ),
    ));
    return tester.widget<Positioned>(find.byType(Positioned)).left!;
  }

  testWidgets('a live pop-up sits on its note start, a replay pop-up on the playhead', (tester) async {
    // Plot 600 px wide after the 46 px gutter, 8 s window, playhead at 30 %.
    // Note start 1.0 s at position 1.2 s: 46 + (1.0 - 1.2 + 2.4) / 8 * 600 = 211.
    // The pop-up is 220 px wide, centred.
    expect(await popupLeft(tester, follow: true), closeTo(211 - 110, 0.01));
    expect(await popupLeft(tester, follow: false), closeTo(46 + 180 - 110, 0.01));
  });

  test('the live roll paints the marker and the in-tune fill', () {
    final notes = NoteList(Float64List.fromList([1.0]), Float64List.fromList([2.0]), Float64List.fromList([60]));
    final trace = LiveTrace();
    for (var t = 1.0; t < 1.5; t += 0.01) {
      final good = t < 1.3;
      trace.add(t, good ? 60 : 61.5, good ? 60 : 61.5, good ? 0 : 150, good ? PitchCategory.good : PitchCategory.off);
    }
    for (final pos in [1.6, 1.5 + 5.0]) {
      final painter = PianoRollPainter(
        notes: notes,
        refF0: F0Curve.empty(),
        trace: trace,
        colors: _colors,
        minMidi: 48,
        maxMidi: 72,
        position: ValueNotifier(pos),
        live: true,
      );
      final rec = ui.PictureRecorder();
      painter.paint(Canvas(rec), const Size(846, 400));
      rec.endRecording().dispose();
    }
  });
}

const _colors = PianoRollColors(
  background: Colors.black,
  rowAlt: Colors.black,
  grid: Colors.grey,
  gridOctave: Colors.grey,
  label: Colors.white,
  noteUpcoming: Colors.blue,
  noteCurrent: Colors.blue,
  notePast: Colors.blue,
  refCurve: Colors.white,
  playhead: Colors.orange,
  good: Colors.green,
  near: Colors.yellow,
  off: Colors.red,
  none: Colors.grey,
);
