// Using the Tuning Wand on a note of a take: the note is recorded in the
// take's wand.json, the score from before the first use is kept for the
// singer (score.original.json, never exported), and the take is scored
// again with that note sung perfectly.

import 'dart:io';

import 'package:path/path.dart' as p;

import '../services/items.dart';
import '../services/song_library.dart';
import 'app_services.dart';
import 'scoring_bridge.dart';
import 'sing_session.dart';
import 'song_data.dart';
import 'tuning_wand.dart';

/// The score of [take] before the Tuning Wand was first used on it, or null.
Future<ScoreData?> originalScoreOf(TakeInfo take) => ScoringBridge.load(p.join(take.dir, TakeWand.originalScoreName));

/// Uses one Tuning Wand (redeeming one first when none is held and
/// [redeem] is set) on note [index] of [notes] and scores [take] again.
/// Returns the new score; throws [StateError] when there is no wand to use.
Future<ScoreData> useTuningWand({
  required AppServices services,
  required Song song,
  required TakeInfo take,
  required NoteList notes,
  required int index,
  bool redeem = false,
}) async {
  final items = services.items;
  if (items.ownedOf(ItemKind.tuningWand) <= 0) {
    if (!redeem || !await items.redeem(ItemKind.tuningWand)) throw StateError('no wand');
  }
  final files = services.library.files(song);
  final before = await TakeWand.load(take.dir);
  if (before.hasNote(notes.onset[index])) throw StateError('already perfect');
  final original = File(p.join(take.dir, TakeWand.originalScoreName));
  final hadOriginal = await original.exists();
  if (!hadOriginal && await File(take.scoreJson).exists()) await File(take.scoreJson).copy(original.path);
  final use = WandUse(onset: notes.onset[index], offset: notes.offset[index], pitch: notes.pitch[index], at: DateTime.now());
  await TakeWand([...before.uses, use]).save(take.dir);
  try {
    final octaveInvariant = (await ScoringBridge.load(take.scoreJson))?.raw['octave_invariant'] as bool? ?? services.settings.octaveInvariant;
    final score = await SingSession.scoreTake(services: services, files: files, take: take, octaveInvariant: octaveInvariant, reuseF0: true, keepGate: true);
    await items.consume(ItemKind.tuningWand);
    return score;
  } catch (_) {
    // Put the take back as it was; the wand stays in the bag.
    await before.save(take.dir);
    if (!hadOriginal && await original.exists() && before.uses.isEmpty) await original.delete();
    rethrow;
  }
}
