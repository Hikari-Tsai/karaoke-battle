// Shadow battle: singing a song against a friend's shared replay of it (an
// imported replay, see replay_library.dart). The friend's sung pitch line
// runs along the roll as a "shadow", moved into the key the user sings in,
// and while recording both sides get a running in-tune figure: of the notes
// already over, the share of each note's time sung inside the green band,
// averaged. That is an estimate for the race only; who wins is decided after
// the take by the real totals, kept with the take in battle.json.
//
// In a duet (the singer sings part A or B), the opponent sings the other
// part: their take is scored again on that part and the lines sung together
// only (the singer's own part's notes taken out, as for the singer), their
// line shows only there, and the race counts only those notes. Both sides
// are then judged on what they each sing.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../services/replay_library.dart';
import '../services/song_library.dart';
import 'beat_grid.dart';
import 'duet_parts.dart';
import 'lyrics.dart';
import 'live_trace.dart';
import 'scoring_bridge.dart';
import 'sing_session.dart';
import 'song_data.dart';
import 'take_trace.dart';
import 'tuning_wand.dart';

/// The imported replays of [song] that can be sung against: the sharer
/// accepted challenges and the pitch file is there; newest first.
List<ImportedReplay> battleOpponentsFor(ReplayLibrary replays, SongLibrary library, Song song) => [
      for (final r in replays.items)
        if (r.acceptsChallenge && ReplayLibrary.findSong(library, r)?.id == song.id && File(r.take.f0Json).existsSync()) r,
    ];

/// A friend's take loaded for a shadow battle.
class BattleOpponent {
  BattleOpponent({
    required this.replayId,
    required this.player,
    required this.total,
    required this.rank,
    required this.subScores,
    required this.notes,
    required this.trace,
    required this.pitchShift,
    this.part,
    this.sangPart,
    this.fullTotal,
  });

  final String replayId;

  /// In a duet: the part the opponent sings (and is scored on), and their
  /// total for the whole take.
  final DuetPart? part;
  final double? fullTotal;

  /// The part their take itself was sung as (a duet take), or null for the
  /// whole song: they can only be the opponent for that part.
  final DuetPart? sangPart;

  /// The sharer's name ('' when they left it empty).
  final String player;
  final double total;
  final String rank;
  final Map<String, double?> subScores;

  /// The notes their take was judged against.
  final NoteList notes;

  /// Their sung line, folded and coloured against [notes] in their key.
  final LiveTrace trace;

  /// The key they sang in (semitones): the shadow is drawn moved by the
  /// user's key minus this one, so it lies on the user's notes.
  final double pitchShift;

  static Future<BattleOpponent> load(ImportedReplay r) async {
    final take = r.take;
    final score = await ScoringBridge.load(take.scoreJson);
    var pitchShift = 0.0;
    try {
      final info = jsonDecode(await File(take.infoJson).readAsString()) as Map<String, dynamic>;
      pitchShift = (info['pitch_shift'] as num?)?.toDouble() ?? 0;
    } catch (_) {}
    DuetPart? sang;
    try {
      final info = jsonDecode(await File(take.infoJson).readAsString()) as Map<String, dynamic>;
      sang = DuetPart.values.where((p) => p != DuetPart.both && p.name == info['duet']).firstOrNull;
    } catch (_) {}
    final notes = await NoteList.load(r.notesJson);
    final offset = await SingSession.takeTimeOffset(take);
    final f0 = await F0Curve.load(take.f0Json, confidenceThreshold: 0.4, timeOffset: offset);
    final trace = buildTakeTrace(notes, f0, shift: (score?.shift ?? 0).toDouble(), pitchShift: pitchShift, lenience: lenienceOfScore(score?.raw));
    return BattleOpponent(
      replayId: r.id,
      player: r.player,
      total: score?.total ?? r.total,
      rank: score?.rank ?? r.rank,
      subScores: score?.subScores ?? const {},
      notes: notes,
      trace: trace,
      pitchShift: pitchShift,
      sangPart: sang,
    );
  }

