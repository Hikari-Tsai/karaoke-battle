// Achievements: what the player has done, worked out from the scored takes
// (practice and unscored recordings do not count), the imported replays, the
// hot-songs genres and a few actions (exports). An achievement, or a tier of
// one, once reached is kept for good in achievements.json in the data folder
// (it moves with the data), even if the takes behind it are deleted later.
// Points add up from what is unlocked; they buy items (see items.dart).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show IconData, Icons;
import 'package:path/path.dart' as p;

import '../state/scoring_bridge.dart';
import '../state/shadow_battle.dart';
import '../state/song_data.dart';
import '../state/take_cheer.dart';
import 'ktv_charts.dart';
import 'replay_library.dart';
import 'settings.dart';
import 'sing_history.dart';
import 'song_library.dart';

enum AchievementCategory { basics, total, skill, ranks, progress, explore, battle, live, secret }

/// One achievement: a single goal ([thresholds] has one value, usually 1) or
/// tiers (bronze, silver, gold; two or three thresholds). [measure] gives the
/// current value from the facts. Names and descriptions are in i18n
/// (`ach.<id>.name` / `ach.<id>.desc`, with {n} for the next threshold).
class AchievementDef {
  const AchievementDef(this.id, this.category, this.icon, this.thresholds, this.measure, {this.hidden = false});
  final String id;
  final AchievementCategory category;
  final IconData icon;
  final List<num> thresholds;
  final double Function(AchievementFacts f) measure;

  /// Shown as "???" until unlocked.
  final bool hidden;

  bool get tiered => thresholds.length > 1;

  /// Tiers reached by [value] (0 to thresholds.length).
  int levelOf(double value) => thresholds.where((t) => value >= t).length;

  /// The unlock key of a tier (1-based): "takes.2", or the id when single.
  String key(int tier) => tiered ? '$id.$tier' : id;

  /// Points of a tier (1-based): its step in [achievementPoints] times
  /// [achievementPointScale].
  int pointsOf(int tier) => achievementPoints[id]![tier - 1] * achievementPointScale;
}

/// What one scored take tells about the player.
class TakeFact {
  const TakeFact({
    required this.songId,
    required this.language,
    required this.startedAt,
    required this.createdAt,
    required this.seconds,
    required this.total,
    required this.rank,
    this.subScores = const {},
    this.perfect = 0,
    this.judged = 0,
    this.misses = 0,
    this.highPitch,
    this.lowPitch,
    this.pitchShift = 0,
    this.songSeconds,
    this.battle,
  });

  /// Sung in a shadow battle: who against (their name, lower case, or the
  /// replay when they gave none) and their total.
  final ({String rival, double total})? battle;
  final String songId;
  final String language;

  /// Local time the take started (the sing day and the hour come from it).
  final DateTime startedAt;
  final DateTime createdAt;
  final double seconds;
  final double total;
  final String rank;
  final Map<String, double?> subScores;

  /// Onset judgements: PERFECT, all judged notes, MISS.
  final int perfect, judged, misses;

  /// A high pitch the take reached (MIDI, near the top of what was sung).
  final double? highPitch;

  /// A low pitch the take reached (MIDI, near the bottom of what was sung).
  final double? lowPitch;

  /// The key change it was sung in (semitones).
  final double pitchShift;

  /// The song's length, to tell a whole song from part of one.
  final double? songSeconds;
}

class AchievementFacts {
  const AchievementFacts({
    this.takes = const [],
    this.replays = const [],
    this.chartGenres = const {},
    this.events = const {},
    this.ownHigh,
    this.ownLow,
    this.songs = 0,
    this.readySongs = 0,
    this.lyricsSongs = 0,
    this.customLyricsSongs = 0,
    this.ownBackingSongs = 0,
    this.latencySet = false,
    this.named = false,
    this.unlocked = const {},
    this.live = const [],
    this.songYears = const {},
    this.artists = const {},
    this.importedReplays = 0,
    this.shares = 0,
    this.cheers = 0,
  });

  /// Viewers' donations received with 觀眾加油 on (kept even if the take
  /// they went to is deleted).
  final int cheers;

  /// The year each song came out: the hot songs charts' release year (the
  /// earliest their entries give), else YouTube's; songs with neither have
  /// none.
  final Map<String, int> songYears;

  /// Each library song's artist: the hot songs charts' when the song is on
  /// them, else the song's own (read from YouTube); songs with neither are
  /// left out.
  final Map<String, String> artists;

  /// Replays imported (any song).
  final int importedReplays;

  /// Videos and replays exported and score cards shared, all told.
  final int shares;

  /// When each take sung with a streaming app open was sung (kept even if
  /// the take is deleted).
  final List<DateTime> live;

  /// Songs in the library, those prepared, those with lyrics.
  final int songs, readySongs, lyricsSongs;

  /// Songs with lyrics the player made (a subtitle file, pasted text, an
  /// edit or typed in), and with a backing track the player imported.
  final int customLyricsSongs, ownBackingSongs;

  /// The latency has been measured; the player has a name.
  final bool latencySet, named;

  /// What was unlocked before (kept for good): finishing the beginner tasks
  /// counts the ones done earlier even if, say, the name was cleared since.
  final Set<String> unlocked;

  /// Every scored take, any order.
  final List<TakeFact> takes;

  /// Imported replays of songs in the library: the song, its score and when
  /// it came in.
  final List<({String songId, double total, DateTime importedAt})> replays;

  /// Songs found on the hot songs charts, with their genres (English names).
  final Map<String, Set<String>> chartGenres;

  /// Actions done at least once: 'share.video', 'share.replay', 'share.card',
  /// 'support.star' (the GitHub page opened from 「賞我星星」).
  final Set<String> events;

