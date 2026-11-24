import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/ui/widgets/reveal.dart';

void main() {
  testWidgets('a number counts up once, then runs from where it is to a new value', (tester) async {
    Widget app(double v) => MaterialApp(home: Center(child: CountUp(value: v, format: (x) => '${x.round()}')));
    int shown() => int.parse(tester.widgetList<Text>(find.byType(Text)).last.data!);
    await tester.pumpWidget(app(100));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(shown(), 100);
    // Points spent: from 100 down to 75, never through 0.
    await tester.pumpWidget(app(75));
    final seen = <int>[];
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      seen.add(shown());
    }
    expect(seen.every((v) => v >= 75 && v <= 100), isTrue, reason: '$seen');
    expect(seen.any((v) => v > 75), isTrue, reason: 'it runs, not jumps');
    expect(seen.last, 75);
  });
}