  /// [r] as the opponent singing [part] of a duet split by [plan] over
  /// [lines] (the song's shown lyric lines): their take scored again on that
  /// part and the lines sung together (kept in the replay's folder, worked
  /// out once per split), their line only where they sing.
  static Future<BattleOpponent> loadPart(ImportedReplay r, {required SongFiles files, required DuetPlan plan, required List<LyricLine> lines, required DuetPart part, required bool calibratedTiming}) async {
    final full = await load(r);
    if (full.sangPart != null && full.sangPart != part) throw DuetPartMissing(full.sangPart!);
    final take = r.take;
    final rawScore = (await ScoringBridge.load(take.scoreJson))?.raw ?? const <String, dynamic>{};
    final songNotes = jsonDecode(await File(r.notesJson).readAsString()) as Map<String, dynamic>;
    final partNotes = duetNotesJson(songNotes, lines, plan, part);
    final dir = p.join(r.dir, 'duet_${part.name}');
    await Directory(dir).create(recursive: true);
    final notesPath = p.join(dir, 'notes.json');
    final scorePath = p.join(dir, 'score.json');
    final keyFile = File(p.join(dir, 'key.txt'));
    final key = jsonEncode([partNotes['notes'].length, [for (final l in lines) l.start], plan.parts.map((x) => x.name).join(), calibratedTiming, 2]);
    ScoreData? score;
    if (await keyFile.exists() && await keyFile.readAsString() == key) score = await ScoringBridge.load(scorePath);
    if (score == null) {
      await File(notesPath).writeAsString(jsonEncode(partNotes));
      // Judged as they sang it: under the Resonance Field when they did
      // (Tuning Wands on single notes do not carry over to a new split).
      if (fieldOfScore(rawScore)) await TakeField.mark(dir, take.createdAt);
      score = await ScoringBridge.scoreAndSave(
        notesJsonPath: notesPath,
        refF0JsonPath: files.refF0Json,
        takeF0JsonPath: take.f0Json,
        scoreJsonPath: scorePath,
        octaveInvariant: rawScore['octave_invariant'] == true,
        takeTimeOffset: await SingSession.takeTimeOffset(take),
        takeWavPath: await File(take.wav).exists() ? take.wav : null,
        referenceWavPath: await File(files.vocalsWav).exists() ? files.vocalsWav : null,
        noiseGateDb: (rawScore['noise_gate_db'] as num?)?.toDouble(),
        tempoBpm: (await TempoOverride.load(files.tempoJson)).bpm ?? (await DetectedBeats.load(files.beatsJson))?.bpm,
        calibratedTiming: calibratedTiming,
      );
      await keyFile.writeAsString(key);
    }
    // Their line only where they sing (their part and together).
    final spans = plan.spans(lines);
    bool sings(double t) {
      for (final s in spans) {
        if (s.start - 0.3 > t) break;
        if (t <= s.end + 0.3) return s.part.sungBy(part);
      }
      return true;
    }

    final trace = LiveTrace(full.trace.length + 1);
    for (var i = 0; i < full.trace.length; i++) {
      final t = full.trace.timeAt(i);
      if (sings(t)) trace.add(t, full.trace.midiAt(i), full.trace.displayAt(i), full.trace.centsAt(i), full.trace.categoryAt(i));
    }
    return BattleOpponent(
      replayId: r.id,
      player: r.player,
      total: score.total,
      rank: score.rank,
      subScores: score.subScores,
      notes: NoteList.fromJson(partNotes),
      trace: trace,
      pitchShift: full.pitchShift,
      part: part,
      sangPart: full.sangPart,
      fullTotal: full.total,
    );
  }

  /// Their in-tune figure, as the race shows it.
  late final RunningAccuracy race = RunningAccuracy(notes, trace);

  BattleRecord get record => BattleRecord(replayId: replayId, player: player, total: total, rank: rank, subScores: subScores, part: part);
}

/// The opponent's take was sung as one part of a duet ([sang]): they cannot
/// sing the other one.
class DuetPartMissing implements Exception {
  DuetPartMissing(this.sang);
  final DuetPart sang;
}

