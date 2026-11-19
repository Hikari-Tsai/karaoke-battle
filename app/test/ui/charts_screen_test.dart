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

/// The KTV Charts site from fixtures; Cashbox can be made to fail.
KtvChartService fakeService({bool cashboxDown = false}) => KtvChartService(
  client: MockClient((req) async {
    final name = req.url.pathSegments.last; // holiday.json…
    if (cashboxDown && name == 'cashbox.json') return http.Response('', 503);
    final f = File('test/services/fixtures/ktv_charts/site-$name');
    if (!f.existsSync()) return http.Response('', 404);
    return http.Response.bytes(f.readAsBytesSync(), 200);
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

  testWidgets('each source is fetched when its tab is first shown', (tester) async {
    final files = <String>[];
    final s = KtvChartService(
      client: MockClient((req) async {
        files.add(req.url.pathSegments.last);
        return http.Response('', 503);
      }),
    );
    await pump(tester, s);
    await tester.pump();
    await settle(tester);
    expect(files.toSet(), {'holiday.json'});
    await openTab(tester, 'DAM');
    expect(files.toSet(), {'holiday.json', 'dam.json'});
  });

  testWidgets('every source tab, with details, movement and links', (tester) async {
    await pump(tester, fakeService());
    await tester.pump();
    await settle(tester);
    expect(tester.takeException(), isNull);
    for (final v in ['好樂迪', '錢櫃', 'JOYSOUND', 'DAM', 'KKBOX', 'VTuber 翻唱']) {
      expect(find.descendant(of: find.byType(TabBar), matching: find.text(v)), findsOneWidget);
    }
    expect(find.widgetWithText(ChoiceChip, '國語點播'), findsOneWidget);
    expect(find.text('在 好樂迪 官網查看'), findsOneWidget);
    expect(find.text('網頁版榜單'), findsOneWidget);
    expect(find.text('ktv-charts'), findsOneWidget, reason: 'the footer names and links the repo');
    expect(find.textContaining('資料來源：好樂迪 官網，由'), findsOneWidget);
    expect(find.text('甲乙丙丁'), findsOneWidget);
    expect(find.text('130 BPM'), findsWidgets);
    expect(find.text('C4–D5'), findsWidgets, reason: 'the chorus range beside its bar');
    expect(find.text('02657'), findsNothing, reason: 'no song numbers any more');
    expect(find.textContaining('2026 · Columbia Records China'), findsOneWidget, reason: 'release year and label under the artist');
    expect(find.byTooltip('在 YouTube 搜尋'), findsWidgets);
    expect(find.byTooltip('試聽'), findsWidgets);

    await openTab(tester, '錢櫃');
    expect(find.text('甲乙丙丁'), findsOneWidget);

    await openTab(tester, 'JOYSOUND');
    expect(find.widgetWithText(ChoiceChip, '綜合週榜'), findsOneWidget);
    expect(find.text('伯方の塩'), findsOneWidget);

    await openTab(tester, 'DAM');
    expect(find.text('怪獣の花唄'), findsOneWidget, reason: 'the weekly chart by default');
    expect(find.textContaining('2026/11/08 ~ 2026/11/14'), findsOneWidget);

    await openTab(tester, 'KKBOX');
    expect(find.text('在 KKBOX 官網查看'), findsOneWidget);

    await openTab(tester, 'VTuber 翻唱');
    expect(find.text('CH4NGE'), findsOneWidget);
    expect(find.text('19 次翻唱'), findsOneWidget);
    expect(find.text('歌名／原唱'), findsOneWidget);
    expect(find.text('標籤'), findsOneWidget);
    expect(find.text('在 YouTube 查看播放清單'), findsOneWidget);
    await tester.tap(find.text('19 次翻唱'));
    await tester.pumpAndSettle();
    expect(find.text('可可伊丹CocoEden'), findsOneWidget);
  });

  testWidgets('the listen menu lists only the services that have the song', (tester) async {
    await pump(tester, fakeService());
    await tester.pump();
    await settle(tester);
    await tester.tap(find.byTooltip('試聽').first);
    await tester.pumpAndSettle();
    expect(find.text('在 Apple Music 試聽'), findsOneWidget);
    expect(find.text('在 Spotify 試聽'), findsOneWidget);
    expect(find.text('在 KKBOX 試聽'), findsOneWidget);
  });

  testWidgets('one failing source shows its own error only', (tester) async {
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

  testWidgets('switching a chart needs no new request', (tester) async {
    var hits = 0;
    final s = KtvChartService(
      client: MockClient((req) async {
        hits++;
        return http.Response.bytes(File('test/services/fixtures/ktv_charts/site-joysound.json').readAsBytesSync(), 200);
      }),
    );
    await pump(tester, s);
    await tester.pump();
    await settle(tester);
    await openTab(tester, 'JOYSOUND');
    final before = hits;
    await tester.tap(find.widgetWithText(ChoiceChip, '綜合日榜'));
    await tester.pump();
    await settle(tester);
    expect(hits, before);
    expect(find.widgetWithText(ChoiceChip, '綜合日榜'), findsOneWidget);
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
