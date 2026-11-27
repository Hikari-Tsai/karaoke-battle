// 歐付寶「實況主收款」donations, live: listens on the same Socket.IO channel
// as the 贊助成功動畫網址 (the AlertBox page an OBS browser source shows).
//
// Unofficial: O'Pay documents no API for this. The AlertBox page connects
// Socket.IO v4 to https://socket.opay.tw (socket-stage on stage) in the
// namespace /web/live/<ID> with empty auth, and the server emits "notify"
// with {data: {settings, lstDonate: [{donateid, name, amount, msg}]}}.
// Only the page URL is needed. The Socket.IO / Engine.IO v4 framing is done
// here over a plain WebSocket, so no package is needed.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'donation.dart';

/// What the AlertBox page tells a listener: the Socket.IO server, the
/// namespace and the auth it connects with.
class OpayPage {
  const OpayPage(this.server, this.namespace, this.auth);
  final String server, namespace;
  final Map<String, dynamic> auth;

  static OpayPage? parse(String html) {
    final io = RegExp(r'''io\(\s*["']([^"']+)["']\s*\+\s*namespace''').firstMatch(html);
    final ns = RegExp(r'''namespace\s*=\s*["']([^"']*)["']\s*\+\s*["']([^"']*)["']''').firstMatch(html);
    if (io == null || ns == null) return null;
    var auth = <String, dynamic>{};
    final a = RegExp(r'var\s+auth\s*=\s*(\{[^;]*\})\s*;').firstMatch(html);
    if (a != null) {
      try {
        final j = jsonDecode(a[1]!);
        if (j is Map<String, dynamic>) auth = j;
      } catch (_) {}
    }
    return OpayPage(io[1]!, '${ns[1]}${ns[2]}', auth);
  }
}

/// One Socket.IO v4 packet as Engine.IO carries it: "2" ping, "40/nsp,{…}"
/// connect, "42/nsp,["event",…]" event, "44/nsp,{…}" connect error.
class SioPacket {
  const SioPacket(this.engine, {this.socket, this.namespace = '/', this.data});

  /// Engine.IO type: 0 open, 1 close, 2 ping, 3 pong, 4 message.
  final int engine;

  /// Socket.IO type inside a message: 0 connect, 1 disconnect, 2 event,
  /// 4 connect error.
  final int? socket;
  final String namespace;
  final Object? data;

  static SioPacket? parse(String s) {
    if (s.isEmpty) return null;
    final engine = int.tryParse(s[0]);
    if (engine == null) return null;
    if (engine != 4) {
      Object? data;
      if (s.length > 1) {
        try {
          data = jsonDecode(s.substring(1));
        } catch (_) {}
      }
      return SioPacket(engine, data: data);
    }
    if (s.length < 2) return null;
    final socket = int.tryParse(s[1]);
    var rest = s.substring(2);
    var namespace = '/';
    if (rest.startsWith('/')) {
      final comma = rest.indexOf(',');
      namespace = comma < 0 ? rest : rest.substring(0, comma);
      rest = comma < 0 ? '' : rest.substring(comma + 1);
    }
    // An ack id may come before the payload.
    rest = rest.replaceFirst(RegExp(r'^\d+'), '');
    Object? data;
    if (rest.isNotEmpty) {
      try {
        data = jsonDecode(rest);
      } catch (_) {}
    }
    return SioPacket(4, socket: socket, namespace: namespace, data: data);
  }
}

/// The donations in a "notify" event's payload (`{data: {lstDonate}}`).
List<Donation> donationsFromNotify(Object? payload, {DateTime? now}) {
  final data = payload is Map ? payload['data'] : null;
  final list = data is Map ? data['lstDonate'] : null;
  if (list is! List) return const [];
  return [
    for (final e in list.whereType<Map>())
      if (parseAmount(e['amount']) case final amount?)
        Donation(
          source: 'opay',
          name: '${e['name'] ?? ''}',
          amount: amount,
          message: e['msg'] == null ? '' : '${e['msg']}',
          receivedAt: now ?? DateTime.now(),
          id: e['donateid'] == null ? null : '${e['donateid']}',
        ),
  ];
}

/// Keeps one Socket.IO connection to an AlertBox's namespace while started,
/// reconnecting when it drops.
class OpayAlertClient implements DonationSource {
  OpayAlertClient(this.box);
  @override
  final AlertBox box;

