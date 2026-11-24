// Items bought with achievement points (items.json in the data folder, so
// they move with the data). Points are earned by achievements and never go
// down; what items cost is kept apart, so the balance is earned - spent.
// Every sing day (from 5:00) the items held are topped up to a daily
// allowance: unused ones do not pile up, and more than that is kept.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../advice/mentor_relay.dart';
import 'achievements.dart';
import 'sing_history.dart' show dayOf, kDayStartHour;

/// An item that can be redeemed for points.
enum ItemKind {
  /// Makes one note's pitch and timing perfect, then scores the take again.
  tuningWand(10, 3),

  /// Cast before singing: the whole take is judged with pitch and timing
  /// twice as lenient.
  resonanceField(50, 1),

  /// Asks the AI Mentor for singing tips on a take, through the Karaoke
  /// Battle relay (no API key of one's own needed).
  mentorTicket(50, 1);

  const ItemKind(this.cost, this.daily);

  /// Whether it can be had and used now (the AI Mentor waits for its relay).
  bool get available => this != mentorTicket || mentorAvailable;

  /// Points to redeem one.
  final int cost;

  /// How many are held at least after each daily reset.
  final int daily;
}

/// Items just gained: redeemed ([daily] false) or the daily top-up.
class ItemGain {
  const ItemGain(this.items, {this.daily = false, this.cost = 0});

  /// What was gained and how many of each.
  final Map<ItemKind, int> items;
  final bool daily;

  /// Points spent on it (0 for the daily top-up).
  final int cost;
}

class ItemService extends ChangeNotifier {
  /// [earnedPoints] reads the points achievements have earned; [points]
  /// tells when they change.
  ItemService({required this.dataRoot, required this.earnedPoints, required this.points, DateTime Function()? clock}) : clock = clock ?? DateTime.now {
    points.addListener(notifyListeners);
  }

  /// The time now (a fixed one in tests).
  final DateTime Function() clock;

  /// The sing day of the last daily top-up.
  DateTime? refilledDay;
  Timer? _refillTimer;

  /// When the next daily top-up comes: 5:00 after the current sing day.
  DateTime get nextReset {
    final d = dayOf(clock());
    return DateTime(d.year, d.month, d.day + 1, kDayStartHour);
  }

  /// Tops the items up to their daily allowance once per sing day (more
  /// held than that is kept). Checked at start and every minute.
  Future<void> refillIfDue() async {
    final today = dayOf(clock());
    final last = refilledDay;
    if (last != null && !today.isAfter(last)) return;
    final got = <ItemKind, int>{};
    for (final k in ItemKind.values) {
      if (k.available && ownedOf(k) < k.daily) {
        got[k] = k.daily - ownedOf(k);
        owned[k] = k.daily;
      }
    }
    refilledDay = today;
    await _save();
    notifyListeners();
    if (got.isNotEmpty) _gained(ItemGain(got, daily: true));
  }

  /// With the points of [achievements].
  factory ItemService.of(String dataRoot, AchievementService achievements) =>
      ItemService(dataRoot: dataRoot, earnedPoints: () => achievements.points, points: achievements);

  final String dataRoot;
  final int Function() earnedPoints;
  final Listenable points;

  File get _file => File(p.join(dataRoot, 'items.json'));

  /// Points spent on items so far.
  int spent = 0;

  /// Items held, by kind.
  final Map<ItemKind, int> owned = {};

  /// Items used so far, by kind (for the profile).
  final Map<ItemKind, int> used = {};

  bool loaded = false;

  final _gains = StreamController<ItemGain>.broadcast();

  /// Items gained, each time (for the celebration).
  Stream<ItemGain> get gains => _gains.stream;
  final _missed = <ItemGain>[];

  /// Gains from before anyone listened (the top-up at start), once.
  List<ItemGain> takeMissed() {
    final out = List.of(_missed);
    _missed.clear();
    return out;
  }

  void _gained(ItemGain g) => _gains.hasListener ? _gains.add(g) : _missed.add(g);