  /// The top of the player's range (MIDI), when measured.
  final int? ownHigh;

  /// The bottom of the player's range (MIDI), when measured.
  final int? ownLow;
}

int _rankValue(String r) => switch (r) { 'SSS' => 7, 'SS' => 6, 'S' => 5, 'A' => 4, 'B' => 3, 'C' => 2, _ => 1 };

List<List<TakeFact>> _bySong(AchievementFacts f) {
  final m = <String, List<TakeFact>>{};
  for (final t in f.takes) {
    (m[t.songId] ??= []).add(t);
  }
  for (final l in m.values) {
    l.sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }
  return m.values.toList();
}

Map<DateTime, List<TakeFact>> _byDay(AchievementFacts f) {
  final m = <DateTime, List<TakeFact>>{};
  for (final t in f.takes) {
    (m[dayOf(t.startedAt)] ??= []).add(t);
  }
  return m;
}

double _longestStreak(AchievementFacts f) {
  final days = _byDay(f).keys.toList()..sort();
  var best = 0, run = 0;
  DateTime? prev;
  for (final d in days) {
    run = prev != null && d.difference(prev).inHours.round() == 24 ? run + 1 : 1;
    best = math.max(best, run);
    prev = d;
  }
  return best.toDouble();
}

double _newBests(AchievementFacts f) {
  var n = 0;
  for (final takes in _bySong(f)) {
    var best = takes.first.total;
    for (final t in takes.skip(1)) {
      if (t.total > best) {
        n++;
        best = t.total;
      }
    }
  }
  return n.toDouble();
}

double _perfectSub(AchievementFacts f, String key) => f.takes.any((t) => (t.subScores[key] ?? 0).round() >= 100) ? 1 : 0;

double _event(AchievementFacts f, String name) => f.events.contains(name) ? 1 : 0;

/// The takes sung in a shadow battle, oldest first, with how each ended
/// (1 won, 0 draw, -1 lost; see [battleOutcome]).
List<({TakeFact take, int outcome})> _battles(AchievementFacts f) => [
      for (final t in f.takes.where((t) => t.battle != null).toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt)))
        (take: t, outcome: battleOutcome(t.total, t.battle!.total)),
    ];

double _longestWinRun(AchievementFacts f) {
  var best = 0, run = 0;
  for (final b in _battles(f)) {
    run = b.outcome == 1 ? run + 1 : 0;
    best = math.max(best, run);
  }
  return best.toDouble();
}

/// Lost to someone, then beat them in a later battle.
double _revenge(AchievementFacts f) {
  final lostTo = <String>{};
  for (final b in _battles(f)) {
    final rival = b.take.battle!.rival;
    if (b.outcome == 1 && lostTo.contains(rival)) return 1;
    if (b.outcome == -1) lostTo.add(rival);
  }
  return 0;
}

/// The beginner tasks: one feature each, done once.
final _basics = <AchievementDef>[
  // Getting started
  AchievementDef('firstSong', AchievementCategory.basics, Icons.add_circle_outline, [1], (f) => f.songs > 0 ? 1 : 0),
  AchievementDef('firstReady', AchievementCategory.basics, Icons.check_circle_outline, [1], (f) => f.readySongs > 0 ? 1 : 0),
  AchievementDef('firstPreview', AchievementCategory.basics, Icons.headphones, [1], (f) => _event(f, 'basics.preview')),
  AchievementDef('firstTake', AchievementCategory.basics, Icons.mic, [1], (f) => f.takes.isNotEmpty ? 1 : 0),
  AchievementDef('firstResults', AchievementCategory.basics, Icons.insights, [1], (f) => _event(f, 'basics.results')),
  AchievementDef('firstReplay', AchievementCategory.basics, Icons.replay, [1], (f) => _event(f, 'basics.replay')),
  // Setting up
  AchievementDef('calibrated', AchievementCategory.basics, Icons.av_timer, [1], (f) => f.latencySet ? 1 : 0),
  AchievementDef('rangeMeasured', AchievementCategory.basics, Icons.piano, [1], (f) => f.ownHigh != null ? 1 : 0),
  AchievementDef('named', AchievementCategory.basics, Icons.badge_outlined, [1], (f) => f.named ? 1 : 0),
  AchievementDef('lyrics', AchievementCategory.basics, Icons.subtitles_outlined, [1], (f) => f.lyricsSongs > 0 ? 1 : 0),
  AchievementDef('customLyrics', AchievementCategory.basics, Icons.edit_note, [1], (f) => f.customLyricsSongs > 0 ? 1 : 0),
  AchievementDef('ownBacking', AchievementCategory.basics, Icons.queue_music, [1], (f) => f.ownBackingSongs > 0 ? 1 : 0),
  // Basic skills
  AchievementDef('keyChange', AchievementCategory.basics, Icons.swap_vert, [1], (f) => f.takes.any((t) => t.pitchShift != 0) ? 1 : 0),
  AchievementDef('wholeSong', AchievementCategory.basics, Icons.done_all, [1], (f) => f.takes.any((t) => t.songSeconds != null && t.songSeconds! > 0 && t.seconds >= 0.9 * t.songSeconds!) ? 1 : 0),
  AchievementDef('deleteNote', AchievementCategory.basics, Icons.auto_fix_normal, [1], (f) => _event(f, 'basics.deleteNote')),
  // Exploring
  AchievementDef('browseCharts', AchievementCategory.basics, Icons.leaderboard_outlined, [1], (f) => _event(f, 'basics.charts')),
  AchievementDef('watchDemo', AchievementCategory.basics, Icons.ondemand_video, [1], (f) => _event(f, 'basics.demo')),
];

