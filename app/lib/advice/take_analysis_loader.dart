// Reads everything [analyzeTake] needs for one of the user's takes from the
// song and take folders.
import 'dart:convert';
import 'dart:io';

import '../scoring/models.dart' show ReferenceNotes;
import '../services/song_library.dart';
import '../state/lyrics.dart';
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
  final score = await read(take.scoreJson);

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

  final history = <HistoryTake>[
    for (final t in await library.takes(song))
      if (t.id != take.id && t.total != null) HistoryTake(createdAt: t.createdAt, total: t.total!, subScores: t.subScores),
  ];

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
