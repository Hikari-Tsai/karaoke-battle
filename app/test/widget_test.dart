import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:karaoke_battle/app.dart';
import 'package:karaoke_battle/state/i18n.dart';

void main() {
  testWidgets('startup error page renders', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(home: StartupErrorPage(error: StateError('boom'), onRetry: () {})));
    expect(find.text(tr('startup.failed')), findsOneWidget);
    expect(find.textContaining('boom'), findsOneWidget);
  });
}
