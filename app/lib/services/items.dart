// Items bought with achievement points (items.json in the data folder, so
// they move with the data). Points are earned by achievements and never go
// down; what items cost is kept apart, so the balance is earned - spent.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'achievements.dart';

/// An item that can be redeemed for points.
enum ItemKind {
  /// Makes one note's pitch and timing perfect, then scores the take again.
  tuningWand(25),

  /// Cast before singing: the whole take is judged with pitch and timing
  /// twice as lenient.
  resonanceField(100);

  const ItemKind(this.cost);

  /// Points to redeem one.
  final int cost;
}

class ItemService extends ChangeNotifier {
  /// [earnedPoints] reads the points achievements have earned; [points]
  /// tells when they change.
  ItemService({required this.dataRoot, required this.earnedPoints, required this.points}) {
    points.addListener(notifyListeners);
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

  /// Points earned by achievements (never goes down).
  int get earned => earnedPoints();

  /// Points left to spend.
  int get balance => earned - spent;

  int ownedOf(ItemKind k) => owned[k] ?? 0;
  int usedOf(ItemKind k) => used[k] ?? 0;
  bool canRedeem(ItemKind k) => balance >= k.cost;

  Future<void> start() async {
    try {
      if (await _file.exists()) {
        final j = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
        spent = (j['spent'] as num?)?.toInt() ?? 0;
        for (final k in ItemKind.values) {
          final o = (j['owned'] as Map?)?[k.name], u = (j['used'] as Map?)?[k.name];
          if (o is num && o > 0) owned[k] = o.toInt();
          if (u is num && u > 0) used[k] = u.toInt();
        }
      }
    } catch (_) {}
    loaded = true;
    notifyListeners();
  }

  /// Spends [ItemKind.cost] points for one [k]; false when there are not enough.
  Future<bool> redeem(ItemKind k) async {
    if (!canRedeem(k)) return false;
    spent += k.cost;
    owned[k] = ownedOf(k) + 1;
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
        'owned': {for (final e in owned.entries) e.key.name: e.value},
        'used': {for (final e in used.entries) e.key.name: e.value},
      }), flush: true);
      await tmp.rename(_file.path);
    } catch (_) {}
  }

  @override
  void dispose() {
    points.removeListener(notifyListeners);
    super.dispose();
  }
}
