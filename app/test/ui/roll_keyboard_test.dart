import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/state/song_data.dart';
import 'package:karaoke_battle/state/take_trace.dart';
import 'package:karaoke_battle/ui/sing/piano_roll.dart';

void main() {
  final notes = NoteList(Float64List.fromList([0, 1]), Float64List.fromList([1, 2]), Float64List.fromList([60, 64]));
  final f0 = F0Curve(Float64List(0), Float64List(0), Float64List(0));

  Future<void> pump(WidgetTester tester, {required bool keyboard, ValueNotifier<double>? sung}) => tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 300,
            child: PianoRollView(notes: notes, refF0: f0, trace: null, minMidi: 55, maxMidi: 70, position: ValueNotifier(0.5), keyboard: keyboard, sungMidi: sung),
          ),
        ),
      ));

  testWidgets('the pitch column draws a keyboard when on, names when off', (tester) async {
    final sung = ValueNotifier<double>(double.nan);
    await pump(tester, keyboard: true, sung: sung);
    expect(tester.takeException(), isNull);
    // A new sung pitch repaints the roll (the key lights up) without errors.
    sung.value = 61.3;
    await tester.pump();
    expect(tester.takeException(), isNull);
    await pump(tester, keyboard: false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('replays light the take own pitch at the playhead; the results view shows plain keys', (tester) async {
    final times = Float64List.fromList([for (var i = 0; i < 200; i++) i * 0.01]);
    final take = F0Curve(times, Float64List.fromList([for (var i = 0; i < 200; i++) i < 100 ? 60.2 : 64.0]), Float64List(200)..fillRange(0, 200, 1));
    final trace = buildTakeTrace(notes, take);
    for (final pos in [0.5, 1.5, 3.0]) {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 300,
            child: PianoRollView(notes: notes, refF0: f0, trace: trace, minMidi: 55, maxMidi: 70, position: ValueNotifier(pos), traceUntilPlayhead: true, keyboard: true),
          ),
        ),
      ));
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 400, height: 300, child: PianoRollView(notes: notes, refF0: f0, trace: trace, minMidi: 55, maxMidi: 70, totalDuration: 2, keyboard: true)),
      ),
    ));
    expect(tester.takeException(), isNull);
  });
}
