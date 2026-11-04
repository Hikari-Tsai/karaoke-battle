// Parsers and the cache of the KTV chart service, against responses saved
// from the operators' sites (test/services/fixtures/ktv_charts). No network.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:karaoke_battle/services/ktv_charts.dart';

String fixture(String name) => File('test/services/fixtures/ktv_charts/$name').readAsStringSync();

ChartBoard board(KtvVendor v, [int i = 0]) => KtvCharts.boards[v]![i];

void main() {
  group('Holiday', () {
    test('decodes a page of the top chart', () {
      final r = parseHolidayPage(fixture('holiday_top_p1.json'));
      expect(r.maxPage, 2);
      expect(r.period, '2026/10/27 – 2026/11/02');
      expect(r.entries, hasLength(3));
      final first = r.entries.first;
      expect(first.rank, 1);
      expect(first.title, '甲乙丙丁');
      expect(first.artist, '李佳薇');
      expect(first.songNo, '02657');
      expect(first.lastRank, 1);
      expect(first.movement, 0);
      expect(first.isNew, isFalse);
    });

    test('marks new entries (weeks 新, lastweek –)', () {
      final r = parseHolidayPage(fixture('holiday_top_p2.json'));
      final n = r.entries.singleWhere((e) => e.isNew);
      expect(n.rank, 8);
      expect(n.title, '別回頭(DJ版)');
      expect(n.lastRank, isNull);
      expect(n.movement, isNull);
      expect(r.entries.firstWhere((e) => !e.isNew).artist, '徐暐翔 Vash Hsu、閻奕格');
    });

    test('a bad chart code is rejected with the decoded message', () {
      expect(
        () => parseHolidayPage(fixture('holiday_error.json')),
        throwsA(isA<ChartException>().having((e) => e.kind, 'kind', ChartErrorKind.rejected).having((e) => e.detail, 'detail', contains('歌曲類別不正確'))),
      );
    });

    test('non-JSON is a format error', () {
      expect(() => parseHolidayPage('<html>'), throwsA(isA<ChartException>().having((e) => e.kind, 'kind', ChartErrorKind.format)));
    });
  });

  group('Cashbox', () {
    test('keeps the requested language, sorted, with movement', () {
      final r = parseCashboxChart(fixture('cashbox_bl.json'), lang: '02');
      expect(r.period, '2026/10/27 – 2026/11/02');
      expect(r.entries.map((e) => e.rank), [1, 2, 22]);
      expect(r.entries.first.title, '若無你我欲去佗位');
      expect(r.entries.first.songNo, isNotEmpty);
      final n = r.entries.last;
      expect(n.isNew, isTrue, reason: 'LastWeekend 0 is a new entry');
      expect(n.lastRank, isNull);
      expect(parseCashboxChart(fixture('cashbox_bl.json'), lang: '01').entries.first.artist, '李佳薇');
    });

    test('a missing Referer is rejected', () {
      expect(
        () => parseCashboxChart(fixture('cashbox_referer_error.json')),
        throwsA(isA<ChartException>().having((e) => e.kind, 'kind', ChartErrorKind.rejected).having((e) => e.detail, 'detail', contains('998'))),
      );
    });

    test('the "no data" row and an empty body', () {
      expect(parseCashboxChart('[{"Result":"0","Msg":"","SongNo":""}]').entries, isEmpty);
      expect(() => parseCashboxChart(''), throwsA(isA<ChartException>()));
    });
  });

  group('JOYSOUND', () {
    test('reads the JSON-LD ItemList and the counting period', () {
      final r = parseJoysoundPage(fixture('joysound_weekly.html'));
      expect(r.period, '2026/10/26 – 2026/11/01');
      expect(r.entries, hasLength(3));
      final first = r.entries.first;
      expect(first.rank, 1);
      expect(first.title, '伯方の塩');
      expect(first.artist, '塩谷信廣');
      expect(first.songNo, '1143056');
      expect(first.movement, isNull);
    });

    test('a page without the list is a format error', () {
      expect(() => parseJoysoundPage('<html><script type="application/ld+json">{"@type":"WebSite"}</script></html>'), throwsA(isA<ChartException>()));
    });
  });

  group('DAM', () {
    test('weekly section with the derived Sunday–Saturday period', () {
      final r = parseDamPage(fixture('dam_ranking.html'));
      expect(r.updated, '2026/11/01');
      expect(r.period, '2026/10/25 – 2026/10/31');
      expect(r.entries.map((e) => e.rank), [1, 2, 3]);
      expect(r.entries.first.title, '怪獣の花唄');
      expect(r.entries.first.artist, 'Vaundy');
      expect(r.entries.first.songNo, '5277-09');
    });

    test('daily section has no derived period', () {
      final r = parseDamPage(fixture('dam_ranking.html'), sectionId: 'ranking-daily');
      expect(r.entries, hasLength(2));
      expect(r.updated, '2026/11/03');
      expect(r.period, isEmpty);
      expect(r.entries[1].title, '好きすぎて滅！');
    });

    test('a song listed twice (PC and mobile layouts) is kept once; entities are unescaped', () {
      final html = fixture('dam_ranking.html');
      final weekly = html.indexOf('id="ranking-weekly"');
      final li = RegExp(r'<li class="p-song-list__item.*?</li>', dotAll: true).firstMatch(html.substring(weekly))!.group(0)!;
      final end = html.indexOf('</ul>', weekly);
      final doubled = html.substring(0, end) + li.replaceAll('Vaundy', 'Tom &amp; Jerry') + html.substring(end);
      final r = parseDamPage(doubled);
      expect(r.entries, hasLength(3));
      expect(r.entries.first.artist, 'Vaundy');
      expect(htmlUnescape('A &amp; B &#x21; &#33; &lt;x&gt; &unknown;'), 'A & B ! ! <x> &unknown;');
    });

    test('a missing section is a format error', () {
      expect(() => parseDamPage(fixture('dam_ranking.html'), sectionId: 'ranking-monthly'), throwsA(isA<ChartException>()));
    });
  });

  group('service', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('ktv_charts_test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    // Serves the fixtures; counts requests per host.
    MockClient fakeSites(Map<String, int> hits, {Set<String> failing = const {}}) => MockClient((req) async {
      final host = req.url.host;
      hits[host] = (hits[host] ?? 0) + 1;
      if (failing.contains(host)) return http.Response('oops', 500);
      final utf8Headers = {'content-type': 'text/html; charset=utf-8'};
      switch (host) {
        case 'www.holiday.com.tw':
          final page = (jsonDecode(req.body) as List).first['page'];
          return http.Response.bytes(utf8.encode(fixture(page == 1 ? 'holiday_top_p1.json' : 'holiday_top_p2.json')), 200, headers: utf8Headers);
        case 'www.cashboxparty.com':
          if (req.headers['Referer'] == null) return http.Response.bytes(utf8.encode(fixture('cashbox_referer_error.json')), 200);
          return http.Response.bytes(utf8.encode(fixture('cashbox_bl.json')), 200);
        case 'www.joysound.com':
          return http.Response.bytes(utf8.encode(fixture('joysound_weekly.html')), 200, headers: utf8Headers);
        case 'www.clubdam.com':
          return http.Response.bytes(utf8.encode(fixture('dam_ranking.html')), 200, headers: utf8Headers);
      }
      return http.Response('', 404);
    });

    test('fetches every vendor; Holiday pages are merged in rank order', () async {
      final hits = <String, int>{};
      final s = KtvChartService(client: fakeSites(hits));
      final holiday = await s.load(board(KtvVendor.holiday));
      expect(holiday.entries.map((e) => e.rank), [1, 2, 3, 8, 21]);
      expect(holiday.period, '2026/10/27 – 2026/11/02');
      expect(hits['www.holiday.com.tw'], 2);
      final cashbox = await s.load(board(KtvVendor.cashbox));
      expect(cashbox.entries.map((e) => e.title), ['甲乙丙丁', '看著我的眼睛說'], reason: 'the Referer was sent, only Mandarin kept');
      expect((await s.load(board(KtvVendor.joysound))).entries, hasLength(3));
      final dam = await s.load(board(KtvVendor.dam));
      expect(dam.updated, '2026/11/01');
      expect(dam.entries, hasLength(3));
    });

    test('memory cache within the TTL, refetch when forced or expired', () async {
      final hits = <String, int>{};
      var now = DateTime(2026, 11, 3, 12);
      final s = KtvChartService(client: fakeSites(hits), now: () => now);
      final b = board(KtvVendor.joysound);
      await s.load(b);
      await s.load(b);
      expect(hits['www.joysound.com'], 1);
      await s.load(b, force: true);
      expect(hits['www.joysound.com'], 2);
      now = now.add(const Duration(hours: 7));
      await s.load(b);
      expect(hits['www.joysound.com'], 3);
    });

    test('concurrent loads of one board share the request', () async {
      final hits = <String, int>{};
      final s = KtvChartService(client: fakeSites(hits));
      final b = board(KtvVendor.dam);
      final r = await Future.wait([s.load(b), s.load(b)]);
      expect(identical(r[0], r[1]), isTrue);
      expect(hits['www.clubdam.com'], 1);
    });

    test('disk cache survives a new service', () async {
      final hits = <String, int>{};
      final b = board(KtvVendor.cashbox);
      final first = await KtvChartService(client: fakeSites(hits), cacheDir: tmp.path).load(b);
      final again = await KtvChartService(client: fakeSites(hits), cacheDir: tmp.path).load(b);
      expect(hits['www.cashboxparty.com'], 1);
      expect(again.entries.map((e) => e.toJson()), first.entries.map((e) => e.toJson()));
      expect(again.period, first.period);
      expect(again.fetchedAt.difference(first.fetchedAt).inSeconds, 0);
      expect(File('${tmp.path}/ktv_charts/${b.key}.json').existsSync(), isTrue);
    });

    test('a corrupt cache file is ignored', () async {
      final b = board(KtvVendor.dam);
      File('${tmp.path}/ktv_charts/${b.key}.json')
        ..createSync(recursive: true)
        ..writeAsStringSync('{not json');
      final hits = <String, int>{};
      expect((await KtvChartService(client: fakeSites(hits), cacheDir: tmp.path).load(b)).entries, hasLength(3));
      expect(hits['www.clubdam.com'], 1);
    });

    test('one vendor failing does not affect the others', () async {
      final s = KtvChartService(client: fakeSites({}, failing: {'www.cashboxparty.com'}));
      final results = await Future.wait([
        for (final v in KtvVendor.values) s.load(board(v)).then<Object>((c) => c, onError: (Object e) => e),
      ]);
      expect(results[KtvVendor.cashbox.index], isA<ChartException>().having((e) => e.kind, 'kind', ChartErrorKind.http).having((e) => e.detail, 'detail', '500'));
      for (final v in [KtvVendor.holiday, KtvVendor.joysound, KtvVendor.dam]) {
        expect(results[v.index], isA<KtvChart>(), reason: v.name);
      }
    });

    test('a slow site times out; a network error is reported as such', () async {
      final slow = KtvChartService(
        client: MockClient((_) => Completer<http.Response>().future),
        timeout: const Duration(milliseconds: 50),
      );
      await expectLater(slow.load(board(KtvVendor.joysound)), throwsA(isA<ChartException>().having((e) => e.kind, 'kind', ChartErrorKind.timeout)));
      final down = KtvChartService(client: MockClient((_) async => throw const SocketException('no route')));
      await expectLater(down.load(board(KtvVendor.dam)), throwsA(isA<ChartException>().having((e) => e.kind, 'kind', ChartErrorKind.network)));
    });
  });

  test('movement is last week minus this week', () {
    expect(const ChartEntry(rank: 3, title: '', artist: '', songNo: '', lastRank: 7).movement, 4);
    expect(const ChartEntry(rank: 7, title: '', artist: '', songNo: '', lastRank: 3).movement, -4);
    expect(const ChartEntry(rank: 7, title: '', artist: '', songNo: '').movement, isNull);
  });

  test('YouTube search links carry the song and artist, encoded', () {
    const e = ChartEntry(rank: 1, title: '怪獣の花唄', artist: 'Vaundy', songNo: '');
    expect(e.youtubeSearchUrl.toString(), startsWith('https://www.youtube.com/results?search_query='));
    expect(e.youtubeSearchUrl.queryParameters['search_query'], '怪獣の花唄 Vaundy');
    const amp = ChartEntry(rank: 1, title: 'A&B #1', artist: '', songNo: '');
    expect(amp.youtubeSearchUrl.queryParameters['search_query'], 'A&B #1');
  });

  test('official links point at each chart', () {
    expect(board(KtvVendor.holiday, 1).officialUrl, 'https://www.holiday.com.tw/SongInfo/SongList.aspx?st=top&lt=tt');
    expect(board(KtvVendor.cashbox).officialUrl, 'https://www.cashboxparty.com/Music/KTVMusic.aspx');
    expect(board(KtvVendor.joysound, 1).officialUrl, 'https://www.joysound.com/web/karaoke/ranking/anime/weekly');
    expect(board(KtvVendor.dam).officialUrl, 'https://www.clubdam.com/ranking/#ranking-weekly');
    expect(board(KtvVendor.dam, 1).officialUrl, 'https://www.clubdam.com/genre/anison/#ranking-weekly');
  });
}