/// Every tier's points are its step below times this (so the steps stay
/// 10, 20, 50, 100, 200 as given).
const achievementPointScale = 2;

/// Points per tier, by how hard it is, on five steps: 5, 10, 25, 50, 100
/// (times [achievementPointScale]).
/// The beginner tasks are 5 (110 for all of them with graduating), a click
/// is 10, real skill 25 and up, and the long haul (gold tiers) 100.
const achievementPoints = <String, List<int>>{
  // Beginner tasks
  'firstSong': [5], 'firstReady': [5], 'firstPreview': [5], 'firstTake': [5], 'firstResults': [5],
  'firstReplay': [5], 'calibrated': [5], 'rangeMeasured': [5], 'named': [5], 'lyrics': [5],
  'keyChange': [5], 'wholeSong': [5], 'browseCharts': [5], 'watchDemo': [5],
  'customLyrics': [5], 'ownBacking': [5], 'deleteNote': [5],
  'graduate': [25],
  // Totals: the gold tiers take months
  'takes': [10, 25, 100], 'songs': [10, 25, 100], 'hours': [10, 25, 100], 'streak': [10, 25, 100],
  // Skill
  'sssSongs': [25, 50, 100],
  'fullPitch': [25], 'fullRhythm': [25], 'fullStability': [25], 'fullVibrato': [25], 'fullExpression': [25], 'fullLongTone': [25],
  'noMiss': [10, 25, 100], 'perfectRate': [25, 50, 100],
  // Ranks: a D is worth remembering, a C or B is on the way, then real skill
  'firstD': [10], 'firstC': [5], 'firstB': [5], 'firstA': [10],
  'rankS': [25], 'rankSS': [50], 'rankSSS': [100], 'allRanks': [25],
  // Progress
  'newBest': [10, 25, 100], 'bigLeap': [25], 'practice': [10, 25, 50],
  // Explore
  'languages': [10, 25, 50], 'genres': [10, 25, 50], 'chartSong': [10, 25, 50], 'decades': [10, 25, 50], 'artists': [10, 25, 50],
  'shareVideo': [10], 'shareReplay': [10], 'shareCard': [10], 'githubStar': [50], 'shares': [10, 25, 50], 'replaysIn': [10, 25, 50], 'challenger': [10, 25, 50],
  // Live: songs sung on stream and days streamed
  'firstLive': [25], 'liveSongs': [10, 25, 100], 'liveDays': [10, 25, 100], 'cheers': [10, 25, 100],
  // Shadow battles: a first battle is a click away, a long winning run is not
  'firstBattle': [10], 'battleWins': [10, 25, 100], 'rivals': [10, 25, 50], 'winStreak': [25, 50, 100], 'revenge': [25],
  // Secrets: worth more for being found; a time of day is easiest, twenty songs in a day hardest
  'nightOwl': [25], 'earlyBird': [25], 'warmup': [50], 'highNote': [50], 'lowNote': [50], 'marathon': [100], 'perfect100': [100], 'closeCall': [25],
};

/// How far past the measured range (semitones) the high and low notes go.
const rangeBeyond = 3;

/// Near the bottom and the top of what a take sang: the 2nd and 98th
/// percentiles of the confident pitch while a note of the song sounds and
/// within 4 semitones of it (keyed by [shift]), or of it an octave away (a
/// song sung an octave down or up). Hum, breath and noise between the notes
/// or far from them do not count, nor anything under C2 (65 Hz; mains hum is
/// 50 or 60 Hz); null below 100 such frames (1.6 s).
({double low, double high})? sungSpan(F0Curve f0, NoteList notes, double shift) {
  final v = <double>[];
  for (var i = 0; i < f0.times.length; i++) {
    final m = f0.midi[i];
    if (!m.isFinite || m < 36) continue;
    final n = notes.indexAt(f0.times[i]);
    if (n < 0) continue;
    final target = notes.pitch[n] + shift;
    if ([-12, 0, 12].any((o) => (m - target - o).abs() <= 4)) v.add(m);
  }
  if (v.length < 100) return null;
  v.sort();
  double at(double q) => v[(v.length * q).floor().clamp(0, v.length - 1)];
  return (low: at(0.02), high: at(0.98));
}

/// The first time of each rank, D to SSS: achievement id -> rank (the medal
/// shows the rank in its colour).
const rankAchievements = {'firstD': 'D', 'firstC': 'C', 'firstB': 'B', 'firstA': 'A', 'rankS': 'S', 'rankSS': 'SS', 'rankSSS': 'SSS'};

