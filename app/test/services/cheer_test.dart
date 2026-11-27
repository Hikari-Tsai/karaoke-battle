import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/scoring/models.dart';
import 'package:karaoke_battle/services/app_paths.dart';
import 'package:karaoke_battle/services/cheer.dart';
import 'package:karaoke_battle/services/ecpay_alert.dart';
import 'package:karaoke_battle/services/opay_alert.dart';
import 'package:karaoke_battle/services/settings.dart';
import 'package:karaoke_battle/services/song_library.dart';
import 'package:karaoke_battle/state/take_cheer.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

const _id = 'C1B8B9E32C2467466E4A8B4CE4A99378';

void main() {
  group('ECPay alert box', () {
    test('accepts the alert URL and the donate link, on live and stage', () {
      final live = AlertBox.parse(' https://payment.ecpay.com.tw/Broadcaster/AlertBox/${_id.toLowerCase()} ')!;
      expect(live.host, 'https://payment.ecpay.com.tw');
      expect(live.id, _id);
      expect(live.isStage, isFalse);
      final stage = AlertBox.parse('https://payment-stage.ecpay.com.tw/Broadcaster/Donate/$_id')!;
      expect(stage.isStage, isTrue);
      expect(stage.alertUrl, 'https://payment-stage.ecpay.com.tw/Broadcaster/AlertBox/$_id');
      expect(stage.donateUrl, 'https://payment-stage.ecpay.com.tw/Broadcaster/Donate/$_id');
    });

    test('rejects other hosts, short IDs and other pages', () {
      expect(AlertBox.parse('https://evil.example.com/Broadcaster/AlertBox/$_id'), isNull);
      expect(AlertBox.parse('https://payment.ecpay.com.tw/Broadcaster/AlertBox/ABC'), isNull);
      expect(AlertBox.parse('https://payment.ecpay.com.tw/Broadcaster/Setup'), isNull);
      expect(AlertBox.parse(''), isNull);
    });

    test('reads the hub, token and method from the alert page', () {
      const html = '''
<script>
    var connection = new signalR.HubConnectionBuilder()
        .withUrl('https://signalr-stage.ecpay.com.tw' +'/donateHub',
            { accessTokenFactory: () => this.loginToken = "aaa.bbb.ccc" })
        .build();
    connection.on("$_id", function (name, amount, msg) { });
</script>''';
      final page = AlertPage.parse(html)!;
      expect(page.hub, 'https://signalr-stage.ecpay.com.tw/donateHub');
      expect(page.token, 'aaa.bbb.ccc');
      expect(page.method, _id);
      expect(AlertPage.parse('<html>changed</html>'), isNull);
    });

    test('amounts: the test alert sends "100", a real payment "123.0000"', () {
      expect(parseAmount('100'), 100);
      expect(parseAmount('123.0000'), 123);
      expect(parseAmount(50), 50);
      expect(parseAmount('abc'), isNull);
    });

    test('splits SignalR frames and keeps a partial one', () {
      final (frames, rest) = splitFrames('{}\u001e{"type":6}\u001e{"type":1,"tar');
      expect(frames, [{}, {'type': 6}]);
      expect(rest, '{"type":1,"tar');
    });

    test('a donation comes from an invocation of the alert box method only', () {
      final at = DateTime(2026, 11, 27, 22, 15);
      final frame = {
        'type': 1,
        'target': _id,
        'arguments': ['KB測試', '123.0000', 'Karaoke Battle 接收測試 #1'],
      };
      final d = donationFromFrame(frame, _id, now: at)!;
      expect((d.source, d.name, d.amount, d.message, d.receivedAt), ('ecpay', 'KB測試', 123, 'Karaoke Battle 接收測試 #1', at));
      expect(donationFromFrame({...frame, 'target': 'other'}, _id), isNull);
      expect(donationFromFrame({'type': 6}, _id), isNull);
      expect(donationFromFrame({'type': 1, 'target': _id, 'arguments': ['x', 'n/a']}, _id), isNull);
      // A test alert with no message.
      expect(donationFromFrame({'type': 1, 'target': _id, 'arguments': ['XXX', '100', null]}, _id)!.message, '');
    });
  });

  group('what was typed for the alert URL', () {
    test('a HashKey, HashIV or merchant ID is caught, not taken for the URL', () {
      // ECPay's published test keys and merchant ID (docs: 測試介接資訊).
      expect(alertInputProblem('pwFHCqoQZGmho4w6', 'ecpay'), AlertInputProblem.secretKey);
      expect(alertInputProblem(' EkRm7iFT261dpevs ', 'ecpay'), AlertInputProblem.secretKey);
      expect(alertInputProblem('HashKey: pwFHCqoQZGmho4w6', 'ecpay'), AlertInputProblem.secretKey);
      expect(alertInputProblem('3002607', 'ecpay'), AlertInputProblem.merchantId);
    });

    test('other near misses say what they are', () {
      expect(alertInputProblem('', 'ecpay'), AlertInputProblem.empty);
      expect(alertInputProblem(_id, 'ecpay'), AlertInputProblem.bareId);
      expect(alertInputProblem('https://p.ecpay.com.tw/F05781D', 'ecpay'), AlertInputProblem.shortLink);
      expect(alertInputProblem('https://vendor.ecpay.com.tw/Broadcaster/AnimationSetup', 'ecpay'), AlertInputProblem.otherPage);
      expect(alertInputProblem('https://payment.ecpay.com.tw/Broadcaster/Setup', 'ecpay'), AlertInputProblem.otherPage);
      expect(alertInputProblem('https://example.com/AlertBox/$_id', 'ecpay'), AlertInputProblem.notProvider);
      expect(alertInputProblem('綠界的網址', 'ecpay'), AlertInputProblem.notProvider);
      expect(alertInputProblem('https://payment.ecpay.com.tw/Broadcaster/AlertBox/$_id', 'ecpay'), isNull);
      // The other service's URL in this one's field.
      expect(alertInputProblem('https://payment.opay.tw/Broadcaster/AlertBox/$_id', 'ecpay'), AlertInputProblem.otherProvider);
      expect(alertInputProblem('https://payment.ecpay.com.tw/Broadcaster/AlertBox/$_id', 'opay'), AlertInputProblem.otherProvider);
      expect(alertInputProblem('https://vendor-stage.opay.tw/', 'opay'), AlertInputProblem.otherPage);
      expect(alertInputProblem('EkRm7iFT261dpevs', 'opay'), AlertInputProblem.secretKey);
      expect(alertInputProblem('https://payment-stage.opay.tw/Broadcaster/AlertBox/$_id', 'opay'), isNull);
    });
  });

  group('O\'Pay alert box', () {
    test('accepts the alert URL and the donate link, on live and stage', () {
      final box = AlertBox.parse('https://payment.opay.tw/Broadcaster/AlertBox/$_id')!;
      expect((box.provider, box.host, box.isStage), ('opay', 'https://payment.opay.tw', false));
      final stage = AlertBox.parse('https://payment-stage.opay.tw/Broadcaster/Donate/${_id.toLowerCase()}', provider: 'opay')!;
      expect((stage.isStage, stage.alertUrl), (true, 'https://payment-stage.opay.tw/Broadcaster/AlertBox/$_id'));
      expect(AlertBox.parse('https://payment.opay.tw/Broadcaster/AlertBox/$_id', provider: 'ecpay'), isNull);
    });

    test('reads the Socket.IO server, namespace and auth from the alert page', () {
      const html = '''
    var namespace = "";
    var auth = {};
        namespace = "/web/live/" + "$_id";
        socket = io("https://socket.opay.tw" + namespace, {''';
      final page = OpayPage.parse(html)!;
      expect((page.server, page.namespace), ('https://socket.opay.tw', '/web/live/$_id'));
      expect(page.auth, isEmpty);
      expect(OpayPage.parse('<script>alert(\'連結錯誤\');</script>'), isNull);
    });

    test('Engine.IO / Socket.IO v4 packets', () {
      final open = SioPacket.parse('0{"sid":"x","pingInterval":25000,"pingTimeout":20000}')!;
      expect((open.engine, (open.data as Map)['pingInterval']), (0, 25000));
      expect(SioPacket.parse('2')!.engine, 2);
      final joined = SioPacket.parse('40/web/live/$_id,{"sid":"y"}')!;
      expect((joined.engine, joined.socket, joined.namespace), (4, 0, '/web/live/$_id'));
      final ev = SioPacket.parse('42/web/live/$_id,["notify",{"data":{"lstDonate":[]}}]')!;
      expect((ev.socket, (ev.data as List).first), (2, 'notify'));
      final acked = SioPacket.parse('42/web/live/$_id,7["notify",{}]')!;
      expect((acked.data as List).first, 'notify', reason: 'an ack id before the payload');
      expect(SioPacket.parse('44/web/live/$_id,{"message":"no"}')!.socket, 4);
    });

    test('the donations in a notify', () {
      final at = DateTime(2026, 11, 28);
      final ds = donationsFromNotify({
        'data': {
          'settings': {'BgColor': '#00FF00'},
          'lstDonate': [
            {'donateid': 'D1', 'name': '小明', 'amount': 300, 'msg': '加油'},
            {'donateid': 'D2', 'name': '小華', 'amount': '150.0000', 'msg': null},
            {'donateid': 'D3', 'name': 'x', 'amount': 'n/a'},
          ],
        },
      }, now: at);
      expect([for (final d in ds) '${d.source} ${d.id} ${d.name} ${d.amount} ${d.message}'], ['opay D1 小明 300 加油', 'opay D2 小華 150 ']);
      expect(donationsFromNotify(null), isEmpty);
    });
  });

  group('cheer in the score', () {
    Map<String, dynamic> score(double total) => {'total': total, 'rank': rankForTotal(total), 'raw_total': total, 'scale': scoreScaleVersion};

    test('adds the points and raises the rank, keeping the score as sung', () {
      final j = withCheer(score(97.5), 1);
      expect((j['total'], j['rank']), (98.5, 'SSS'));
      expect(j['cheer'], {'points': 1.0, 'base_total': 97.5, 'base_rank': 'SS'});
    });

    test('again (more donations) counts from the score as sung, not twice', () {
      final once = withCheer(score(80), 1);
      final twice = withCheer(once, 3);
      expect(twice['total'], 83);
      expect((twice['cheer'] as Map)['base_total'], 80);
    });

    test('stops at 100', () {
      final j = withCheer(score(99.5), 4);
      expect((j['total'], j['rank']), (100.0, 'SSS'));
      expect(withCheer(score(100), 2)['total'], 100);
    });

    test('an older score is put on the current scale first', () {
      final j = withCheer({'total': 80.0, 'raw_total': 80.0, 'scale': 2}, 1);
      expect(j['scale'], scoreScaleVersion);
      expect(j['total'], scaledTotal(80) + 1);
    });

    test('no points gives the score as sung back', () {
      final j = withCheer(withCheer(score(80), 5), 0);
      expect((j['total'], j.containsKey('cheer')), (80.0, false));
    });
  });

  test('item points: one for every full NT\$10, the rest dropped (fixed)', () {
    expect(kCheerTwdPerItemPoint, 10);
    expect([for (final a in [0, 9, 10, 19, 150, 299, 1000]) cheerItemPoints(a)], [0, 0, 1, 1, 15, 29, 100]);
  });

  test('points: one for every full NT\$150 of a donation, the rest dropped', () {
    expect(cheerPoints(150, 150), 1);
    expect(cheerPoints(123, 150), 0);
    expect(cheerPoints(299, 150), 1);
    expect(cheerPoints(300, 150), 2);
    expect(cheerPoints(1000, 150), 6);
    expect(cheerPoints(100, 0), 0);
  });

  group('crediting', () {
    late Directory tmp;
    late SongLibrary library;
    late AppSettings settings;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('cheer_test');
      library = SongLibrary(AppPaths.forTest(tmp.path));
      SharedPreferences.setMockInitialValues({});
      settings = await AppSettings.load();
    });
    tearDown(() => tmp.delete(recursive: true));

    TakeInfo? takeOf(List<TakeInfo> takes, String dir) => takes.where((t) => t.dir == dir).firstOrNull;

    Directory take(Song song, String at, double total) {
      final d = Directory(p.join(library.files(song).takesDir, at.replaceAll(':', '_')))..createSync(recursive: true);
      File(p.join(d.path, 'score.json')).writeAsStringSync(jsonEncode({
        'total': total,
        'rank': rankForTotal(total),
        'scale': scoreScaleVersion,
        'sub_scores_flat': {'pitch': 80},
      }));
      return d;
    }

    Donation donation(String name, int amount) => Donation(source: 'ecpay', name: name, amount: amount, message: 'hi', receivedAt: DateTime(2026, 11, 27));

    test('goes to the newest take, kept in cheer.json beside the score', () async {
      final a = await library.create(title: 'A', sourceType: SourceType.file);
      final b = await library.create(title: 'B', sourceType: SourceType.file);
      take(a, '2026-11-27T20:00:00', 80);
      final newest = take(b, '2026-11-27T21:00:00', 90);
      final cheer = CheerService(library: library, settings: settings);
      addTearDown(cheer.dispose);

      final changed = <String?>[];
      library.takesChanged.addListener(() => changed.add(library.takesChanged.value?.songId));
      final c1 = (await cheer.receive(donation('甲', 150)))!;
      final c2 = (await cheer.receive(donation('乙', 123)))!;
      final c3 = (await cheer.receive(donation('丙', 450)))!;
      expect((c1.songTitle, c1.points, c1.before, c1.after, c1.beforeRank, c1.afterRank), ('B', 1.0, 90.0, 91.0, 'A', 'S'));
      expect((c2.points, c2.before, c2.after), (0.0, 91.0, 91.0), reason: 'under NT\$150: no point');
      expect((c3.points, c3.before, c3.after, c3.afterRank), (3.0, 91.0, 94.0, 'S'));
      expect(cheer.last, c3);
      expect(changed, [b.id, b.id, b.id], reason: 'the library reloads the song');

      final t = takeOf(await library.takes(b), newest.path)!;
      final kept = await TakeCheer.load(t.dir);
      expect([for (final (d, pts) in kept.items) '${d.name} ${d.amount} $pts'], ['甲 150 1.0', '乙 123 0.0', '丙 450 3.0']);
      expect(kept.points, 4);
      expect(kept.amount, 723);
      expect((t.total, t.rank), (94.0, 'S'), reason: 'the points are in the score');
      final score = jsonDecode(File(p.join(t.dir, 'score.json')).readAsStringSync()) as Map;
      expect(score['cheer'], {'points': 4.0, 'base_total': 90.0, 'base_rank': 'A'});
      expect(cheer.cached(t).points, 4);
      final older = takeOf(await library.takes(a), p.join(library.files(a).takesDir, '2026-11-27T20_00_00'))!;
      expect((await TakeCheer.load(older.dir)).isEmpty, isTrue);
      expect(older.total, 80);
    });

    test('a take credited before (cheer.json, score without it) is fixed at start', () async {
      final a = await library.create(title: 'A', sourceType: SourceType.file);
      final d = take(a, '2026-11-27T20:00:00', 80);
      await TakeCheer.add(d.path, donation('甲', 300), 2);
      final cheer = CheerService(library: library, settings: settings);
      addTearDown(cheer.dispose);
      await cheer.receive(donation('乙', 150)); // waits for the start-up pass
      expect((await library.takes(a)).single.total, 83);
    });

    test('a donation sent again (same service and id) counts once, across restarts', () async {
      final a = await library.create(title: 'A', sourceType: SourceType.file);
      take(a, '2026-11-27T20:00:00', 80);
      Donation op(String id) => Donation(source: 'opay', name: '甲', amount: 300, message: '', receivedAt: DateTime(2026, 11, 28), id: id);
      final cheer = CheerService(library: library, settings: settings);
      addTearDown(cheer.dispose);
      expect(await cheer.receive(op('D1')), isNotNull);
      expect(await cheer.receive(op('D1')), isNull);
      expect(await cheer.receive(op('D2')), isNotNull);
      expect((await library.takes(a)).single.total, 84);
      final again = CheerService(library: library, settings: await AppSettings.load());
      addTearDown(again.dispose);
      expect(await again.receive(op('D2')), isNull, reason: 'remembered after a restart');
    });

    test('both services set up: both listed, in order', () async {
      final cheer = CheerService(library: library, settings: settings);
      addTearDown(cheer.dispose);
      await settings.setAlertUrlOf('opay', 'https://payment-stage.opay.tw/Broadcaster/AlertBox/$_id');
      expect(cheer.providers, ['opay']);
      await settings.setAlertUrlOf('ecpay', 'https://payment-stage.ecpay.com.tw/Broadcaster/AlertBox/$_id');
      expect(cheer.providers, ['ecpay', 'opay']);
      expect(cheer.enabled, isFalse, reason: 'set up, not turned on');
    });

    test('each donation gives item points and is reported (achievements, wallet)', () async {
      final got = <CheerCredit>[];
      final cheer = CheerService(library: library, settings: settings, onCheer: got.add);
      addTearDown(cheer.dispose);
      final c = (await cheer.receive(donation('甲', 123)))!;
      expect((c.points, c.itemPoints), (0.0, 12), reason: 'no score point under NT\$150, but 12 item points');
      expect(got, [c]);
    });

    test('uses the rate in the settings at the time', () async {
      final a = await library.create(title: 'A', sourceType: SourceType.file);
      take(a, '2026-11-27T20:00:00', 80);
      await settings.setCheerTwdPerPoint(200);
      final cheer = CheerService(library: library, settings: settings);
      addTearDown(cheer.dispose);
      expect((await cheer.receive(donation('甲', 450)))!.points, 2);
    });

    test('the rate is 150 by default and never less', () async {
      expect(settings.cheerTwdPerPoint, 150);
      await settings.setCheerTwdPerPoint(100);
      expect(settings.cheerTwdPerPoint, 150);
      SharedPreferences.setMockInitialValues({'cheer_twd_per_point': 50});
      expect((await AppSettings.load()).cheerTwdPerPoint, 150, reason: 'an older, lower rate is raised');
    });

    test('with nothing sung yet it is shown but not credited', () async {
      final cheer = CheerService(library: library, settings: settings);
      addTearDown(cheer.dispose);
      final c = (await cheer.receive(donation('甲', 300)))!;
      expect(c.songTitle, isNull);
      expect(c.points, 2);
    });

    test('on only with a payment service set up', () async {
      final cheer = CheerService(library: library, settings: settings);
      addTearDown(cheer.dispose);
      await settings.setCheerEnabled(true);
      expect((cheer.configured, cheer.enabled), (false, false));
      expect(cheer.providers, isEmpty);
      // Stage host; the client starts connecting in the background, which a
      // test cannot reach, so turn it off again right away.
      await settings.setEcpayAlertUrl('https://payment-stage.ecpay.com.tw/Broadcaster/AlertBox/$_id');
      expect((cheer.configured, cheer.enabled), (true, true));
      expect(cheer.providers, ['ecpay']);
      await settings.setCheerEnabled(false);
      expect(cheer.enabled, isFalse);
    });
  });
}
