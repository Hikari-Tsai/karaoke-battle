// What every payment service's live donations share (觀眾加油): a donation,
// the alert URL the streamer pastes (the OBS browser source of 綠界 or 歐付寶
// 實況主收款) and its checks, and the listener each service implements.
// Plain Dart, so it can be tested and run without Flutter.
import 'dart:async';

/// The payment services 觀眾加油 can listen to, in the order shown.
const kCheerProviders = ['ecpay', 'opay'];

/// One donation: who, how much (NT$) and what they wrote; [id] when the
/// service numbers them (歐付寶 does), to tell a repeat from a new one.
class Donation {
  const Donation({required this.source, required this.name, required this.amount, required this.message, required this.receivedAt, this.id});
  final String source;
  final String name;
  final int amount;
  final String message;
  final DateTime receivedAt;
  final String? id;

  Map<String, dynamic> toJson() => {
        'source': source,
        'name': name,
        'amount': amount,
        'msg': message,
        'at': receivedAt.toUtc().toIso8601String(),
        'id': ?id,
      };

  static Donation? fromJson(Object? j) {
    if (j is! Map) return null;
    final amount = j['amount'];
    if (amount is! num) return null;
    return Donation(
      source: '${j['source'] ?? 'ecpay'}',
      name: '${j['name'] ?? ''}',
      amount: amount.round(),
      message: '${j['msg'] ?? ''}',
      receivedAt: DateTime.tryParse('${j['at']}')?.toLocal() ?? DateTime.now(),
      id: j['id'] == null ? null : '${j['id']}',
    );
  }
}

/// "100", "123.0000", 100 → 100; null when it is not a number.
int? parseAmount(Object? v) => v is num ? v.round() : num.tryParse('$v'.trim())?.round();

/// A service's 實況主收款 alert URL (or its donate link: both services use
/// the same ID for the two), reduced to the service, host and 32-hex ID.
class AlertBox {
  const AlertBox(this.provider, this.host, this.id);

  /// 'ecpay' or 'opay'.
  final String provider;
  final String host; // e.g. https://payment.ecpay.com.tw, https://payment-stage.opay.tw
  final String id;

  bool get isStage => host.contains('-stage');
  String get alertUrl => '$host/Broadcaster/AlertBox/$id';
  String get donateUrl => '$host/Broadcaster/Donate/$id';

  static final _patterns = {
    'ecpay': RegExp(r'^https?://(payment(?:-stage)?\.ecpay\.com\.tw)/Broadcaster/(?:AlertBox|Donate)/([0-9A-Fa-f]{32})/?(?:[?#].*)?$'),
    'opay': RegExp(r'^https?://(payment(?:-stage)?\.opay\.tw)/Broadcaster/(?:AlertBox|Donate)/([0-9A-Fa-f]{32})/?(?:[?#].*)?$'),
  };

  /// Accepts `.../Broadcaster/AlertBox/ID` or `.../Broadcaster/Donate/ID` on
  /// [provider]'s payment host (live or stage); any service when null.
  static AlertBox? parse(String input, {String? provider}) {
    for (final e in _patterns.entries) {
      if (provider != null && e.key != provider) continue;
      final m = e.value.firstMatch(input.trim());
      if (m != null) return AlertBox(e.key, 'https://${m[1]}', m[2]!.toUpperCase());
    }
    return null;
  }

  @override
  bool operator ==(Object other) => other is AlertBox && other.alertUrl == alertUrl;
  @override
  int get hashCode => alertUrl.hashCode;
}

/// What is wrong with what was typed where an alert URL goes.
enum AlertInputProblem {
  /// Nothing typed.
  empty,

  /// Looks like a HashKey or HashIV (or another API key): never needed here.
  secretKey,

  /// Looks like a 特店編號 (MerchantID).
  merchantId,

  /// The 32-hex ID alone, without the address.
  bareId,

  /// A short donate link (p.ecpay.com.tw/…), which hides the ID.
  shortLink,

  /// Another page of the same service (the back office, a payment page…).
  otherPage,

  /// The other service's alert URL, in this one's field.
  otherProvider,

  /// Not this service's address at all.
  notProvider,
}

/// Null when [input] is [provider]'s alert URL (or donate link); otherwise
/// what it looks like instead.
AlertInputProblem? alertInputProblem(String input, String provider) {
  final s = input.trim();
  if (s.isEmpty) return AlertInputProblem.empty;
  if (AlertBox.parse(s, provider: provider) != null) return null;
  if (AlertBox.parse(s) != null) return AlertInputProblem.otherProvider;
  final lower = s.toLowerCase();
  if (RegExp(r'^[0-9a-f]{32}$').hasMatch(lower)) return AlertInputProblem.bareId;
  if (lower.contains('hashkey') || lower.contains('hashiv') || lower.contains('hash key') || lower.contains('hash iv')) return AlertInputProblem.secretKey;
  if (RegExp(r'^\d{6,10}$').hasMatch(s)) return AlertInputProblem.merchantId;
  final isUrl = RegExp(r'^[a-z][a-z0-9+.-]*://').hasMatch(lower) || lower.startsWith('www.') || RegExp(r'^[a-z0-9-]+(\.[a-z0-9-]+)+/').hasMatch(lower);
  // A HashKey / HashIV is a short run of letters and digits (16 at ECPay).
  if (!isUrl && RegExp(r'^[A-Za-z0-9+/=_-]{8,64}$').hasMatch(s)) return AlertInputProblem.secretKey;
  if (!isUrl) return AlertInputProblem.notProvider;
  final host = Uri.tryParse(lower.contains('://') ? lower : 'https://$lower')?.host ?? '';
  final domain = provider == 'opay' ? 'opay.tw' : 'ecpay.com.tw';
  if (host == 'p.$domain' || host == 'p-stage.$domain') return AlertInputProblem.shortLink;
  if (host == domain || host.endsWith('.$domain')) return AlertInputProblem.otherPage;
  final other = provider == 'opay' ? 'ecpay.com.tw' : 'opay.tw';
  if (host == other || host.endsWith('.$other')) return AlertInputProblem.otherProvider;
  return AlertInputProblem.notProvider;
}

enum AlertStatus { off, connecting, connected, error }

/// A live connection to one service's donations.
abstract class DonationSource {
  AlertBox get box;
  Stream<Donation> get donations;
  ValueNotifierLite<AlertStatus> get status;
  String? get lastError;
  void start();
  Future<void> dispose();
}

/// A minimal ValueNotifier that does not need Flutter.
class ValueNotifierLite<T> {
  ValueNotifierLite(this._value);
  T _value;
  final _listeners = <void Function()>[];
  T get value => _value;
  set value(T v) {
    if (v == _value) return;
    _value = v;
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  void addListener(void Function() l) => _listeners.add(l);
  void removeListener(void Function() l) => _listeners.remove(l);
}
