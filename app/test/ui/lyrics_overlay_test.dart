import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/state/lyrics.dart';
import 'package:karaoke_battle/ui/sing/lyrics_overlay.dart';

void main() {
  // AAA and BBB back to back, a gap, then CCC.
  final lyrics = Lyrics(tracks: [
    LyricTrack(lang: 'ja', auto: false, lines: const [
      LyricLine(1, 3, 'AAA'),
      LyricLine(3, 5, 'BBB'),
      LyricLine(8, 10, 'CCC'),
    ]),
  ]);
  final position = ValueNotifier<double>(0);
  final key = GlobalKey();

  Future<void> at(WidgetTester tester, double t) async {
    position.value = t;
    await tester.pump();
  }

  Future<void> pumpOverlay(WidgetTester tester) => tester.pumpWidget(MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.blueGrey,
          body: Align(
            alignment: Alignment.bottomCenter,
            child: RepaintBoundary(
              key: key,
              child: SizedBox(width: 600, height: 400, child: Align(alignment: Alignment.bottomCenter, child: LyricsOverlay(lyrics: lyrics, position: position))),
            ),
          ),
        ),
      ));

  double opacityOf(WidgetTester tester, String text) {
    var o = 1.0;
    final el = tester.element(find.text(text).first);
    el.visitAncestorElements((a) {
      final w = a.widget;
      if (w is Opacity) o *= w.opacity;
      return w is! LyricsOverlay;
    });
    return o;
  }

  testWidgets('the next line flips up while the sung line slides out', (tester) async {
    await pumpOverlay(tester);
    await at(tester, 2);
    expect(find.text('AAA'), findsWidgets);
    final nextY = tester.getCenter(find.text('BBB').first).dy;
    final curY = tester.getCenter(find.text('AAA').first).dy;
    expect(nextY, greaterThan(curY), reason: 'BBB is the small line below');

    await at(tester, 3 + LyricsOverlay.flipSeconds * 0.3);
    expect(find.text('AAA'), findsWidgets, reason: 'AAA is still sliding out');
    expect(opacityOf(tester, 'AAA'), inExclusiveRange(0, 1));
    expect(tester.getCenter(find.text('AAA').first).dy, lessThan(curY), reason: 'moving up');
    final midY = tester.getCenter(find.text('BBB').first).dy;
    expect(midY, inExclusiveRange(curY, nextY + 1), reason: 'BBB is on its way up');

    await at(tester, 3 + LyricsOverlay.flipSeconds + 0.01);
    expect(find.text('AAA'), findsNothing);
    expect(opacityOf(tester, 'BBB'), 1);
  });

  testWidgets('before a gap the sung line still slides out', (tester) async {
    await pumpOverlay(tester);
    await at(tester, 5 + LyricsOverlay.flipSeconds * 0.5);
    expect(find.text('BBB'), findsWidgets);
    expect(opacityOf(tester, 'BBB'), inExclusiveRange(0, 1));
    expect(find.text('CCC'), findsOneWidget, reason: 'the upcoming line, dimmed');
    await at(tester, 6);
    expect(find.text('BBB'), findsNothing);
    expect(find.text('CCC'), findsOneWidget);
  });

  // KE_TEST_LYRICS_OUT=<dir> saves frames of the flip for a visual check.
  testWidgets('frames', (tester) async {
    final out = Platform.environment['KE_TEST_LYRICS_OUT'];
    if (out == null) return;
    await pumpOverlay(tester);
    for (final t in [2.9, 3.03, 3.08, 3.15, 3.25, 3.4, 5.1, 5.2, 5.4]) {
      await at(tester, t);
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final img = await boundary.toImage();
        final data = await img.toByteData(format: ui.ImageByteFormat.png);
        await File('$out/lyrics_${t.toStringAsFixed(2)}.png').writeAsBytes(data!.buffer.asUint8List());
      });
    }
  });
}
