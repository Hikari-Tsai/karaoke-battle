// 觀眾加油 (直播工具): while it is on, each donation a viewer makes through a
// connected payment service adds points to the last song sung: one point
// for every full NT$150 (the rate in the settings) of it, the rest dropped.
//
// The points go into the take's score (take_cheer.dart: cheer.json beside
// score.json, which also keeps the score as sung), so the library, records
// and the 直播工具 list show the score with cheer, up to 100.
// 綠界 (ECPay, ecpay_alert.dart) and 歐付寶 (O'Pay, opay_alert.dart), each
// through its 贊助成功動畫網址; both at once when both are set up.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../state/take_cheer.dart';
import 'app_log.dart';
import 'ecpay_alert.dart';
import 'opay_alert.dart';
import 'settings.dart';
import 'sing_history.dart';
import 'song_library.dart';

/// The test 贊助成功動畫網址 filled in in 開發模式: the AlertBox of ECPay's
/// public test merchant 3002607 (stagetest3) on the stage environment.
const kEcpayStageTestAlertUrl = 'https://payment-stage.ecpay.com.tw/Broadcaster/AlertBox/C1B8B9E32C2467466E4A8B4CE4A99378';

/// ECPay's stage back office page whose 查看效果 sends a test donation.
const kEcpayStageAnimationSetup = 'https://vendor-stage.ecpay.com.tw/Broadcaster/AnimationSetup';

/// O'Pay's stage 實況主收款設定 (a personal member's page: log in by scanning
/// its QR code with O'Pay's test app and the public test account on the
/// login page); its 贊助成功動畫 tab's 測試動畫效果 sends a test donation.
const kOpayStageBackOffice = 'https://payment-stage.opay.tw/Broadcaster/Setup';

/// The test 贊助成功動畫網址 filled in in 開發模式 for 歐付寶: the alert box
/// of O'Pay's public test personal member on the stage environment.
const kOpayStageTestAlertUrl = 'https://payment-stage.opay.tw/Broadcaster/AlertBox/740F06A8DEBBE6566C8824D938FA403B';

/// Points for one donation of [amount] NT$: one for every full
/// [twdPerPoint] NT$, the rest dropped (NT$299 at 150 is 1 point).
double cheerPoints(int amount, int twdPerPoint) => twdPerPoint <= 0 || amount <= 0 ? 0 : (amount ~/ twdPerPoint).toDouble();

/// Item points (點數) a donation gives besides the score: one for every
/// full NT\$[kCheerTwdPerItemPoint], the rest dropped. Fixed, not a setting.
const kCheerTwdPerItemPoint = 10;
int cheerItemPoints(int amount) => amount <= 0 ? 0 : amount ~/ kCheerTwdPerItemPoint;

/// One donation credited to a take.
class CheerCredit {
  const CheerCredit({required this.donation, required this.points, this.itemPoints = 0, this.songTitle, this.takeKey, this.before, this.beforeRank, this.after, this.afterRank});
  final Donation donation;
  final double points;

  /// Item points (點數) it gave (see [cheerItemPoints]).
  final int itemPoints;

  /// The song it went to; null when nothing had been sung yet.
  final String? songTitle;
  final String? takeKey;

  /// The take's score (and rank) before and after this donation.
  final double? before, after;
  final String? beforeRank, afterRank;
}

class CheerService extends ChangeNotifier {
  CheerService({required this.library, required this.settings, this.onCheer}) {
    settings.addListener(_sync);
    _sync();
    _writes = _reconcile();
  }

  /// Takes credited before the points went into the score (or whose
  /// score.json was replaced) get them added now.
  Future<void> _reconcile() async {
    try {
      for (final song in library.songs) {
        var changed = false;
        for (final t in await library.takes(song)) {
          if (t.total == null || (await TakeCheer.load(t.dir)).isEmpty) continue;
          final r = await applyCheerToTake(t.dir);
          if (r != null && r.after != r.before) changed = true;
        }
        if (changed) library.markTakesChanged(library.files(song));
      }
    } catch (e) {
      AppLog.warn('cheer: $e');
    }
  }

  final SongLibrary library;
  final AppSettings settings;

  /// Each new donation (for the achievements and the item points).
  final void Function(CheerCredit credit)? onCheer;

  /// One live connection per service set up (while 觀眾加油 is on).
  final _clients = <String, DonationSource>{};
  final _subs = <String, StreamSubscription<Donation>>{};

  /// 歐付寶 resends recent donations: their ids, so each counts once (kept
  /// in the settings across restarts).
  late final Set<String> _seen = {...settings.cheerSeenIds};
  final _cache = <String, TakeCheer>{};
  Future<void> _writes = Future.value();

