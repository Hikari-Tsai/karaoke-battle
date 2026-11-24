// The Tuning Wand on a take: the notes it was used on (wand.json in the take
// folder). Scoring takes those notes as sung perfectly (see
// ScoringOptions.perfectSpans); the score keeps the list ('wand') so a
// replay shows where it was used, and score.original.json keeps the score
// from before the first use, for the singer only (never exported).

import 'dart:convert';
import 'dart:math' as math;
import 'dart:io';

import 'package:path/path.dart' as p;

/// One use: the reference note (track seconds, MIDI) and when.
class WandUse {
  const WandUse({required this.onset, required this.offset, required this.pitch, required this.at});
  final double onset, offset, pitch;
  final DateTime at;

  Map<String, dynamic> toJson() => {'onset': onset, 'offset': offset, 'pitch': pitch, 'at': at.toIso8601String()};

  static WandUse? fromJson(Object? j) {
    if (j is! Map) return null;
    final on = j['onset'], off = j['offset'], pitch = j['pitch'];
    if (on is! num || off is! num || pitch is! num || off <= on) return null;
    return WandUse(onset: on.toDouble(), offset: off.toDouble(), pitch: pitch.toDouble(), at: DateTime.tryParse('${j['at']}') ?? DateTime(2000));
  }

  /// Whether this is the note at [onset] (times as saved, to the millisecond).
  bool isNote(double onset) => (this.onset - onset).abs() < 0.002;
}

/// The uses on one take.
class TakeWand {
  const TakeWand(this.uses);
  final List<WandUse> uses;

  static const fileName = 'wand.json';
  static const originalScoreName = 'score.original.json';

  static String pathIn(String takeDir) => p.join(takeDir, fileName);

  List<(double, double)> get spans => [for (final u in uses) (u.onset, u.offset)];

  bool hasNote(double onset) => uses.any((u) => u.isNote(onset));

  static List<WandUse> listFromJson(Object? j) => [for (final e in (j is List ? j : const [])) ?WandUse.fromJson(e)];

  static Future<TakeWand> load(String takeDir) async {
    try {
      final f = File(pathIn(takeDir));
      if (!await f.exists()) return const TakeWand([]);
      final j = jsonDecode(await f.readAsString());
      return TakeWand(listFromJson(j is Map ? j['notes'] : null));
    } catch (_) {
      return const TakeWand([]);
    }
  }

  Future<void> save(String takeDir) async {
    final f = File(pathIn(takeDir));
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode({'notes': [for (final u in uses) u.toJson()]}), flush: true);
    await tmp.rename(f.path);
  }
}

/// The wand uses a score carries (its 'wand' list), for replays.
List<WandUse> wandUsesOfScore(Map<String, dynamic>? raw) => TakeWand.listFromJson(raw?['wand']);

/// The Resonance Field on a take (field.json in the take folder): cast
/// before it was sung, the whole take is judged [lenience] times as
/// leniently. The score keeps it ('field') for the results and replays.
class TakeField {
  const TakeField._();

  static const fileName = 'field.json';
  static const lenience = 2.0;

  static String pathIn(String takeDir) => p.join(takeDir, fileName);

  static Future<bool> isOn(String takeDir) => File(pathIn(takeDir)).exists();

  static Future<void> mark(String takeDir, DateTime at) =>
      File(pathIn(takeDir)).writeAsString(jsonEncode({'lenience': lenience, 'at': at.toIso8601String()}));
}

/// Whether a score was judged under the Resonance Field.
bool fieldOfScore(Map<String, dynamic>? raw) => raw?['field'] is Map;

/// What each note is worth with the Tuning Wand on a take (wand_weights.json
/// in the take folder), so that tuning every note that can gain anything
/// makes exactly 100: [base] is the take scored without any wand, [raw] how
/// much a wand on each note alone adds to it (by onset in ms), and the
/// shares spread 100 − base over the notes in proportion to [raw]. With
/// wands the total is base + the shares of the notes tuned.
class WandWeights {
  const WandWeights({required this.key, required this.base, required this.raw});

  /// What the figures were worked out from (they are redone when it changes).
  final String key;
  final double base;
  final Map<int, double> raw;

  static const fileName = 'wand_weights.json';

  /// Bump when the scoring changes what a wand is worth.
  static const version = 1;

  static int onsetKey(double onset) => (onset * 1000).round();

  /// Below this a note gains nothing (shown "—", not pickable).
  static const minGain = 0.005;

  /// Each note's share of 100 − [base]: proportional to what it adds alone;
  /// all alike when none adds anything measurable.
  Map<int, double> get shares {
    final gap = math.max(0.0, 100 - base);
    if (gap <= 0 || raw.isEmpty) return {for (final k in raw.keys) k: 0.0};
    final positive = {for (final e in raw.entries) if (e.value > minGain) e.key: e.value};
    if (positive.isEmpty) return {for (final k in raw.keys) k: gap / raw.length};
    final sum = positive.values.fold<double>(0, (a, b) => a + b);
    return {for (final k in raw.keys) k: positive.containsKey(k) ? gap * positive[k]! / sum : 0.0};
  }

  /// The total with the wand on the notes starting at [onsets].
  double totalWith(Iterable<double> onsets) {
    final s = shares;
    final keys = {for (final o in onsets) onsetKey(o)};
    final sum = keys.fold<double>(0, (a, k) => a + (s[k] ?? 0));
    // Every note that can gain anything tuned: exactly 100.
    final open = [for (final e in s.entries) if (e.value > minGain && !keys.contains(e.key)) e.key];
    return open.isEmpty ? 100.0 : math.min(100.0, base + sum);
  }

  Map<String, dynamic> toJson() => {'key': key, 'base': base, 'raw': {for (final e in raw.entries) '${e.key}': e.value}};

  static Future<WandWeights?> load(String takeDir, String key) async {
    try {
      final f = File(p.join(takeDir, fileName));
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map || j['key'] != key) return null;
      final raw = <int, double>{};
      for (final e in (j['raw'] as Map? ?? const {}).entries) {
        final k = int.tryParse('${e.key}');
        if (k != null && e.value is num) raw[k] = (e.value as num).toDouble();
      }
      return WandWeights(key: key, base: (j['base'] as num).toDouble(), raw: raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(String takeDir) => File(p.join(takeDir, fileName)).writeAsString(jsonEncode(toJson()));
}
