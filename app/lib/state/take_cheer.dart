// 觀眾加油 on one take: the donations credited to it (cheer.json in the take
// folder) and their points, which are added to the take's score.json
// total (up to 100). The score as sung stays in score.json under 'cheer'
// ('base_total', 'base_rank'), so re-scoring the take (an item, a newer
// scoring) adds the same points again.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../scoring/models.dart' show rankForTotal, readScoreTotal, upgradeScoreJson;
import '../services/ecpay_alert.dart' show Donation;

class TakeCheer {
  const TakeCheer(this.items);
  final List<(Donation, double)> items;
  static const empty = TakeCheer([]);
  static const fileName = 'cheer.json';

  double get points => items.fold(0.0, (s, e) => s + e.$2);
  int get amount => items.fold(0, (s, e) => s + e.$1.amount);
  bool get isEmpty => items.isEmpty;

  static String pathIn(String takeDir) => p.join(takeDir, fileName);

  static Future<TakeCheer> load(String takeDir) async {
    try {
      final f = File(pathIn(takeDir));
      if (!await f.exists()) return empty;
      final j = jsonDecode(await f.readAsString());
      final list = j is Map ? j['donations'] : null;
      if (list is! List) return empty;
      return TakeCheer([
        for (final e in list)
          if (Donation.fromJson(e) case final d? when e is Map && e['points'] is num) (d, (e['points'] as num).toDouble()),
      ]);
    } catch (_) {
      return empty;
    }
  }

  /// Adds one donation to the take's cheer.json.
  static Future<TakeCheer> add(String takeDir, Donation d, double points) async {
    final now = await load(takeDir);
    final next = TakeCheer([...now.items, (d, points)]);
    final f = File(pathIn(takeDir));
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert({
      'donations': [
        for (final (d, pts) in next.items) {...d.toJson(), 'points': pts},
      ],
    }), flush: true);
    await tmp.rename(f.path);
    return next;
  }
}

/// The highest score there is; cheer does not go past it.
const double kMaxScore = 100;

/// [score] (a score.json map) with [points] of cheer on top of the score as
/// sung: total and rank raised (to at most 100), 'cheer' noting the score
/// before. Points of 0 give the score as sung.
Map<String, dynamic> withCheer(Map<String, dynamic> score, double points) {
  final j = Map<String, dynamic>.of(score);
  final prior = j['cheer'];
  double base;
  String baseRank;
  if (prior is Map && prior['base_total'] is num) {
    base = (prior['base_total'] as num).toDouble();
    baseRank = '${prior['base_rank'] ?? rankForTotal(base)}';
  } else {
    final upgraded = upgradeScoreJson(j);
    j
      ..clear()
      ..addAll(upgraded);
    final t = readScoreTotal(j);
    base = t.total;
    baseRank = t.rank;
  }
  if (points <= 0) {
    j.remove('cheer');
    j['total'] = base;
    j['rank'] = baseRank;
    return j;
  }
  final total = math.min(kMaxScore, ((base + points) * 100).round() / 100);
  j['total'] = total;
  j['rank'] = total == base ? baseRank : rankForTotal(total);
  j['cheer'] = {'points': points, 'base_total': base, 'base_rank': baseRank};
  return j;
}

/// Rewrites [takeDir]'s score.json with the take's cheer added. Returns the
/// total and rank before and after, or null when the take has no score.
Future<({double before, String beforeRank, double after, String afterRank})?> applyCheerToTake(String takeDir) async {
  final f = File(p.join(takeDir, 'score.json'));
  if (!await f.exists()) return null;
  final Map<String, dynamic> j;
  try {
    j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
  if (j['total'] is! num) return null;
  final before = readScoreTotal(j);
  final points = (await TakeCheer.load(takeDir)).points;
  final prior = j['cheer'];
  final next = withCheer(j, points);
  // Already in the score: nothing to write.
  if (prior is Map && prior['points'] == points && next['total'] == j['total']) {
    return (before: before.total, beforeRank: before.rank, after: before.total, afterRank: before.rank);
  }
  final tmp = File('${f.path}.tmp');
  await tmp.writeAsString(jsonEncode(next), flush: true);
  await tmp.rename(f.path);
  return (before: before.total, beforeRank: before.rank, after: (next['total'] as num).toDouble(), afterRank: '${next['rank']}');
}
