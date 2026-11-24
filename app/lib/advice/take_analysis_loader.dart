// Reads everything [analyzeTake] needs for one of the user's takes from the
// song and take folders. The scores are the takes as sung: items (the
// Tuning Wand, the Resonance Field) never reach the AI tips.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../scoring/models.dart' show ReferenceNotes, readScoreTotal;
import '../services/song_library.dart';
import '../state/lyrics.dart';
import '../state/scoring_bridge.dart' show ScoringBridge;
import '../state/tuning_wand.dart' show TakeWand;
import '../state/voice_range.dart';
import 'take_analysis.dart';

Future<TakeAnalysisInput> loadTakeAnalysisInput({
  required SongLibrary library,
  required Song song,
  required TakeInfo take,
  Set<int> ownRangeKeys = const {},
}) async {
  Future<Map<String, dynamic>> read(String path) async => jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
  final files = library.files(song);
  final notes = ReferenceNotes.fromJson(await read(await take.notesFor(files.notesJson))).notes;
  final score = await read(await rawScorePathOf(take));

  var lyrics = const <LyricLine>[];
  try {
    if (await File(files.lyricsJson).exists()) {
      lyrics = Lyrics.fromJson(await read(files.lyricsJson)).shifted().primaryTrack?.lines ?? const [];
    }
  } catch (_) {}

  var pitchShift = 0.0;
  try {
    pitchShift = ((await read(take.infoJson))['pitch_shift'] as num?)?.toDouble() ?? 0;
  } catch (_) {}

  final history = <HistoryTake>[];
  for (final t in await library.takes(song)) {
    if (t.id == take.id || t.total == null) continue;
    var total = t.total!, subScores = t.subScores;
    final path = await rawScorePathOf(t);
    if (path != t.scoreJson) {
      try {
        final j = await read(path);
        total = readScoreTotal(j).total;
        final flat = j['sub_scores_flat'];
        if (flat is Map) subScores = {for (final e in flat.entries) '${e.key}': (e.value as num?)?.toDouble()};
      } catch (_) {}
    }
    history.add(HistoryTake(createdAt: t.createdAt, total: total, subScores: subScores));
  }

  return TakeAnalysisInput(
    notes: notes,
    score: score,
    takeCreatedAt: take.createdAt,
    songTitle: song.title,
    artist: song.artist,
    lyrics: lyrics,
    pitchShift: pitchShift,
    ownRange: VoiceZone.ofReached(ownRangeKeys),
    history: history,
  );
}

/// The score of [take] as sung: scored without its items (score.raw.json),
/// else the one from before the Tuning Wand, else its score.
Future<String> rawScorePathOf(TakeInfo take) async {
  for (final path in [ScoringBridge.rawScorePath(take.scoreJson), p.join(take.dir, TakeWand.originalScoreName)]) {
    if (await File(path).exists()) return path;
  }
  return take.scoreJson;
}