/// All achievements, in the order they are shown.
final achievements = <AchievementDef>[
  // --- 0. beginner tasks: the app's basics, once each ---
  ..._basics,
  AchievementDef('graduate', AchievementCategory.basics, Icons.school, [1], (f) {
    // Every task done, now or before.
    return _basics.every((a) => f.unlocked.contains(a.id) || a.measure(f) >= 1) ? 1 : 0;
  }),
  // --- A. totals: keep coming back ---
  AchievementDef('takes', AchievementCategory.total, Icons.mic, [10, 100, 500], (f) => f.takes.length.toDouble()),
  AchievementDef('songs', AchievementCategory.total, Icons.library_music, [5, 30, 100], (f) => f.takes.map((t) => t.songId).toSet().length.toDouble()),
  AchievementDef('hours', AchievementCategory.total, Icons.timer, [1, 10, 50], (f) => f.takes.fold<double>(0, (a, t) => a + t.seconds) / 3600),
  AchievementDef('streak', AchievementCategory.total, Icons.local_fire_department, [3, 7, 30], _longestStreak),
  // --- B. skill: scores and ranks ---
  AchievementDef('sssSongs', AchievementCategory.skill, Icons.workspace_premium, [3, 10, 20], (f) => f.takes.where((t) => t.rank == 'SSS').map((t) => t.songId).toSet().length.toDouble()),
  AchievementDef('fullPitch', AchievementCategory.skill, Icons.music_note, [1], (f) => _perfectSub(f, 'pitch')),
  AchievementDef('fullRhythm', AchievementCategory.skill, Icons.timer_outlined, [1], (f) => _perfectSub(f, 'rhythm')),
  AchievementDef('fullStability', AchievementCategory.skill, Icons.horizontal_rule, [1], (f) => _perfectSub(f, 'stability')),
  AchievementDef('fullVibrato', AchievementCategory.skill, Icons.waves, [1], (f) => _perfectSub(f, 'vibrato')),
  AchievementDef('fullExpression', AchievementCategory.skill, Icons.volume_up, [1], (f) => _perfectSub(f, 'expression')),
  AchievementDef('fullLongTone', AchievementCategory.skill, Icons.straighten, [1], (f) => _perfectSub(f, 'long_tone')),
  AchievementDef('noMiss', AchievementCategory.skill, Icons.verified, [1, 10, 50], (f) => f.takes.where((t) => t.judged > 0 && t.misses == 0).length.toDouble()),
  AchievementDef('perfectRate', AchievementCategory.skill, Icons.bolt, [1, 5, 10], (f) => f.takes.where((t) => t.judged > 0 && t.perfect / t.judged >= 0.8).length.toDouble()),
  // --- ranks: the first time of each rank, the bad ones too ---
  for (final e in rankAchievements.entries)
    AchievementDef(e.key, AchievementCategory.ranks, Icons.star, [1], (f) => f.takes.any((t) => t.rank == e.value) ? 1 : 0),
  AchievementDef('allRanks', AchievementCategory.ranks, Icons.collections_bookmark, [1], (f) {
    // Ranks reached before count even if their takes were deleted.
    final got = f.takes.map((t) => t.rank).toSet();
    return rankAchievements.entries.every((e) => got.contains(e.value) || f.unlocked.contains(e.key)) ? 1 : 0;
  }),
  // --- C. progress: getting better ---
  AchievementDef('newBest', AchievementCategory.progress, Icons.trending_up, [1, 10, 50], _newBests),
  AchievementDef('bigLeap', AchievementCategory.progress, Icons.rocket_launch, [1], (f) => _bySong(f).any((takes) => takes.skip(1).any((t) => t.total >= takes.first.total + 20)) ? 1 : 0),
  AchievementDef('practice', AchievementCategory.progress, Icons.fitness_center, [10, 20, 30], (f) => _bySong(f).fold<int>(0, (a, takes) => math.max(a, takes.length)).toDouble()),
  // --- D. explore: the app's corners ---
  AchievementDef('languages', AchievementCategory.explore, Icons.translate, [2, 3, 5], (f) => f.takes.map((t) => t.language).toSet().length.toDouble()),
  AchievementDef('genres', AchievementCategory.explore, Icons.category, [3, 5, 7], (f) {
    final sung = f.takes.map((t) => t.songId).toSet();
    return {for (final e in f.chartGenres.entries) if (sung.contains(e.key)) ...e.value}.length.toDouble();
  }),
  AchievementDef('chartSong', AchievementCategory.explore, Icons.leaderboard, [1, 10, 30], (f) => f.takes.map((t) => t.songId).where(f.chartGenres.containsKey).toSet().length.toDouble()),
  AchievementDef('decades', AchievementCategory.explore, Icons.history_edu, [2, 3, 5], (f) => {for (final t in f.takes) if (f.songYears[t.songId] case final y?) y ~/ 10}.length.toDouble()),
  AchievementDef('artists', AchievementCategory.explore, Icons.groups, [5, 20, 50], (f) => {for (final t in f.takes) if (f.artists[t.songId] case final a?) a.trim().toLowerCase()}.length.toDouble()),
  AchievementDef('shareVideo', AchievementCategory.explore, Icons.movie, [1], (f) => f.events.contains('share.video') ? 1 : 0),
  AchievementDef('shareReplay', AchievementCategory.explore, Icons.ios_share, [1], (f) => f.events.contains('share.replay') ? 1 : 0),
  AchievementDef('shareCard', AchievementCategory.explore, Icons.share, [1], (f) => f.events.contains('share.card') ? 1 : 0),
  // The app cannot see a star: opening the repo from 「賞我星星」 counts.
  AchievementDef('githubStar', AchievementCategory.explore, Icons.star, [1], (f) => _event(f, 'support.star')),
  AchievementDef('shares', AchievementCategory.explore, Icons.campaign, [5, 20, 50], (f) => f.shares.toDouble()),
  AchievementDef('replaysIn', AchievementCategory.explore, Icons.move_to_inbox, [1, 10, 30], (f) => f.importedReplays.toDouble()),
  // Imported replays beaten: a take of their song after the import, above it.
  AchievementDef('challenger', AchievementCategory.explore, Icons.sports_kabaddi, [1, 5, 20], (f) => f.replays.where((r) => f.takes.any((t) => t.songId == r.songId && t.createdAt.isAfter(r.importedAt) && t.total > r.total)).length.toDouble()),
  // --- live: singing on stream ---
  // --- shadow battles: singing against a friend's replay ---
  AchievementDef('firstBattle', AchievementCategory.battle, Icons.sports_kabaddi, [1], (f) => _battles(f).isNotEmpty ? 1 : 0),
  AchievementDef('battleWins', AchievementCategory.battle, Icons.emoji_events, [1, 10, 50], (f) => _battles(f).where((b) => b.outcome == 1).length.toDouble()),
  AchievementDef('rivals', AchievementCategory.battle, Icons.groups_2, [2, 5, 10], (f) => {for (final b in _battles(f)) if (b.outcome == 1) b.take.battle!.rival}.length.toDouble()),
  AchievementDef('winStreak', AchievementCategory.battle, Icons.whatshot, [3, 5, 10], _longestWinRun),
  AchievementDef('revenge', AchievementCategory.battle, Icons.replay_circle_filled, [1], _revenge),
  AchievementDef('firstLive', AchievementCategory.live, Icons.live_tv, [1], (f) => f.live.isNotEmpty ? 1 : _event(f, 'live.first')),
  AchievementDef('liveSongs', AchievementCategory.live, Icons.queue_music, [10, 100, 500], (f) => f.live.length.toDouble()),
  AchievementDef('liveDays', AchievementCategory.live, Icons.event_available, [3, 10, 30], (f) => f.live.map(dayOf).toSet().length.toDouble()),
  AchievementDef('cheers', AchievementCategory.live, Icons.volunteer_activism, [10, 50, 200], (f) => f.cheers.toDouble()),
  // --- E. secret: shown once found ---
  AchievementDef('nightOwl', AchievementCategory.secret, Icons.nightlight_round, [1], (f) => f.takes.any((t) => t.startedAt.hour < 5) ? 1 : 0, hidden: true),
  AchievementDef('marathon', AchievementCategory.secret, Icons.directions_run, [1], (f) => _byDay(f).values.any((d) => d.length >= 20) ? 1 : 0, hidden: true),
  // A total that shows as 100.0 (items count too).
  AchievementDef('closeCall', AchievementCategory.secret, Icons.balance, [1], (f) => _battles(f).any((b) => b.outcome == 1 && b.take.total - b.take.battle!.total < 0.5) ? 1 : 0, hidden: true),
  AchievementDef('perfect100', AchievementCategory.secret, Icons.diamond, [1], (f) => f.takes.any((t) => t.total >= 99.95) ? 1 : 0, hidden: true),
  // Three semitones past the measured range (the note reached, give or take
  // half a semitone); only once the range is measured.
  AchievementDef('highNote', AchievementCategory.secret, Icons.north, [1], (f) {
    final top = f.ownHigh;
    return top != null && f.takes.any((t) => (t.highPitch ?? 0) >= top + rangeBeyond - 0.5) ? 1 : 0;
  }, hidden: true),
  AchievementDef('lowNote', AchievementCategory.secret, Icons.south, [1], (f) {
    final bottom = f.ownLow;
    return bottom != null && f.takes.any((t) => t.lowPitch != null && t.lowPitch! <= bottom - rangeBeyond + 0.5) ? 1 : 0;
  }, hidden: true),
  AchievementDef('earlyBird', AchievementCategory.secret, Icons.flutter_dash, [1], (f) {
    // The day's first song started between 7:00 and 9:00.
    for (final day in _byDay(f).values) {
      final first = day.reduce((a, b) => a.startedAt.isBefore(b.startedAt) ? a : b);
      if (first.startedAt.hour >= 7 && first.startedAt.hour < 9) return 1;
    }
    return 0;
  }, hidden: true),
  AchievementDef('warmup', AchievementCategory.secret, Icons.wb_sunny, [1], (f) {
    for (final day in _byDay(f).values) {
      day.sort((a, b) => a.startedAt.compareTo(b.startedAt));
      if (_rankValue(day.first.rank) >= 5) return 1;
    }
    return 0;
  }, hidden: true),
];

