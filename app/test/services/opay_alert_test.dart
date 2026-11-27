// OpayAlertClient end to end against a local stand-in for O'Pay: the
// AlertBox page, then Socket.IO v4 over a WebSocket (open, namespace
// connect, pings, "notify" events) as payment.opay.tw / socket.opay.tw
// serve them.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/donation.dart';
import 'package:karaoke_battle/services/opay_alert.dart';

const _id = 'C1B8B9E32C2467466E4A8B4CE4A99378';

void main() {
  late HttpServer server;
  late String origin;
  final sent = <String>[];
  WebSocket? socket;
  final connected = Completer<void>();

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      if (req.uri.path == '/Broadcaster/AlertBox/$_id') {
        req.response.headers.contentType = ContentType.html;
        req.response.write('''
<script>
    var namespace = "";
    var auth = {};
        namespace = "/web/live/" + "$_id";
    function createSocket(namespace ,auth ,query){
        socket = io("$origin" + namespace, { reconnectionDelayMax : 10000, auth : auth, query : query });
    }
</script>''');
        await req.response.close();
        return;
      }
      if (req.uri.path == '/socket.io/' && req.uri.queryParameters['EIO'] == '4' && WebSocketTransformer.isUpgradeRequest(req)) {
        final ws = socket = await WebSocketTransformer.upgrade(req);
        ws.add('0{"sid":"s1","upgrades":[],"pingInterval":25000,"pingTimeout":20000,"maxPayload":1000000}');
        ws.listen((m) {
          sent.add('$m');
          if ('$m'.startsWith('40/web/live/$_id,')) {
            ws.add('40/web/live/$_id,{"sid":"n1"}');
            if (!connected.isCompleted) connected.complete();
          }
        });
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });
  });
  tearDown(() => server.close(force: true));

  test('joins the namespace, answers pings and reports each donation', () async {
    final client = OpayAlertClient(AlertBox('opay', origin, _id));
    final got = <Donation>[];
    client.donations.listen(got.add);
    final statuses = <AlertStatus>[];
    client.status.addListener(() => statuses.add(client.status.value));
    client.start();
    await connected.future.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(statuses.last, AlertStatus.connected);
    expect(sent.first, '40/web/live/$_id,{}', reason: 'joins with the page\'s (empty) auth');

    socket!.add('2');
    socket!.add('42/web/live/$_id,${jsonEncode([
          'notify',
          {
            'data': {
              'settings': {'MsgTemplate': '感謝 {name} 贊助 {amount} 元'},
              'lstDonate': [
                {'donateid': 'D9', 'name': '小明', 'amount': 300, 'msg': '加油！'},
              ],
            },
          },
        ])}');
    // Another namespace's event is not ours.
    socket!.add('42/web/live/OTHER,["notify",{"data":{"lstDonate":[{"donateid":"X","name":"x","amount":1}]}}]');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(sent, contains('3'), reason: 'pong');
    expect([for (final d in got) '${d.source} ${d.id} ${d.name} ${d.amount} ${d.message}'], ['opay D9 小明 300 加油！']);

    await client.dispose();
    expect(client.status.value, AlertStatus.off);
  });

  test('an unknown ID (a page that only says 連結錯誤) is an error, retried', () async {
    final client = OpayAlertClient(AlertBox('opay', origin, '0' * 32));
    final done = Completer<void>();
    client.status.addListener(() {
      if (client.status.value == AlertStatus.error && !done.isCompleted) done.complete();
    });
    client.start();
    await done.future.timeout(const Duration(seconds: 5));
    expect(client.lastError, isNotNull);
    await client.dispose();
  });
}
