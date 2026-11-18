import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:karaoke_battle/services/ktv_charts.dart';

// Fixtures are trimmed copies of the KTV Charts site's data files.
String fixture(String name) => File('test/services/fixtures/ktv_charts/$name').readAsStringSync();

void main() {
  final t0 = DateTime(2026, 11, 18, 10);

  group('parseVendorCharts', () {
    test('reads every chart of a source with its titles, period and links', () {
      final d = parseVendorCharts(KtvVendor.holiday, fixture('site-holiday.json'), downloadedAt: t0);
      expect(d.boards.map((b) => b.id), ['tc', 'tt']);
      final tc = d.chart('tc')!;
      expect(tc.board.label('zh'), '國語點播');
      expect(tc.board.label('en'), 'Mandarin Requests');
      expect(tc.board.label('xx'), '國語點播', reason: 'unknown language falls back to Chinese');
      expect(tc.board.sourceUrl, contains('holiday.com.tw'));
      expect(tc.period, '2026/11/10 ~ 2026/11/16');
      expect(tc.hasSongNo, isTrue);
      expect(tc.hasMovement, isTrue);
      final e = tc.entries.first;
      expect((e.rank, e.title, e.artist, e.songNo), (1, '甲乙丙丁', '李佳薇', '02657'));
      expect(e.genre, 'Mandopop');
      expect(e.bpm, 130);
      expect(e.tags['mood'], ['relaxed', 'sad']);
      expect((e.range!.low, e.range!.high, e.range!.fit), (60, 74, 'f'));
      expect(e.range!.female, (verdict: 'high', key: -2));
      expect(e.range!.male, (verdict: 'vhigh', key: 0));
      expect((e.year, e.released, e.album), ('2026', '2026-07-02', '甲乙丙丁Strangers - Single'));
      expect(e.label, startsWith('Columbia Records China'));
    });

    test('JOYSOUND takes its song id from the song page; KKBOX has no numbers', () {
      final j = parseVendorCharts(KtvVendor.joysound, fixture('site-joysound.json'), downloadedAt: t0).chart('all-weekly')!;
      expect(j.entries[1].songNo, '1143475');
      expect(j.entries[1].songUrl, 'https://www.joysound.com/web/search/song/1143475');
      final k = parseVendorCharts(KtvVendor.kkbox, fixture('site-kkbox.json'), downloadedAt: t0).chart('song-weekly-297')!;
      expect(k.hasSongNo, isFalse);
      expect(k.entries.where((e) => e.isNew).map((e) => e.rank), [13]);
    });

    test('a broken file is a format error', () {
      expect(() => parseVendorCharts(KtvVendor.dam, '<html>', downloadedAt: t0), throwsA(isA<ChartException>().having((e) => e.kind, 'kind', ChartErrorKind.format)));
      expect(() => parseVendorCharts(KtvVendor.dam, '{"charts": []}', downloadedAt: t0), throwsA(isA<ChartException>()));
    });
  });

  group('listen links', () {
    final e = parseVendorCharts(KtvVendor.holiday, fixture('site-holiday.json'), downloadedAt: t0).chart('tc')!.entries.first;

    test('open the exact song on each service that has it', () {
      expect(e.listenServices, ListenService.values);
      expect(e.listenUrl(ListenService.apple).toString(), 'https://music.apple.com/tw/song/6785801848');
      expect(e.listenUrl(ListenService.spotify).toString(), 'https://open.spotify.com/track/${e.spotify}');
      expect(e.listenUrl(ListenService.kkbox).toString(), 'https://www.kkbox.com/tw/tc/song/${e.kkbox}');
    });

    test('no link where the site found no match', () {
      const bare = ChartEntry(rank: 1, title: '伯方の塩', artist: '塩谷信廣', apple: 'jp/123');
      expect(bare.listenServices, [ListenService.apple]);
      expect(bare.listenUrl(ListenService.spotify), isNull);
      expect(bare.youtubeSearchUrl.queryParameters['search_query'], '伯方の塩 塩谷信廣');
    });
  });

  test('VTuber covers: count and who sang them', () {
    final d = parseVendorCharts(KtvVendor.vtuber, fixture('site-vtuber.json'), downloadedAt: t0);
    expect(d.boards.map((b) => b.id), ['covers-all', 'covers-90d']);
    final e = d.chart('covers-all')!.entries.first;
    expect((e.title, e.covers), ('CH4NGE', 19));
    expect(e.performers.first, (name: '可可伊丹CocoEden', video: 'QRcTX1JJaVo'));
    expect(ChartEntry.youtubeVideo('QRcTX1JJaVo').toString(), 'https://www.youtube.com/watch?v=QRcTX1JJaVo');
  });

  group('KtvChartService', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('ke-charts-'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('downloads the source file once, then serves the cache until the ttl', () async {
      var now = t0;
      final urls = <String>[];
      KtvChartService make() => KtvChartService(
        cacheDir: dir.path,
        now: () => now,
        client: MockClient((req) async {
          urls.add(req.url.toString());
          return http.Response.bytes(utf8.encode(fixture('site-dam.json')), 200);
        }),
      );
      final old = File('${dir.path}/ktv_charts/dam-all.json')..createSync(recursive: true);
      final s = make();
      final a = await s.load(KtvVendor.dam);
      expect(old.existsSync(), isFalse, reason: 'old per-board cache files are removed');
      expect(urls, ['https://hikari-tsai.github.io/ktv-charts/data/dam.json']);
      expect(a.chart('all-weekly')!.entries.first.title, '怪獣の花唄');
      expect(a.offline, isFalse);
      await s.load(KtvVendor.dam);
      expect(urls, hasLength(1), reason: 'memory cache');
      // A new launch reads the disk copy.
      final s2 = make();
      final b = await s2.load(KtvVendor.dam);
      expect(urls, hasLength(1), reason: 'disk cache');
      expect(b.downloadedAt, t0);
      now = t0.add(const Duration(hours: 4));
      await s2.load(KtvVendor.dam);
      expect(urls, hasLength(2), reason: 'older than the ttl');
      await s2.load(KtvVendor.dam, force: true);
      expect(urls, hasLength(3), reason: 'refresh');
    });

    test('offline: the last copy on disk, marked offline; an error only with no copy', () async {
      var up = true;
      var now = t0;
      final s = KtvChartService(
        cacheDir: dir.path,
        now: () => now,
        client: MockClient((req) async => up ? http.Response.bytes(utf8.encode(fixture('site-kkbox.json')), 200) : http.Response('', 503)),
      );
      await s.load(KtvVendor.kkbox);
      up = false;
      now = t0.add(const Duration(days: 2));
      final d = await s.load(KtvVendor.kkbox);
      expect(d.offline, isTrue);
      expect(d.downloadedAt, t0);
      expect(d.chart('song-weekly-297')!.entries, isNotEmpty);
      await expectLater(s.load(KtvVendor.joysound), throwsA(isA<ChartException>().having((e) => e.detail, 'detail', '503')));
    });

    test('concurrent loads share one request', () async {
      var hits = 0;
      final s = KtvChartService(
        client: MockClient((req) async {
          hits++;
          return http.Response.bytes(utf8.encode(fixture('site-cashbox.json')), 200);
        }),
      );
      await Future.wait([s.load(KtvVendor.cashbox), s.load(KtvVendor.cashbox)]);
      expect(hits, 1);
    });
  });
}
