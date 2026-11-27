import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/ui/widgets/live_score.dart';

void main() {
  Widget at(double v) => MaterialApp(home: Center(child: LiveScoreText(v)));

  testWidgets('shows the first value as it is, then counts up to a new one', (tester) async {
    await tester.pumpWidget(at(90));
    expect(find.text('90.0'), findsOneWidget);

    await tester.pumpWidget(at(93));
    expect(find.text('90.0'), findsOneWidget, reason: 'starts from what was shown');
    await tester.pump(const Duration(milliseconds: 300));
    final mid = double.parse((tester.widget(find.byType(Text)) as Text).data!);
    expect(mid, inExclusiveRange(90, 93), reason: 'on the way');
    await tester.pumpAndSettle();
    expect(find.text('93.0'), findsOneWidget);
  });

  testWidgets('waits while a celebration holds the screen', (tester) async {
    await tester.pumpWidget(at(80));
    LiveScoreHold.notifier.value = true;
    addTearDown(() => LiveScoreHold.notifier.value = false);
    await tester.pumpWidget(at(82));
    await tester.pumpAndSettle();
    expect(find.text('80.0'), findsOneWidget, reason: 'held');

    LiveScoreHold.notifier.value = false;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('80.0'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('82.0'), findsOneWidget);
  });

  test('the rank follows the number on the way, the stored one at the end', () {
    expect(liveRank(97.5, 98.6, 'SSS'), 'SS');
    expect(liveRank(98.2, 98.6, 'SSS'), 'SSS');
    expect(liveRank(98.6, 98.6, 'SSS'), 'SSS');
  });
}