  /// Points earned by achievements (never goes down).
  int get earned => earnedPoints();

  /// Points left to spend.
  int get balance => earned - spent;

  int ownedOf(ItemKind k) => owned[k] ?? 0;
  int usedOf(ItemKind k) => used[k] ?? 0;
  bool canRedeem(ItemKind k) => k.available && balance >= k.cost;

  Future<void> start() async {
    try {
      if (await _file.exists()) {
        final j = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
        spent = (j['spent'] as num?)?.toInt() ?? 0;
        refilledDay = DateTime.tryParse('${j['refilled_day']}');
        for (final k in ItemKind.values) {
          final o = (j['owned'] as Map?)?[k.name], u = (j['used'] as Map?)?[k.name];
          if (o is num && o > 0) owned[k] = o.toInt();
          if (u is num && u > 0) used[k] = u.toInt();
        }
      }
    } catch (_) {}
    loaded = true;
    await refillIfDue();
    _refillTimer = Timer.periodic(const Duration(minutes: 1), (_) => refillIfDue());
    notifyListeners();
  }

  /// Spends [ItemKind.cost] points for one [k]; false when there are not enough.
  Future<bool> redeem(ItemKind k) async {
    if (!canRedeem(k)) return false;
    spent += k.cost;
    owned[k] = ownedOf(k) + 1;
    await _save();
    notifyListeners();
    _gained(ItemGain({k: 1}, cost: k.cost));
    return true;
  }

  /// Spends the points for [n] of [k] at once (one celebration); false when
  /// there are not enough.
  Future<bool> redeemMany(ItemKind k, int n) async {
    if (n <= 0) return true;
    if (!k.available || balance < k.cost * n) return false;
    spent += k.cost * n;
    owned[k] = ownedOf(k) + n;
    await _save();
    notifyListeners();
    _gained(ItemGain({k: n}, cost: k.cost * n));
    return true;
  }

  /// Uses up [n] of [k]; false (and nothing used) when fewer are held.
  Future<bool> consumeMany(ItemKind k, int n) async {
    if (ownedOf(k) < n) return false;
    owned[k] = ownedOf(k) - n;
    used[k] = usedOf(k) + n;
    await _save();
    notifyListeners();
    return true;
  }

  /// Uses up one [k]; false when none is held.
  Future<bool> consume(ItemKind k) async {
    if (ownedOf(k) <= 0) return false;
    owned[k] = ownedOf(k) - 1;
    used[k] = usedOf(k) + 1;
    await _save();
    notifyListeners();
    return true;
  }

  /// Dev mode: the points to spend, set by what counts as spent (earned
  /// points stay as achievements give them).
  Future<void> setBalance(int points) async {
    spent = earned - points;
    await _save();
    notifyListeners();
  }

  /// Dev mode: undoes every trade: the points spent come back, nothing is
  /// counted as used, and the items held are what the day's top-up gives.
  Future<void> resetTrades() async {
    spent = 0;
    used.clear();
    owned.clear();
    for (final k in ItemKind.values) {
      if (k.available && k.daily > 0) owned[k] = k.daily;
    }
    await _save();
    notifyListeners();
  }

  /// Dev mode: how many [k] are held.
  Future<void> setOwned(ItemKind k, int n) async {
    owned[k] = n < 0 ? 0 : n;
    await _save();
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      await _file.parent.create(recursive: true);
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert({
        'spent': spent,
        if (refilledDay != null) 'refilled_day': '${refilledDay!.year.toString().padLeft(4, '0')}-${refilledDay!.month.toString().padLeft(2, '0')}-${refilledDay!.day.toString().padLeft(2, '0')}',
        'owned': {for (final e in owned.entries) e.key.name: e.value},
        'used': {for (final e in used.entries) e.key.name: e.value},
      }), flush: true);
      await tmp.rename(_file.path);
    } catch (_) {}
  }

  @override
  void dispose() {
    _refillTimer?.cancel();
    _gains.close();
    points.removeListener(notifyListeners);
    super.dispose();
  }
}
