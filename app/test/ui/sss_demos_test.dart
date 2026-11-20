// The rules page's SSS demo cards: the website's numbers, an entrance that
// waits until the cards are scrolled into view, and plays again whenever
// their tab is shown again.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/app_paths.dart';
import 'package:karaoke_battle/services/replay_library.dart';
import 'package:karaoke_battle/services/settings.dart';
import 'package:karaoke_battle/services/sidecars.dart';
import 'package:karaoke_battle/state/i18n.dart';
import 'package:karaoke_battle/ui/rules/sss_demos.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late AppSettings settings;
  late ReplayLibrary replays;
  late Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = await AppSettings.load();
    tmp = Directory.systemTemp.createTempSync('sss_demos');
    final paths = AppPaths.forTest(tmp.path);
    replays = ReplayLibrary(paths, Sidecars(paths, SidecarCatalog({})));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Widget app({bool active = true, double above = 0, ScrollController? scroll}) => MultiProvider(
        providers: [
          ChangeNotifierProvider<AppSettings>.value(value: settings),
          ChangeNotifierProvider<ReplayLibrary>.value(value: replays),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: TickerMode(
              enabled: active,
              child: ListView(controller: scroll, cacheExtent: 5000, children: [SizedBox(height: above), const SssDemos()]),
            ),
          ),
        ),
      );

  void bigWindow(WidgetTester tester) {
    tester.view.physicalSize = const Size(1500, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  // The total is drawn twice: invisible at its final width, and counting.
  int shown(String total) => find.text(total, skipOffstage: false).evaluate().length;

  testWidgets('counts up to the website\'s numbers, with a download button each', (tester) async {
    bigWindow(tester);
    await tester.pumpWidget(app());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(shown('99.2'), 1, reason: 'still counting');
    await tester.pump(const Duration(seconds: 3));
    expect(shown('99.2'), 2);
    expect(shown('98.7'), 2);
    expect(find.text('PERFECT'), findsNWidgets(2));
    expect(find.text(tr('demo.download')), findsNWidgets(2));
    expect(find.text(tr('demo.c992')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('waits until scrolled into view', (tester) async {
    bigWindow(tester);
    final scroll = ScrollController();
    await tester.pumpWidget(app(above: 3000, scroll: scroll));
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(shown('99.2'), 1, reason: 'not played off screen');
    scroll.jumpTo(2900);
    await tester.pump(); // the check, after layout, starts the entrance
    await tester.pump(const Duration(milliseconds: 100)); // its first tick
    await tester.pump(const Duration(seconds: 3));
    expect(shown('99.2'), 2);
  });

  testWidgets('plays again when its tab is shown again', (tester) async {
    bigWindow(tester);
    await tester.pumpWidget(app());
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(shown('99.2'), 2);
    await tester.pumpWidget(app(active: false));
    await tester.pump();
    await tester.pumpWidget(app());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(shown('99.2'), 1, reason: 'counting again');
    await tester.pump(const Duration(seconds: 3));
    expect(shown('99.2'), 2);
  });

  testWidgets('one column in a narrow window, without overflow', (tester) async {
    tester.view.physicalSize = const Size(600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app());
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    final a = tester.getTopLeft(find.text(tr('demo.c992')));
    final b = tester.getTopLeft(find.text(tr('demo.c987')));
    expect(b.dy, greaterThan(a.dy));
    expect(tester.takeException(), isNull);
  });
}
