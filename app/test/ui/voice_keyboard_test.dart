import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/state/song_data.dart';
import 'package:karaoke_battle/state/voice_range.dart';
import 'package:karaoke_battle/ui/sing/voice_keyboard.dart';

void main() {
  test('key geometry: C2..C6 has 29 white keys; black keys sit between whites', () {
    expect(VoiceKeyboardPainter.whiteCount, 29);
    const w = 290.0;
    expect(VoiceKeyboardPainter.keyCenter(36, w), 5); // C2
    expect(VoiceKeyboardPainter.keyCenter(37, w), 10); // C#2 on the C/D line
    expect(VoiceKeyboardPainter.xOf(36.5, w), 7.5);
    expect(VoiceKeyboardPainter.xOf(20, w), 5, reason: 'clamped to the keyboard');
  });

  testWidgets('paints with a score key, a sung key and the range', (tester) async {
    final notes = NoteList(Float64List.fromList([0, 1]), Float64List.fromList([1, 2]), Float64List.fromList([60, 67]));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 256,
          child: VoiceKeyboard(range: SongRange.of(notes), shift: -2, refMidi: 60, sungMidi: 61.3),
        ),
      ),
    ));
    expect(find.byType(VoiceKeyboard), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