  final _donations = StreamController<Donation>.broadcast();
  @override
  Stream<Donation> get donations => _donations.stream;

  @override
  final status = ValueNotifierLite<AlertStatus>(AlertStatus.off);
  @override
  String? lastError;

  bool _running = false;
  WebSocket? _ws;
  Timer? _retry, _watchdog;
  int _failures = 0;
  final _rnd = Random();

  @override
  void start() {
    if (_running) return;
    _running = true;
    unawaited(_connect());
  }

  Future<void> stop() async {
    _running = false;
    _retry?.cancel();
    _watchdog?.cancel();
    final ws = _ws;
    _ws = null;
    await ws?.close();
    status.value = AlertStatus.off;
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _donations.close();
  }

  Future<void> _connect() async {
    if (!_running) return;
    status.value = AlertStatus.connecting;
    try {
      final page = await fetchOpayPage(box);
      final wsUrl = '${page.server.replaceFirst(RegExp('^http'), 'ws')}/socket.io/?EIO=4&transport=websocket';
      final ws = await WebSocket.connect(wsUrl, headers: {'Origin': box.host}).timeout(const Duration(seconds: 15));
      if (!_running) {
        await ws.close();
        return;
      }
      _ws = ws;
      var pingTimeout = const Duration(seconds: 45);
      ws.listen((raw) {
        final p = SioPacket.parse(raw is String ? raw : utf8.decode(raw as List<int>));
        if (p == null) return;
        switch (p.engine) {
          case 0: // open: join the namespace
            final d = p.data;
            if (d is Map && d['pingInterval'] is num && d['pingTimeout'] is num) {
              pingTimeout = Duration(milliseconds: (d['pingInterval'] as num).toInt() + (d['pingTimeout'] as num).toInt());
            }
            _feed(ws, pingTimeout);
            ws.add('40${page.namespace},${jsonEncode(page.auth)}');
          case 2: // ping
            _feed(ws, pingTimeout);
            ws.add('3');
          case 1:
            ws.close();
          case 4 when p.namespace == page.namespace:
            switch (p.socket) {
              case 0:
                _failures = 0;
                lastError = null;
                status.value = AlertStatus.connected;
              case 4:
                lastError = '${p.data}';
                ws.close();
              case 1:
                ws.close();
              case 2:
                final d = p.data;
                if (d is List && d.isNotEmpty && d[0] == 'notify') {
                  for (final don in donationsFromNotify(d.length > 1 ? d[1] : null)) {
                    _donations.add(don);
                  }
                }
            }
        }
      }, onDone: () => _dropped(ws), onError: (Object e) {
        lastError = '$e';
        _dropped(ws);
      }, cancelOnError: true);
    } catch (e) {
      lastError = '$e';
      _scheduleRetry();
    }
  }

  /// No ping within the server's interval + timeout: the link is dead.
  void _feed(WebSocket ws, Duration timeout) {
    _watchdog?.cancel();
    _watchdog = Timer(timeout, () {
      lastError = 'ping timeout';
      ws.close();
    });
  }

  void _dropped(WebSocket ws) {
    if (_ws != ws) return;
    _ws = null;
    _watchdog?.cancel();
    _scheduleRetry();
  }

  /// First retry soon, then 10–40 s (the page itself retries within 10 s).
  void _scheduleRetry() {
    if (!_running) return;
    status.value = AlertStatus.error;
    _failures++;
    final seconds = _failures == 1 ? 3 : 10 + _rnd.nextInt(30);
    _retry?.cancel();
    _retry = Timer(Duration(seconds: seconds), _connect);
  }
}

/// Reads the AlertBox page; throws when it cannot be read or no longer has
/// the parts we look for (O'Pay changed it, or the ID is wrong).
Future<OpayPage> fetchOpayPage(AlertBox box) async {
  final c = HttpClient()
    ..userAgent = 'Mozilla/5.0'
    ..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await c.getUrl(Uri.parse(box.alertUrl));
    final res = await req.close().timeout(const Duration(seconds: 15));
    final html = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) throw HttpException('AlertBox HTTP ${res.statusCode}');
    final page = OpayPage.parse(html);
    // An unknown ID gets a page that only says 連結錯誤 and leaves.
    if (page == null) throw FormatException(html.length < 400 && html.contains('連結錯誤') ? 'alert link not found' : 'alert page not recognised');
    return page;
  } finally {
    c.close();
  }
}
