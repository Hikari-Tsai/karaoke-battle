import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/ui/results/score_reveal.dart';

void main() {
  test('the slot curve starts fast and settles exactly on the score', () {
    const c = SlotCurve();
    expect(c.transform(0), 0);
    expect(c.transform(1), 1);
    expect(c.slope(0), greaterThan(2));
    expect(c.slope(0.95), lessThan(0.2));
    // Still moving near the end, so the last ticks are heard.
    expect(c.transform(0.85), lessThan(0.99));
  });

  test('reels turn over like an odometer', () {
    // 85.3 → tenths 853
    expect(RollingNumber.reel(853, 0), closeTo(3, 1e-9));
    expect(RollingNumber.reel(853, 1), closeTo(5, 1e-9));
    expect(RollingNumber.reel(853, 2), closeTo(8, 1e-9));
    // 89.95: the units reel is halfway to 0, the tens halfway to 9.
    expect(RollingNumber.reel(899.5, 1), closeTo(9.5, 1e-9));
    expect(RollingNumber.reel(899.5, 2), closeTo(8.5, 1e-9));
    // Below the carry window the higher reel stays put.
    expect(RollingNumber.reel(894, 2), closeTo(8, 1e-9));
    expect(RollingNumber.visible(9.5), (9, 0, 0.5));
  });

  testWidgets('the rolled number reads as the score', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Center(child: RollingNumber(value: 85.3, intDigits: 2, style: TextStyle(fontSize: 40))),
    ));
    // At rest each reel shows one digit fully, the next one parked below.
    final shown = tester.widgetList<Positioned>(find.byType(Positioned)).where((p) => p.top == 0).map((p) => (p.child as Text).data).join();
    expect(shown, '853');
    expect(find.text('.'), findsOneWidget);
  });

  testWidgets('the celebration ends by itself and can be clicked away', (tester) async {
    var done = 0;
    await tester.pumpWidget(MaterialApp(
      home: CelebrationOverlay(score: 91.7, previousBest: 85.2, onDone: () => done++),
    ));
    expect(find.text('+6.5'), findsOneWidget);
    expect(find.text('85.2 → 91.7'), findsOneWidget);
    // Too early: a click does not skip the slam.
    await tester.tap(find.byType(CelebrationOverlay));
    await tester.pump(const Duration(milliseconds: 100));
    expect(done, 0);
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byType(CelebrationOverlay));
    expect(done, 1);
    await tester.pump(CelebrationOverlay.duration);
    expect(done, 1, reason: 'finishing again after a skip does nothing');

    done = 0;
    await tester.pumpWidget(MaterialApp(
      home: CelebrationOverlay(key: UniqueKey(), score: 91.7, previousBest: 85.2, onDone: () => done++),
    ));
    await tester.pump(CelebrationOverlay.duration + const Duration(milliseconds: 50));
    expect(done, 1);
  });
}
