import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:karaoke_battle/services/ktv_charts.dart';
import 'package:karaoke_battle/state/i18n.dart';
import 'package:karaoke_battle/ui/charts/charts_screen.dart';

String fixture(String name) => File('test/services/fixtures/ktv_charts/$name').readAsStringSync();

/// Fixture-backed sites; Cashbox can be made to fail.
KtvChartService fakeService({bool cashboxDown = false}) => KtvChartService(
  client: MockClient((req) async {
    final body = switch (req.url.host) {
      'www.holiday.com.tw' => fixture(req.body.contains('"page":1') ? 'holiday_top_p1.json' : 'holiday_top_p2.json'),
      'www.cashboxparty.com' => cashboxDown ? null : fixture('cashbox_bl.json'),
      'www.joysound.com' => fixture('joysound_weekly.html'),
      'www.clubdam.com' => fixture('dam_ranking.html'),
      _ => null,
    };
    if (body == null) return http.Response('', 503);
    return http.Response.bytes(utf8.encode(body), 200);
  }),
);

void main() {
  tearDown(() => I18n.notifier.value = 'zh');

  Future<void> pump(WidgetTester tester, KtvChartService service, {bool active = true}) async {
    tester.view.physicalSize = const Size(1100, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: ChartsScreen(active: active, service: service),
    ));
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
  }

  testWidgets('nothing is fetched until the tab is shown', (tester) async {
    var hits = 0;
    final s = KtvChartService(
      client: MockClient((_) async {
        hits++;
        return http.Response('', 500);
      }),
    );
    await pump(tester, s, active: false);
    await settle(tester);
    expect(hits, 0);
  });

  Future<void> openTab(WidgetTester tester, String name) async {
    await tester.tap(find.descendant(of: find.byType(TabBar), matching: find.text(name)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
  }

  testWidgets('each operator is fetched when its tab is first shown', (tester) async {
    final hosts = <String>[];
    final s = KtvChartService(
      client: MockClient((req) async {
        hosts.add(req.url.host);
        return http.Response('', 503);
      }),
    );
    await pump(tester, s);
    await tester.pump();
    await settle(tester);
    expect(hosts.toSet(), {'www.holiday.com.tw'});
    await openTab(tester, 'DAM');
    expect(hosts.toSet(), {'www.holiday.com.tw', 'www.clubdam.com'});
  });

  testWidgets('every operator tab, with movement, new entries and links', (tester) async {
    await pump(tester, fakeService());
    await tester.pump();
    await settle(tester);
    expect(tester.takeException(), isNull);
    for (final v in ['好樂迪', '錢櫃', 'JOYSOUND', 'DAM']) {
      expect(find.descendant(of: find.byType(TabBar), matching: find.text(v)), findsOneWidget);
    }
    expect(find.text('在 好樂迪 官網查看'), findsOneWidget);
    expect(find.text('甲乙丙丁'), findsOneWidget);
    expect(find.text('新進'), findsOneWidget, reason: 'Holiday rank 8');
    expect(find.byTooltip('在 YouTube 搜尋'), findsWidgets);

    await openTab(tester, '錢櫃');
    expect(find.text('在 錢櫃 官網查看'), findsOneWidget);
    expect(find.text('甲乙丙丁'), findsOneWidget);

    await openTab(tester, 'JOYSOUND');
    expect(find.text('伯方の塩'), findsOneWidget);

    await openTab(tester, 'DAM');
    expect(find.text('怪獣の花唄'), findsOneWidget);
    expect(find.textContaining('2026/10/25 – 2026/10/31'), findsOneWidget, reason: 'DAM weekly period');
    expect(find.text('5277-09'), findsOneWidget);
    expect(find.text('在 DAM 官網查看'), findsOneWidget);
  });

  testWidgets('one failing operator shows its own error only', (tester) async {
    await pump(tester, fakeService(cashboxDown: true));
    await tester.pump();
    await settle(tester);
    await openTab(tester, '錢櫃');
    expect(find.textContaining('無法取得錢櫃的排行榜'), findsOneWidget);
    expect(find.textContaining('HTTP 503'), findsOneWidget);
    expect(find.text('重試'), findsOneWidget);
    expect(find.descendant(of: find.byType(TabBar), matching: find.byIcon(Icons.error_outline)), findsOneWidget);
    await openTab(tester, 'JOYSOUND');
    expect(find.text('伯方の塩'), findsOneWidget);
    expect(find.text('重試'), findsNothing);
  });

  testWidgets('switching a board loads that chart', (tester) async {
    final paths = <String>[];
    final s = KtvChartService(
      client: MockClient((req) async {
        paths.add(req.url.path);
        return http.Response.bytes(utf8.encode(fixture('joysound_weekly.html')), 200);
      }),
    );
    await pump(tester, s);
    await tester.pump();
    await settle(tester);
    await openTab(tester, 'JOYSOUND');
    await tester.tap(find.widgetWithText(ChoiceChip, '動畫'));
    await tester.pump();
    await settle(tester);
    expect(paths, contains('/web/karaoke/ranking/anime/weekly'));
  });

  // KE_TEST_CHARTS_OUT=<file.png> (with KE_TEST_CHARTS_FONT=<CJK font>) saves
  // the page for a visual check; KE_TEST_CHARTS_LANG picks the UI language and
  // KE_TEST_CHARTS_TAB the operator tab (by its shown name).
  testWidgets('screenshot', (tester) async {
    final out = Platform.environment['KE_TEST_CHARTS_OUT'];
    if (out == null) return;
    final fontPath = Platform.environment['KE_TEST_CHARTS_FONT'];
    if (fontPath != null) {
      await tester.runAsync(() async {
        final loader = FontLoader('ChartsTest')..addFont(Future.value(ByteData.sublistView(File(fontPath).readAsBytesSync())));
        await loader.load();
      });
    }
    I18n.notifier.value = Platform.environment['KE_TEST_CHARTS_LANG'] ?? 'zh';
    final key = GlobalKey();
    tester.view.physicalSize = const Size(1000, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(brightness: Brightness.dark, fontFamily: fontPath == null ? null : 'ChartsTest'),
        home: ChartsScreen(service: fakeService(cashboxDown: Platform.environment['KE_TEST_CHARTS_FAIL'] != null)),
      ),
    ));
    await tester.pump();
    await settle(tester);
    final tab = Platform.environment['KE_TEST_CHARTS_TAB'];
    if (tab != null) await openTab(tester, tab);
    await tester.runAsync(() async {
      final b = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final img = await b.toImage();
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      await File(out).writeAsBytes(data!.buffer.asUint8List());
    });
  });
}