/// Tiers reached per achievement id, from the facts.
Map<String, int> achievementLevels(AchievementFacts f) => {for (final a in achievements) a.id: a.levelOf(a.measure(f))};

/// A tier just unlocked, for the pop-up.
class AchievementUnlock {
  const AchievementUnlock(this.def, this.tier);
  final AchievementDef def;
  final int tier;
  int get points => def.pointsOf(tier);
}

/// Works the achievements out as takes, replays and settings change, keeps
/// what was unlocked and tells the UI about new unlocks.
class AchievementService extends ChangeNotifier {
  AchievementService({required this.library, required this.replays, required this.settings, required this.dataRoot, required this.cacheDir});
  final SongLibrary library;
  final ReplayLibrary replays;
  final AppSettings settings;
  final String dataRoot;
  final String cacheDir;

  File get _file => File(p.join(dataRoot, 'achievements.json'));

  /// The file's format. 2: the SSS songs tiers became 3 / 10 / 20 songs.
  /// 3: PERFECT rate and practice got a middle tier (their old silver is
  /// now gold), genres a gold.
  /// 4: hot songs, beating replays became tiers (the single goal is the
  /// bronze), genres 3 / 5 / 7, and shares are counted (from one per kind
  /// done before).
  static const _version = 4;

  static const _v4Moves = {
    'chartSong': ['chartSong.1'],
    'challenger': ['challenger.1'],
    'genres.1': ['genres.1', 'genres.2'],
    'genres.2': ['genres.1', 'genres.2', 'genres.3'],
    'genres.3': ['genres.1', 'genres.2', 'genres.3'],
  };

  /// Version 3: an old silver is the new gold, and the new silver below it
  /// was reached on the same day.
  static const _v3Moves = {'perfectRate.2': ['perfectRate.2', 'perfectRate.3'], 'practice.2': ['practice.2', 'practice.3']};

  /// Tiers taken back because what they ask for changed, with their dates:
  /// given back quietly (no celebration) if still reached.
  final Map<String, DateTime> _regrade = {};

  /// Unlock key -> when it was unlocked.
  final Map<String, DateTime> unlocked = {};

  /// Action -> when it was first done.
  final Map<String, DateTime> events = {};

