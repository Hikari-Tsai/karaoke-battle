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

/// The score [take] would get with a Tuning Wand on each of the notes
/// [indices] (nothing is saved or used up).
Future<ScoreData> previewTuningWand({required AppServices services, required Song song, required TakeInfo take, required NoteList notes, required List<int> indices}) async {
  final octaveInvariant = (await ScoringBridge.load(take.scoreJson))?.raw['octave_invariant'] as bool? ?? services.settings.octaveInvariant;
  return SingSession.previewWand(services, services.library.files(song), take, octaveInvariant, [for (final i in indices) (notes.onset[i], notes.offset[i])]);
}

/// Uses a Tuning Wand on each of the notes [indices] of [notes] and scores
/// [take] again once (redeeming the wands missing first when [redeem] is
/// set). Returns the new score; throws [StateError] when there are not
/// enough wands, and leaves the take as it was on any failure.
Future<ScoreData> useTuningWand({
  required AppServices services,
  required Song song,
  required TakeInfo take,
  required NoteList notes,
  required List<int> indices,
  bool redeem = false,
}) async {
  const kind = ItemKind.tuningWand;
  final items = services.items;
  final files = services.library.files(song);
  final before = await TakeWand.load(take.dir);
  final todo = [for (final i in indices.toSet()) if (!before.hasNote(notes.onset[i])) i];
  if (todo.isEmpty) throw StateError('already perfect');
  final short = todo.length - items.ownedOf(kind);
  if (short > 0 && (!redeem || !await items.redeemMany(kind, short))) throw StateError('no wand');
  final original = File(p.join(take.dir, TakeWand.originalScoreName));
  final hadOriginal = await original.exists();
  if (!hadOriginal && await File(take.scoreJson).exists()) await File(take.scoreJson).copy(original.path);
  final now = DateTime.now();
  await TakeWand([
    ...before.uses,
    for (final i in todo) WandUse(onset: notes.onset[i], offset: notes.offset[i], pitch: notes.pitch[i], at: now),
  ]).save(take.dir);
  try {
    final octaveInvariant = (await ScoringBridge.load(take.scoreJson))?.raw['octave_invariant'] as bool? ?? services.settings.octaveInvariant;
    final score = await SingSession.scoreTake(services: services, files: files, take: take, octaveInvariant: octaveInvariant, reuseF0: true, keepGate: true);
    await items.consumeMany(kind, todo.length);
    return score;
  } catch (_) {
    // Put the take back as it was; the wands stay in the bag.
    await before.save(take.dir);
    if (!hadOriginal && await original.exists() && before.uses.isEmpty) await original.delete();
    rethrow;
  }
}

/// Takes the Tuning Wand off every note of [take] and scores it again as
/// sung (its field kept). The wands used are not given back.
Future<ScoreData> resetTuningWand({required AppServices services, required Song song, required TakeInfo take}) async {
  final before = await TakeWand.load(take.dir);
  await const TakeWand([]).save(take.dir);
  try {
    final octaveInvariant = (await ScoringBridge.load(take.scoreJson))?.raw['octave_invariant'] as bool? ?? services.settings.octaveInvariant;
    final score = await SingSession.scoreTake(services: services, files: services.library.files(song), take: take, octaveInvariant: octaveInvariant, reuseF0: true, keepGate: true);
    // No wand left: no score from before it to keep.
    final original = File(p.join(take.dir, TakeWand.originalScoreName));
    if (await original.exists()) await original.delete();
    final wand = File(TakeWand.pathIn(take.dir));
    if (await wand.exists()) await wand.delete();
    return score;
  } catch (_) {
    await before.save(take.dir);
    rethrow;
  }
}
