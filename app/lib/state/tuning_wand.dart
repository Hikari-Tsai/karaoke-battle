// The Tuning Wand on a take: the notes it was used on (wand.json in the take
// folder). Scoring takes those notes as sung perfectly (see
// ScoringOptions.perfectSpans); the score keeps the list ('wand') so a
// replay shows where it was used, and score.original.json keeps the score
// from before the first use, for the singer only (never exported).

import 'dart:convert';
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