  /// Running counts: 'shares' (videos and replays exported, cards shared).
  final Map<String, int> counts = {};

  /// "song id/take id" -> when it was sung with a streaming app open.
  final Map<String, DateTime> live = {};

  /// Current value per achievement id (for the progress bars).
  Map<String, double> values = {};

  bool loaded = false;
  final _unlocks = StreamController<List<AchievementUnlock>>.broadcast();

  /// New unlocks, a batch per evaluation (none on the very first run, when
  /// everything earned so far is recorded quietly).
  Stream<List<AchievementUnlock>> get unlocks => _unlocks.stream;

  /// What was unlocked on the very first run (for one summary message).
  int firstRunCount = 0;

  Timer? _debounce;
  bool _running = false, _again = false;
  String? _lastSettingsKey;

  int get points {
    var sum = 0;
    for (final a in achievements) {
      for (var t = 1; t <= a.thresholds.length; t++) {
        if (unlocked.containsKey(a.key(t))) sum += a.pointsOf(t);
      }
    }
    return sum;
  }

  /// Highest tier unlocked (stored, so it never goes down).
  int tierOf(AchievementDef a) {
    var tier = 0;
    for (var t = 1; t <= a.thresholds.length; t++) {
      if (unlocked.containsKey(a.key(t))) tier = t;
    }
    return tier;
  }

  Future<void> start() async {
    var fresh = true;
    try {
      if (await _file.exists()) {
        final j = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
        for (final e in (j['unlocked'] as Map? ?? const {}).entries) {
          final t = DateTime.tryParse('${e.value}');
          if (t != null) unlocked['${e.key}'] = t;
        }
        for (final e in (j['events'] as Map? ?? const {}).entries) {
          final t = DateTime.tryParse('${e.value}');
          if (t != null) events['${e.key}'] = t;
        }
        for (final e in (j['counts'] as Map? ?? const {}).entries) {
          if (e.value is num) counts['${e.key}'] = (e.value as num).toInt();
        }
        for (final e in (j['live'] as Map? ?? const {}).entries) {
          final t = DateTime.tryParse('${e.value}');
          if (t != null) live['${e.key}'] = t;
        }
        fresh = false;
        final version = (j['version'] as num?)?.toInt() ?? 1;
        if (version < 2) {
          for (final k in unlocked.keys.where((k) => k.startsWith('sssSongs.')).toList()) {
            _regrade[k] = unlocked.remove(k)!;
          }
        }
        if (version < 3) {
          for (final e in _v3Moves.entries) {
            final at = unlocked.remove(e.key);
            if (at == null) continue;
            for (final k in e.value) {
              unlocked.putIfAbsent(k, () => at);
            }
          }
        }
        if (version < 4) {
          final moved = <String, DateTime>{};
          for (final e in _v4Moves.entries) {
            final at = unlocked.remove(e.key);
            if (at == null) continue;
            for (final k in e.value) {
              if (moved[k] == null || at.isBefore(moved[k]!)) moved[k] = at;
            }
          }
          for (final e in moved.entries) {
            unlocked.putIfAbsent(e.key, () => e.value);
          }
          counts.putIfAbsent('shares', () => events.keys.where((k) => k.startsWith('share.')).length);
        }
        if (version < _version) await _save();
      }
    } catch (_) {}
    loaded = true;
    library.takesChanged.addListener(_schedule);
    library.addListener(_schedule);
    replays.addListener(_schedule);
    settings.addListener(_onSettings);
    _lastSettingsKey = '$_ownHigh|$_ownLow|${settings.latencySeconds != null}|${settings.playerName.isNotEmpty}';
    await evaluate(quiet: fresh);
  }

  @override
  void dispose() {
    library.takesChanged.removeListener(_schedule);
    library.removeListener(_schedule);
    replays.removeListener(_schedule);
    settings.removeListener(_onSettings);
    _debounce?.cancel();
    _unlocks.close();
    super.dispose();
  }

  int? get _ownHigh {
    final keys = settings.ownRangeKeys;
    return keys.isEmpty ? null : keys.reduce(math.max);
  }

  int? get _ownLow {
    final keys = settings.ownRangeKeys;
    return keys.isEmpty ? null : keys.reduce(math.min);
  }