/// Share of the note from [on] to [off] sung inside the green band of
/// [trace]: each frame stands for the time to the next one (at most
/// [frameCap] seconds, so a gap in the voice does not count).
double inTuneShare(LiveTrace trace, double on, double off, {double frameCap = 0.05}) {
  final dur = off - on;
  if (dur <= 0 || trace.isEmpty) return 0;
  var good = 0.0;
  for (var i = trace.lowerBound(on); i < trace.length; i++) {
    final a = trace.timeAt(i);
    if (a >= off) break;
    if (trace.categoryAt(i) != PitchCategory.good) continue;
    final next = i + 1 < trace.length ? trace.timeAt(i + 1) : a + frameCap;
    final b = math.min(off, math.min(next, a + frameCap));
    if (b > a) good += b - a;
  }
  return (good / dur).clamp(0.0, 1.0);
}

/// The running in-tune figure of a take: the mean [inTuneShare] of the notes
/// that are over by a position. A note is worked out once, the first time
/// it is over, so this also follows a line that is still being sung (the
/// caller waits [settle] seconds past a note's end for its last frames).
class RunningAccuracy {
  RunningAccuracy(this.notes, this.trace);

  final NoteList notes;
  final LiveTrace trace;

  /// Cumulative sums of the worked-out notes' shares ([_sums][k] = sum of
  /// the first k).
  final List<double> _sums = [0];

  /// The figure (0..1) and how many notes it covers at [pos], with notes
  /// counted once they ended [settle] seconds before it; null before the
  /// first one.
  ({double share, int notes})? at(double pos, {double settle = 0}) {
    final limit = pos - settle;
    while (_sums.length - 1 < notes.length && notes.offset[_sums.length - 1] <= limit) {
      final k = _sums.length - 1;
      _sums.add(_sums.last + inTuneShare(trace, notes.onset[k], notes.offset[k]));
    }
    // After a jump back, count only the notes over by then.
    var n = _sums.length - 1;
    while (n > 0 && notes.offset[n - 1] > limit) {
      n--;
    }
    if (n == 0) return null;
    return (share: _sums[n] / n, notes: n);
  }
}

/// How a battle ended for the singer: 1 won, -1 lost, 0 a draw (the totals
/// equal to the 0.1 shown).
int battleOutcome(double mine, double theirs) => ((mine * 10).round() - (theirs * 10).round()).sign;

/// Who a take was sung against, kept in its folder (battle.json) so its
/// results show the battle later too.
class BattleRecord {
  const BattleRecord({required this.replayId, required this.player, required this.total, required this.rank, this.subScores = const {}, this.part});

  final String replayId;
  final String player;
  final double total;
  final String rank;
  final Map<String, double?> subScores;

  /// In a duet: the part the opponent sang and was scored on (the singer
  /// sang the other one); null for the whole song.
  final DuetPart? part;

  static String pathIn(String takeDir) => p.join(takeDir, 'battle.json');

  Map<String, dynamic> toJson() => {
        'replay_id': replayId,
        'player': player,
        'total': total,
        'rank': rank,
        'sub_scores': subScores,
        if (part != null) 'part': part!.name,
      };

  Future<void> save(String takeDir) => File(pathIn(takeDir)).writeAsString(jsonEncode(toJson()));

  static Future<BattleRecord?> load(String takeDir) async {
    try {
      final f = File(pathIn(takeDir));
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map || j['total'] is! num || j['replay_id'] is! String) return null;
      final subs = <String, double?>{};
      final sj = j['sub_scores'];
      if (sj is Map) {
        for (final e in sj.entries) {
          if (e.key is String) subs[e.key as String] = e.value is num ? (e.value as num).toDouble() : null;
        }
      }
      return BattleRecord(
        replayId: j['replay_id'] as String,
        player: j['player'] is String ? j['player'] as String : '',
        total: (j['total'] as num).toDouble(),
        rank: j['rank'] is String ? j['rank'] as String : '',
        subScores: subs,
        part: DuetPart.values.where((x) => x != DuetPart.both && x.name == j['part']).firstOrNull,
      );
    } catch (_) {
      return null;
    }
  }

  /// 1 when [mine] beats this, -1 when it loses, 0 for a draw (see
  /// [battleOutcome]).
  int outcome(double mine) => battleOutcome(mine, total);
}
