// 綠界「實況主收款」donations, live: listens on the same SignalR channel as
// the 贊助成功動畫網址 (the AlertBox page an OBS browser source shows).
//
// Unofficial: ECPay documents no API for this. The AlertBox page carries a
// short-lived JWT (15 minutes) for https://signalr.ecpay.com.tw/donateHub;
// the hub calls a method named after the page's ID with (name, amount,
// message). Only the page URL is needed, no login and no merchant keys.
// Amounts come as "100" (the back office's test alert) or "123.0000" (a real
// payment). See notes/donation-feasibility.md.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'donation.dart';

export 'donation.dart';

/// What the AlertBox page tells a listener: the hub, its token and the
/// method name donations arrive on.
class AlertPage {
  const AlertPage(this.hub, this.token, this.method);
  final String hub, token, method;

  static AlertPage? parse(String html) {
    final hub = RegExp(r"withUrl\(\s*'([^']+)'\s*\+\s*'([^']+)'").firstMatch(html);
    final tok = RegExp(r'loginToken\s*=\s*"([^"]+)"').firstMatch(html);
    final on = RegExp(r'connection\.on\(\s*"([^"]+)"').firstMatch(html);
    if (hub == null || tok == null || on == null) return null;
    return AlertPage('${hub[1]}${hub[2]}', tok[1]!, on[1]!);
  }
}

/// SignalR's JSON protocol ends every message with this.
const _rs = '\u001e';

/// Splits [buffer] into complete SignalR frames; returns them and what is
/// left over (a frame still arriving).
(List<Map<String, dynamic>>, String) splitFrames(String buffer) {
  final out = <Map<String, dynamic>>[];
  var rest = buffer;
  while (true) {
    final i = rest.indexOf(_rs);
    if (i < 0) break;
    final frame = rest.substring(0, i);
    rest = rest.substring(i + 1);
    if (frame.isEmpty) continue;
    try {
      final j = jsonDecode(frame);
      if (j is Map<String, dynamic>) out.add(j);
    } catch (_) {}
  }
  return (out, rest);
}

/// The donation in an invocation frame for [method], or null.
Donation? donationFromFrame(Map<String, dynamic> frame, String method, {DateTime? now}) {
  if (frame['type'] != 1 || '${frame['target']}'.toUpperCase() != method.toUpperCase()) return null;
  final args = frame['arguments'];
  if (args is! List || args.length < 2) return null;
  final amount = parseAmount(args[1]);
  if (amount == null) return null;
  return Donation(
    source: 'ecpay',
    name: '${args[0] ?? ''}',
    amount: amount,
    message: args.length > 2 && args[2] != null ? '${args[2]}' : '',
    receivedAt: now ?? DateTime.now(),
  );
}

/// Keeps one connection to an AlertBox's hub while started, reconnecting
/// (with a fresh token from the page) when it drops.
class EcpayAlertClient implements DonationSource {
  EcpayAlertClient(this.box);
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
  Timer? _ping, _retry;
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
    _ping?.cancel();
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
      final page = await fetchAlertPage(box);
      final connToken = await _negotiate(page);
      final wsUrl = page.hub.replaceFirst(RegExp('^http'), 'ws');
      final ws = await WebSocket.connect(
        '$wsUrl?id=${Uri.encodeQueryComponent(connToken)}&access_token=${Uri.encodeQueryComponent(page.token)}',
      ).timeout(const Duration(seconds: 15));
      if (!_running) {
        await ws.close();
        return;
      }
      _ws = ws;
      ws.add('${jsonEncode({'protocol': 'json', 'version': 1})}$_rs');
      var handshook = false;
      var buf = '';
      _ping?.cancel();
      _ping = Timer.periodic(const Duration(seconds: 15), (_) {
        try {
          ws.add('{"type":6}$_rs');
        } catch (_) {}
      });
      ws.listen((data) {
        final (frames, rest) = splitFrames(buf + (data is String ? data : utf8.decode(data as List<int>)));
        buf = rest;
        for (final f in frames) {
          if (!handshook) {
            if (f['error'] != null) {
              lastError = '${f['error']}';
              ws.close();
              return;
            }
            handshook = true;
            _failures = 0;
            lastError = null;
            status.value = AlertStatus.connected;
            continue;
          }
          if (f['type'] == 7) lastError = f['error'] == null ? null : '${f['error']}';
          final d = donationFromFrame(f, page.method);
          if (d != null) _donations.add(d);
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

  void _dropped(WebSocket ws) {
    if (_ws != ws) return;
    _ws = null;
    _ping?.cancel();
    _scheduleRetry();
  }

  /// First retry soon; after that the AlertBox page's own 30–120 s, so a
  /// restarted hub does not get every client back at once.
  void _scheduleRetry() {
    if (!_running) return;
    status.value = AlertStatus.error;
    _failures++;
    final seconds = _failures == 1 ? 5 : 30 + _rnd.nextInt(90);
    _retry?.cancel();
    _retry = Timer(Duration(seconds: seconds), _connect);
  }

  Future<String> _negotiate(AlertPage page) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await c.postUrl(Uri.parse('${page.hub}/negotiate?negotiateVersion=1'));
      req.headers.set('Authorization', 'Bearer ${page.token}');
      req.headers.contentLength = 0;
      final res = await req.close().timeout(const Duration(seconds: 15));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode != 200) throw HttpException('negotiate HTTP ${res.statusCode}');
      final j = jsonDecode(body) as Map<String, dynamic>;
      return '${j['connectionToken'] ?? j['connectionId']}';
    } finally {
      c.close();
    }
  }
}

/// Reads the AlertBox page; throws when it cannot be read or no longer has
/// the parts we look for (ECPay changed it, or the ID is wrong).
Future<AlertPage> fetchAlertPage(AlertBox box) async {
  final c = HttpClient()
    ..userAgent = 'Mozilla/5.0'
    ..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await c.getUrl(Uri.parse(box.alertUrl));
    final res = await req.close().timeout(const Duration(seconds: 15));
    final html = await res.transform(utf8.decoder).join();
    if (res.statusCode != 200) throw HttpException('AlertBox HTTP ${res.statusCode}');
    final page = AlertPage.parse(html);
    if (page == null) throw const FormatException('alert page not recognised');
    return page;
  } finally {
    c.close();
  }
}