  void _onSettings() {
    // Only the range, the latency and the name matter here.
    final key = '$_ownHigh|$_ownLow|${settings.latencySeconds != null}|${settings.playerName.isNotEmpty}';
    if (key == _lastSettingsKey) return;
    _lastSettingsKey = key;
    _schedule();
  }

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), evaluate);
  }

  /// An action done (an export or a share): kept with its first time.
  Future<void> recordEvent(String name) async {
    // Every share counts towards the share total, not just the first.
    final share = name.startsWith('share.');
    if (share) counts['shares'] = (counts['shares'] ?? 0) + 1;
    if (events.containsKey(name) && !share) return;
    events.putIfAbsent(name, DateTime.now);
    await _save();
    await evaluate();
  }

  /// A viewer's donation received with 觀眾加油 on.
  Future<void> recordCheer() async {
    counts['cheers'] = (counts['cheers'] ?? 0) + 1;
    await _save();
    await evaluate();
  }

  /// A scored take sung with a streaming app open (once per take).
  Future<void> recordLive(String takeId, {DateTime? at}) async {
    if (live.containsKey(takeId)) return;
    live[takeId] = at ?? DateTime.now();
    events.putIfAbsent('live.first', () => live[takeId]!);
    await _save();
    await evaluate();
  }

  /// Recomputes the values and unlocks what was newly reached.
  Future<void> evaluate({bool quiet = false}) async {
    if (_running) {
      _again = true;
      return;
    }
    _running = true;
    try {
      final facts = await collectFacts();
      values = {for (final a in achievements) a.id: a.measure(facts)};
      final now = DateTime.now();
      final fresh = <AchievementUnlock>[];
      var regraded = false;
      for (final a in achievements) {
        final level = a.levelOf(values[a.id]!);
        for (var t = 1; t <= level; t++) {
          final key = a.key(t);
          if (unlocked.containsKey(key)) continue;
          final before = _regrade.remove(key);
          if (before != null) {
            unlocked[key] = before;
            regraded = true;
            continue;
          }
          unlocked[key] = now;
          fresh.add(AchievementUnlock(a, t));
        }
      }
      _regrade.clear();
      if (regraded && fresh.isEmpty) await _save();
      if (fresh.isNotEmpty) {
        await _save();
        if (quiet) {
          firstRunCount = fresh.length;
        } else {
          _unlocks.add(fresh);
        }
      }
      notifyListeners();
    } catch (_) {
      // Never in the way of singing.
    } finally {
      _running = false;
      if (_again) {
        _again = false;
        unawaited(evaluate());
      }
    }
  }

  /// 開發模式: takes back every tier of [a]. Nothing is evaluated now, so it
  /// is unlocked (and celebrated) again the next time something is
  /// evaluated and still reaches it — after the next take, song, setting
  /// or action.
  Future<void> revoke(AchievementDef a) async {
    var changed = false;
    for (var t = 1; t <= a.thresholds.length; t++) {
      changed = unlocked.remove(a.key(t)) != null || changed;
    }
    if (!changed) return;
    await _save();
    notifyListeners();
  }

  Future<void> _save() async {
    try {
      await _file.parent.create(recursive: true);
      await _file.writeAsString(const JsonEncoder.withIndent('  ').convert({
        'version': _version,
        'unlocked': {for (final e in unlocked.entries) e.key: e.value.toIso8601String()},
        'events': {for (final e in events.entries) e.key: e.value.toIso8601String()},
        'live': {for (final e in live.entries) e.key: e.value.toIso8601String()},
        'counts': counts,
      }));
    } catch (_) {}
  }

  final Map<String, ({double low, double high})?> _spanCache = {};

  /// The facts from the library, replays, charts and settings.
  Future<AchievementFacts> collectFacts() async {
    final chart = await _chartFacts();
    final takes = <TakeFact>[];
    var cheersOnTakes = 0;
    for (final e in await loadSingHistory(library)) {
      final t = e.take;
      cheersOnTakes += (await TakeCheer.load(t.dir)).items.length;
      final score = await ScoringBridge.load(t.scoreJson);
      final counts = (score?.raw['rhythm'] is Map ? ((score!.raw['rhythm'] as Map)['counts'] as Map?) : null) ?? const {};
      int n(String k) => (counts[k] as num?)?.toInt() ?? 0;
      takes.add(TakeFact(
        songId: e.song.id,
        // The charts' language, else YouTube's, else the song's own setting.
        language: chart.languages[e.song.id] ?? e.song.ytLanguage ?? e.song.language,
        startedAt: e.startedAt.toLocal(),
        createdAt: t.createdAt,
        seconds: e.seconds ?? 0,
        total: t.total!,
        rank: t.rank ?? '',
        subScores: t.subScores,
        perfect: n('perfect'),
        judged: n('perfect') + n('great') + n('good') + n('miss'),
        misses: n('miss'),
        highPitch: (await _pitchSpan(t))?.high,
        lowPitch: (await _pitchSpan(t))?.low,
        pitchShift: await _pitchShift(t.infoJson),
        songSeconds: e.song.durationSec,
        battle: _battleFact(await BattleRecord.load(t.dir)),
      ));
    }
    var lyricsSongs = 0, customLyricsSongs = 0, ownBackingSongs = 0;
    for (final song in library.songs) {
      final files = library.files(song);
      final f = File(files.lyricsJson);
      // An empty lyrics.json ("no subtitles") is ~60 bytes.
      if (await f.exists() && await f.length() > 120) {
        lyricsSongs++;
        if (await _hasCustomLyrics(f)) customLyricsSongs++;
      }
      if (await File(files.userInstWav).exists()) ownBackingSongs++;
    }
    final replayFacts = <({String songId, double total, DateTime importedAt})>[];
    for (final r in replays.items) {
      final song = ReplayLibrary.findSong(library, r);
      if (song != null) replayFacts.add((songId: song.id, total: r.total, importedAt: r.importedAt));
    }
    return AchievementFacts(
      takes: takes,
      replays: replayFacts,
      chartGenres: chart.genres,
      events: events.keys.toSet(),
      ownHigh: _ownHigh,
      ownLow: _ownLow,
      songs: library.songs.length,
      readySongs: library.songs.where((s) => s.stage == PrepStage.done).length,
      lyricsSongs: lyricsSongs,
      customLyricsSongs: customLyricsSongs,
      ownBackingSongs: ownBackingSongs,
      latencySet: settings.latencySeconds != null,
      named: settings.playerName.isNotEmpty,
      unlocked: unlocked.keys.toSet(),
      live: live.values.toList(),
      songYears: {
        for (final s in library.songs)
          if (chart.years[s.id] ?? s.releaseYear case final y?) s.id: y,
      },
      artists: {
        for (final s in library.songs)
          if ((chart.artists[s.id] ?? s.artist).trim().isNotEmpty) s.id: chart.artists[s.id] ?? s.artist,
      },
      importedReplays: replays.items.length,
      shares: counts['shares'] ?? 0,
      // The count, or the donations on the takes when more (credited before
      // the count was kept).
      cheers: math.max(counts['cheers'] ?? 0, cheersOnTakes),
    );
  }

  static ({String rival, double total})? _battleFact(BattleRecord? b) {
    if (b == null) return null;
    final name = b.player.trim().toLowerCase();
    return (rival: name.isEmpty ? 'replay:${b.replayId}' : name, total: b.total);
  }

  Future<double> _pitchShift(String takeJson) async {
    try {
      final j = jsonDecode(await File(takeJson).readAsString()) as Map<String, dynamic>;
      return (j['pitch_shift'] as num?)?.toDouble() ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// The low and high of what the take sang on the song's notes (see
  /// [sungSpan]), with its notes, key change and timing.
  Future<({double low, double high})?> _pitchSpan(TakeInfo take) async {
    final key = take.f0Json;
    if (_spanCache.containsKey(key)) return _spanCache[key];
    ({double low, double high})? span;
    try {
      // Take-file time to song time, as the results screen does.
      var offset = 0.0;
      final side = File('${take.wav}.json');
      if (await side.exists()) {
        final j = jsonDecode(await side.readAsString()) as Map<String, dynamic>;
        offset = ((j['track_start_offset'] as num?)?.toDouble() ?? 0) - ((j['latency'] as num?)?.toDouble() ?? 0);
      }
      final f0 = await F0Curve.load(take.f0Json, confidenceThreshold: 0.6, timeOffset: offset);
      span = sungSpan(f0, await NoteList.load(take.notesJson), await _pitchShift(take.infoJson));
    } catch (_) {}
    return _spanCache[key] = span;
  }

  /// Library songs that are on the cached hot songs charts, with their
  /// genres: a song counts when a part of its title (see [titleParts]) is a
  /// chart title.
  /// The library songs found on the hot songs charts: their genres, release
  /// year and artist.
  Future<({Map<String, Set<String>> genres, Map<String, int> years, Map<String, String> artists, Map<String, String> languages})> _chartFacts() async {
    final entries = <ChartEntry>[];
    // A chart split by language (國語點播, 日語新歌…) gives its songs' language.
    final entryLanguage = <ChartEntry, String>{};
    for (final v in KtvVendor.values) {
      final f = File(p.join(cacheDir, 'ktv_charts', 'site-${v.name}.json'));
      try {
        if (!await f.exists()) continue;
        final charts = parseVendorCharts(v, await f.readAsString(), downloadedAt: DateTime.now());
        for (final c in charts.charts) {
          entries.addAll(c.entries);
          final lang = chartLanguage(c.board.title['en'] ?? '');
          if (lang != null) {
            for (final e in c.entries) {
              entryLanguage[e] = lang;
            }
          }
        }
      } catch (_) {}
    }
    final byTitle = <String, List<ChartEntry>>{};
    for (final e in entries) {
      final t = normaliseTitle(e.title);
      if (t.length >= 2) (byTitle[t] ??= []).add(e);
    }
    final out = <String, Set<String>>{};
    final years = <String, int>{};
    final artists = <String, String>{};
    final languages = <String, String>{};
    for (final song in library.songs) {
      for (final part in titleParts(song.title)) {
        for (final e in byTitle[part] ?? const <ChartEntry>[]) {
          (out[song.id] ??= {}).addAll([?e.genre, ...?e.tags['genre']]);
          if (e.artist.trim().isNotEmpty) artists.putIfAbsent(song.id, () => e.artist.trim());
          if (entryLanguage[e] case final lang?) languages.putIfAbsent(song.id, () => lang);
          final y = int.tryParse(RegExp(r'\d{4}').firstMatch(e.year ?? '')?.group(0) ?? '');
          if (y != null && y > 1900 && (years[song.id] == null || y < years[song.id]!)) years[song.id] = y;
        }
      }
    }
    return (genres: out, years: years, artists: artists, languages: languages);
  }
}

/// The language of a chart split by language, from its English name
/// ("Mandarin Requests", "Japanese New Songs"…); null for mixed charts.
String? chartLanguage(String englishTitle) {
  final t = englishTitle.toLowerCase();
  for (final (word, lang) in const [('mandarin', 'zh'), ('taiwanese', 'nan'), ('hokkien', 'nan'), ('cantonese', 'yue'), ('japanese', 'ja'), ('english', 'en'), ('korean', 'ko')]) {
    if (t.contains(word)) return lang;
  }
  return null;
}

/// The parts of a song's title, split at the brackets and separators video
/// titles use (【歌ってみた】食虫植物 / covered by …), each normalised; the
/// whole title too. A chart title has to be one of them, so a word inside a
/// longer title ("Vtuber" in a self-introduction) does not count.
Set<String> titleParts(String title) => {
      normaliseTitle(title),
      for (final part in title.split(RegExp(r'[【】\[\]()（）「」『』/／|｜_~～:：・\-–—]')))
        if (normaliseTitle(part).length >= 2) normaliseTitle(part),
    };

/// Lower case, without spaces and punctuation, to match titles loosely.
String normaliseTitle(String s) => s.toLowerCase().replaceAll(RegExp(r"[\s\p{P}\p{S}]", unicode: true), '');

/// Lyrics the player made, not YouTube's or Whisper's: a track imported from
/// a subtitle file, edited, typed in or pasted (see LyricSource).
const customLyricSources = {'imported', 'edited', 'manual', 'aligned'};

Future<bool> _hasCustomLyrics(File lyricsJson) async {
  try {
    final j = jsonDecode(await lyricsJson.readAsString());
    return hasCustomLyrics(j);
  } catch (_) {
    return false;
  }
}

/// Whether a decoded lyrics.json has a track from [customLyricSources].
bool hasCustomLyrics(Object? lyricsJson) =>
    lyricsJson is Map && (lyricsJson['tracks'] as List? ?? const []).any((t) => t is Map && customLyricSources.contains(t['source']));
