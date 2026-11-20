// Rank tags: S and above shine (a sweeping band of light now and then), the
// others stay plain, and nothing moves in a captured card (ShineScope off).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/ui/widgets/rank.dart';
import 'package:karaoke_battle/ui/widgets/shine.dart';

void main() {
  Widget chip(String rank, {bool scope = true, double fontSize = 14}) =>
      MaterialApp(home: Scaffold(body: Center(child: ShineScope(enabled: scope, child: RankChip(rank: rank, fontSize: fontSize)))));

  /// Pumps frames over [seconds] and whether a band of light was seen.
  Future<bool> sawShine(WidgetTester tester, {double seconds = 5}) async {
    var seen = false;
    for (var ms = 0; ms < seconds * 1000; ms += 50) {
      await tester.pump(const Duration(milliseconds: 50));
      seen |= find.byType(ShineBand).evaluate().isNotEmpty;
    }
    return seen;
  }

  testWidgets('S, SS and SSS shine; A does not', (tester) async {
    for (final r in ['S', 'SS', 'SSS']) {
      await tester.pumpWidget(chip(r));
      expect(find.byType(ShineTicker), findsOneWidget, reason: r);
      expect(await sawShine(tester), isTrue, reason: '$r should sweep within 5 s');
    }
    await tester.pumpWidget(chip('A'));
    expect(find.byType(ShineTicker), findsNothing);
    expect(await sawShine(tester), isFalse);
  });

  testWidgets('large tags sparkle', (tester) async {
    await tester.pumpWidget(chip('SSS', fontSize: 30));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(Sparkle), findsNWidgets(3));
  });

  testWidgets('no light while captured (ShineScope off)', (tester) async {
    await tester.pumpWidget(chip('SSS', scope: false, fontSize: 30));
    expect(await sawShine(tester), isFalse);
    expect(find.byType(Sparkle), findsNothing);
    expect(tester.hasRunningAnimations, isFalse);
  });
}
