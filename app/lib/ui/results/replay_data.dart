// Everything a take's replay shows, loaded once: the replay screen plays it
// and the video export renders it, so both draw exactly the same picture.
import 'dart:convert';
import 'dart:io';

import '../../services/replay_mix.dart';
import '../../services/song_library.dart';
import '../../state/app_services.dart';
import '../../state/live_trace.dart';
import '../../state/lyrics.dart';
import '../../state/note_edits.dart';
import '../../state/scoring_bridge.dart';
import '../../state/sing_session.dart';
import '../../state/song_data.dart';
import '../../state/take_trace.dart';
import '../widgets/judgement_popups.dart';

class ReplayData {
  ReplayData({
    required this.notes,
    required this.refF0,
    required this.trace,
    required this.lyrics,
    required this.score,
    required this.judgements,
    required this.pitchShift,
    required this.stems,
    required this.takeSeconds,
  });

  final NoteList notes;
  final F0Curve refF0;
  final LiveTrace trace;
  final Lyrics? lyrics;
  final ScoreData? score;
  final List<JudgementMark> judgements;

  /// Key the take was sung in (semitones).
  final double pitchShift;

  /// Backing and voice on the track timeline.
  final ReplayStems stems;

  /// How long the take was recorded (from the track start); null if unknown.
  final double? takeSeconds;
}

/// Loads a take for replay. [notesJsonPath] overrides the notes (an
/// imported replay carries the sharer's).
Future<ReplayData> loadReplayData(AppServices services, Song song, TakeInfo take, {String? notesJsonPath}) async {
  final files = services.library.files(song);
  var track = 'inst';
  var pitchShift = 0.0;
  double? takeSeconds;
  try {
    final info = jsonDecode(await File(take.infoJson).readAsString()) as Map<String, dynamic>;
    pitchShift = (info['pitch_shift'] as num?)?.toDouble() ?? 0;
    track = info['track'] as String? ?? 'inst';
    takeSeconds = (info['duration'] as num?)?.toDouble();
  } catch (_) {}
  var backing = track == 'mix' ? files.mixWav : files.instWav;
  if (!await File(backing).exists()) backing = await File(files.instWav).exists() ? files.instWav : files.mixWav;
  final offset = await SingSession.takeTimeOffset(take);

  final notesPath = notesJsonPath ?? await take.notesFor(files.notesJson);
  final notes = await NoteList.load(notesPath);
  final refF0 = await F0Curve.load(files.refF0Json, confidenceThreshold: 0.5);
  try {
    final nj = jsonDecode(await File(notesPath).readAsString()) as Map<String, dynamic>;
    maskCurve(refF0, excludedSpansFromJson(nj));
  } catch (_) {}
  final score = await ScoringBridge.load(take.scoreJson);
  final takeF0 = await F0Curve.load(take.f0Json, confidenceThreshold: 0.4, timeOffset: offset);
  final trace = buildTakeTrace(notes, takeF0, shift: (score?.shift ?? 0).toDouble(), pitchShift: pitchShift);
  Lyrics? lyrics;
  try {
    final lf = File(files.lyricsJson);
    if (await lf.exists()) {
      final l = Lyrics.fromJson(jsonDecode(await lf.readAsString()) as Map<String, dynamic>);
      if (!l.isEmpty) lyrics = l;
    }
  } catch (_) {}
  // Judgement pop-ups at the notes' onsets: the onset's rhythm judgement
  // combined with the note's pitch (see JudgementMark.forNote).
  final judgements = <JudgementMark>[];
  final rj = score?.raw['rhythm'];
  if (rj is Map) {
    final errors = <int, double>{};
    final cents = <int, double>{};
    final nm = score?.raw['note_metrics'];
    if (nm is Map) {
      for (final e in (nm['per_note'] as List? ?? const [])) {
        if (e is! Map || e['index'] is! num) continue;
        final i = (e['index'] as num).toInt();
        if (e['onset_error_ms'] is num) errors[i] = (e['onset_error_ms'] as num).toDouble();
        if (e['cents_deviation'] is num) cents[i] = (e['cents_deviation'] as num).toDouble();
      }
    }
    for (final n in (rj['notes'] as List? ?? const [])) {
      final i = (n['index'] as num).toInt();
      if (i < 0 || i >= notes.length) continue;
      judgements.add(JudgementMark.forNote(
        time: notes.onset[i],
        midi: notes.pitch[i] + pitchShift,
        timing: n['onset'] as String,
        onsetErrorMs: errors[i],
        cents: cents[i],
      ));
    }
    judgements.sort((a, b) => a.time.compareTo(b.time));
  }

  final stems = await ensureReplayStems(
    services.sidecars,
    takeDir: take.dir,
    voiceWav: take.wav,
    backingWav: backing,
    offsetSeconds: offset,
    pitchShift: pitchShift,
  );
  return ReplayData(
    notes: notes,
    refF0: refF0,
    trace: trace,
    lyrics: lyrics,
    score: score,
    judgements: judgements,
    pitchShift: pitchShift,
    stems: stems,
    takeSeconds: takeSeconds,
  );
}