  final _credits = StreamController<CheerCredit>.broadcast();

  /// Each donation as it is credited (for the celebration).
  Stream<CheerCredit> get credits => _credits.stream;

  /// The most recent donation this session.
  CheerCredit? last;

  /// The alert box set up for [provider] ('ecpay' or 'opay'), or null.
  AlertBox? boxOf(String provider) => AlertBox.parse(settings.alertUrlOf(provider), provider: provider);
  AlertBox? get ecpay => boxOf('ecpay');
  AlertBox? get opay => boxOf('opay');

  /// The services set up, in order (for 觀眾加油：綠界、歐付寶).
  List<String> get providers => [for (final p in kCheerProviders) if (boxOf(p) != null) p];

  /// A payment service is set up (so 觀眾加油 can be turned on).
  bool get configured => providers.isNotEmpty;

  bool get enabled => settings.cheerEnabled && configured;
  AlertStatus statusOf(String provider) => _clients[provider]?.status.value ?? AlertStatus.off;
  String? lastErrorOf(String provider) => _clients[provider]?.lastError;

  /// Starts, restarts or stops each connection to match the settings.
  void _sync() {
    for (final p in kCheerProviders) {
      final box = enabled ? boxOf(p) : null;
      final old = _clients[p];
      if (box == old?.box) continue;
      _subs.remove(p)?.cancel();
      _clients.remove(p);
      if (old != null) {
        old.status.removeListener(notifyListeners);
        unawaited(old.dispose());
      }
      if (box != null) {
        final DonationSource c = p == 'opay' ? OpayAlertClient(box) : EcpayAlertClient(box);
        c.status.addListener(notifyListeners);
        _subs[p] = c.donations.listen(_onDonation);
        _clients[p] = c;
        c.start();
        AppLog.info('cheer: listening to $p${box.isStage ? ' (stage)' : ''}');
      }
    }
    notifyListeners();
  }

  /// Credits [d] to the newest take in the 直播工具 list and adds its
  /// points to that take's score.
  Future<CheerCredit?> _onDonation(Donation d) {
    // A donation already counted (歐付寶 sends the recent ones again).
    if (d.id != null) {
      final key = '${d.source}:${d.id}';
      if (!_seen.add(key)) return Future.value();
      unawaited(settings.setCheerSeenIds([..._seen]));
    }
    final done = _writes.then((_) async {
      final points = cheerPoints(d.amount, settings.cheerTwdPerPoint);
      final itemPoints = cheerItemPoints(d.amount);
      final entries = await loadSingHistory(library, clearedAt: settings.historyClearedAt, hidden: settings.historyHidden);
      CheerCredit credit;
      if (entries.isEmpty) {
        credit = CheerCredit(donation: d, points: points, itemPoints: itemPoints);
      } else {
        final e = entries.first;
        _cache[e.take.dir] = await TakeCheer.add(e.take.dir, d, points);
        final score = await applyCheerToTake(e.take.dir);
        library.markTakesChanged(library.files(e.song));
        credit = CheerCredit(
          donation: d,
          points: points,
          itemPoints: itemPoints,
          songTitle: e.song.title,
          takeKey: e.key,
          before: score?.before,
          beforeRank: score?.beforeRank,
          after: score?.after,
          afterRank: score?.afterRank,
        );
      }
      AppLog.info('cheer: ${d.source} NT\$${d.amount} → ${credit.songTitle ?? '(no take)'} +${credit.points} (${credit.before} → ${credit.after})');
      last = credit;
      onCheer?.call(credit);
      _credits.add(credit);
      notifyListeners();
      return credit;
    });
    _writes = done.then((_) {}, onError: (Object e) => AppLog.warn('cheer: $e'));
    return done;
  }

  /// For tests and 開發模式: handle [d] as if it had arrived.
  @visibleForTesting
  Future<CheerCredit?> receive(Donation d) => _onDonation(d);

  /// The cheer on [take] (cached after the first read).
  TakeCheer cached(TakeInfo take) => _cache[take.dir] ?? TakeCheer.empty;
  Future<TakeCheer> cheerOf(TakeInfo take) async => _cache[take.dir] ??= await TakeCheer.load(take.dir);

  @override
  void dispose() {
    settings.removeListener(_sync);
    for (final s in _subs.values) {
      s.cancel();
    }
    for (final c in _clients.values) {
      c.status.removeListener(notifyListeners);
      unawaited(c.dispose());
    }
    _clients.clear();
    _credits.close();
    super.dispose();
  }
}
