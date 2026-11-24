import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/ui/results/results_screen.dart' show ZoomableRoll, ZoomableRollState;

void main() {
  testWidgets('the results roll zooms with its buttons, moves with a drag and comes back', (tester) async {
    tester.view.physicalSize = const Size(1046, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    double? start, span;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 1046,
          height: 300,
          child: ZoomableRoll(total: 100, builder: (s, sp) {
            start = s;
            span = sp;
            return const ColoredBox(color: Colors.black);
          }),
        ),
      ),
    ));
    expect(span, isNull, reason: 'the whole song');
    await tester.tap(find.byIcon(Icons.zoom_in));
    await tester.pump();
    expect(span, closeTo(100 / 1.6, 0.01));
    expect(start, closeTo(50 - 50 / 1.6, 0.01), reason: 'around the middle');
    final before = start!;
    // Dragging left moves later into the song: 100 px of the 1000 px plot.
    await tester.drag(find.byType(ColoredBox).first, const Offset(-100, 0));
    await tester.pump();
    expect(start!, greaterThan(before));
    final state = tester.state<ZoomableRollState>(find.byType(ZoomableRoll));
    state.zoomBy(1000);
    await tester.pump();
    expect(span, closeTo(ZoomableRoll.minSpan, 0.01), reason: 'no closer than 2 s');
    await tester.tap(find.byIcon(Icons.fit_screen));
    await tester.pump();
    expect((start, span), (0, null));
  });
}
