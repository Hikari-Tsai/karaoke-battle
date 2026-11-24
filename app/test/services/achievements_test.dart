import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/achievements.dart';
import 'package:karaoke_battle/services/app_paths.dart';
import 'package:karaoke_battle/services/replay_library.dart';
import 'package:karaoke_battle/services/settings.dart';
import 'package:karaoke_battle/services/sidecars.dart';
import 'package:karaoke_battle/services/song_library.dart';
import 'package:karaoke_battle/state/i18n.dart';
import 'package:karaoke_battle/state/song_data.dart';
import 'package:karaoke_battle/ui/profile/achievements_view.dart' show achievementNote;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

TakeFact take(String song, String at, double total, {String rank = 'A', String lang = 'zh', double seconds = 200, int perfect = 0, int judged = 0, int misses = 0, double? high, double? low, Map<String, double?> subs = const {}}) {
  final t = DateTime.parse(at);
  return TakeFact(songId: song, language: lang, startedAt: t, createdAt: t, seconds: seconds, total: total, rank: rank, perfect: perfect, judged: judged, misses: misses, highPitch: high, lowPitch: low, subScores: subs);
}

int level(String id, AchievementFacts f) => achievementLevels(f)[id]!;

void main() {
  tearDown(() => I18n.notifier.value = 'zh');

  test('every achievement has a name and a description in all three languages', () {
    for (final lang in I18n.supported) {
      I18n.notifier.value = lang;
      for (final a in achievements) {
        for (final k in ['ach.${a.id}.name', 'ach.${a.id}.desc']) {
          final s = tr(k, {'n': 3});
          expect(s, isNot(k), reason: '$k missing in $lang');
          expect(s, isNot(contains('{')), reason: '$k has unreplaced args in $lang');
        }
      }
      for (final c in AchievementCategory.values) {
        expect(tr('ach.cat.${c.name}'), isNot('ach.cat.${c.name}'));
      }
    }
  });

  test('notes on how a rule is judged: in all three languages, where needed', () {
    AchievementDef d(String id) => achievements.firstWhere((a) => a.id == id);
    for (final id in ['streak', 'decades', 'genres', 'firstLive', 'liveSongs', 'liveDays', 'firstD', 'rankSSS', 'fullPitch', 'highNote', 'lowNote', 'challenger']) {
      expect(achievementNote(d(id)), isNotNull, reason: id);
    }
    expect(achievementNote(d('firstSong')), isNull, reason: 'its description says it all');
    expect(achievementNote(d('firstD')), achievementNote(d('rankSS')), reason: 'the ranks share one note');
    for (final lang in I18n.supported) {
      I18n.notifier.value = lang;
      for (final a in achievements) {
        final n = achievementNote(a);
        if (n == null) continue;
        expect(n.trim(), isNotEmpty, reason: '${a.id} in $lang');
        expect(n, isNot(contains('{')), reason: '${a.id} in $lang');
      }
    }
    I18n.notifier.value = 'en';
    expect(achievementNote(d('decades')), contains('hot songs charts'));
  });

  test('every rank, counting ones reached before whose takes are gone', () {
    final f = AchievementFacts(takes: [take('a', '2026-11-10T20:00:00', 99, rank: 'SSS')], unlocked: {'firstD', 'firstC', 'firstB', 'firstA', 'rankS', 'rankSS'});
    expect(level('allRanks', f), 1);
  });

  test('totals: takes, songs, hours and the longest streak of sing days', () {
    final f = AchievementFacts(takes: [
      for (var i = 0; i < 12; i++) take('s${i % 6}', '2026-11-${10 + (i % 4)}T20:00:00', 80, seconds: 400),
    ]);
    expect(level('takes', f), 1, reason: '12 takes: bronze (10)');
    expect(level('songs', f), 1, reason: '6 songs: bronze (5)');
    expect(level('hours', f), 1, reason: '12 x 400 s = 1.3 h');
    expect(level('streak', f), 1, reason: 'four days in a row: bronze (3)');
    final gap = AchievementFacts(takes: [take('a', '2026-11-10T20:00:00', 80), take('a', '2026-11-12T20:00:00', 80), take('a', '2026-11-13T20:00:00', 80)]);
    expect(level('streak', gap), 0, reason: 'two days in a row only');
    // A take at 2 a.m. still belongs to the night before.
    final late = AchievementFacts(takes: [take('a', '2026-11-10T20:00:00', 80), take('a', '2026-11-11T02:00:00', 80), take('a', '2026-11-12T20:00:00', 80)]);
    expect(level('streak', late), 0, reason: 'the 2 a.m. take is still the 10th');
  });

  test('skill: ranks, SSS songs, full sub-scores, no miss and PERFECT rate', () {
    final f = AchievementFacts(takes: [
      take('a', '2026-11-10T20:00:00', 96, rank: 'SS', perfect: 40, judged: 50, misses: 0, subs: {'pitch': 100, 'rhythm': 92}),
      take('b', '2026-11-10T21:00:00', 99, rank: 'SSS', perfect: 30, judged: 50, misses: 2),
    ]);
    expect(level('rankS', f), 0, reason: 'each rank counts on its own: no take is an S');
    expect(level('rankSS', f), 1);
    expect(level('rankSSS', f), 1);
    expect(level('sssSongs', f), 0, reason: 'one SSS song; the bronze asks for three'); 
    expect(level('fullPitch', f), 1);
    expect(level('fullRhythm', f), 0);
    expect(level('fullVibrato', f), 0, reason: 'no vibrato score on these songs');
    expect(level('fullVibrato', AchievementFacts(takes: [take('c', '2026-11-11T20:00:00', 90, subs: {'vibrato': 99.6})])), 1, reason: 'rounds to 100');
    expect(level('noMiss', f), 1, reason: 'the first take has no MISS');
    expect(level('perfectRate', f), 1, reason: '40 of 50 PERFECT is 80%');
  });

  test('ranks: the first time of each rank, D included, then all seven', () {
    final some = AchievementFacts(takes: [take('a', '2026-11-10T20:00:00', 60, rank: 'D'), take('a', '2026-11-10T21:00:00', 88, rank: 'A')]);
    expect(level('firstD', some), 1);
    expect(level('firstA', some), 1);
    expect(level('firstC', some), 0);
    expect(level('allRanks', some), 0);
    final all = AchievementFacts(takes: [
      for (final (i, r) in ['D', 'C', 'B', 'A', 'S', 'SS', 'SSS'].indexed) take('a', '2026-11-1${i}T20:00:00', 60.0 + 5 * i, rank: r),
    ]);
    for (final id in rankAchievements.keys) {
      expect(level(id, all), 1, reason: id);
    }
    expect(level('allRanks', all), 1);
  });

  test('progress: new bests, a 20-point leap and practice on one song', () {
    final f = AchievementFacts(takes: [
      take('a', '2026-11-10T20:00:00', 60),
      take('a', '2026-11-10T20:10:00', 70), // new best
      take('a', '2026-11-10T20:20:00', 65),
      take('a', '2026-11-10T20:30:00', 82), // new best, 22 above the first
      for (var i = 0; i < 6; i++) take('a', '2026-11-11T20:0$i:00', 50),
    ]);
    expect(achievements.firstWhere((a) => a.id == 'newBest').measure(f), 2);
    expect(level('bigLeap', f), 1);
    expect(level('practice', f), 1, reason: '10 takes of one song');
  });

  test('beginner: custom lyrics, own backing, deleting a note', () {
    expect(level('customLyrics', const AchievementFacts()), 0);
    expect(level('customLyrics', const AchievementFacts(customLyricsSongs: 1)), 1);
    expect(level('ownBacking', const AchievementFacts(ownBackingSongs: 1)), 1);
    expect(level('deleteNote', const AchievementFacts(events: {'basics.deleteNote'})), 1);
    expect(hasCustomLyrics({'tracks': [{'lang': 'ja', 'lines': []}]}), isFalse, reason: 'YouTube subtitles');
    expect(hasCustomLyrics({'tracks': [{'lang': 'ja', 'source': 'whisper'}]}), isFalse);
    for (final s in ['imported', 'edited', 'manual', 'aligned']) {
      expect(hasCustomLyrics({'tracks': [{'lang': 'ja'}, {'lang': 'ja-x-$s', 'source': s}]}), isTrue, reason: s);
    }
    expect(hasCustomLyrics(null), isFalse);
  });

  test('explore: languages, chart genres, shares and beating a replay', () {
    final f = AchievementFacts(
      takes: [take('a', '2026-11-10T20:00:00', 90, lang: 'zh'), take('b', '2026-11-12T20:00:00', 88, lang: 'ja')],
      chartGenres: {
        'a': {'Mandopop', 'Ballad', 'Pop'},
        'b': {'J-Pop', 'Rock'},
        'not sung': {'Jazz'},
      },
      replays: [(songId: 'b', total: 85, importedAt: DateTime.parse('2026-11-11T00:00:00'))],
      events: {'share.card'},
    );
    expect(level('languages', f), 1);
    expect(level('genres', f), 2, reason: 'five genres among the songs sung: silver (5)');
    expect(level('chartSong', f), 1);
    expect(level('shareCard', f), 1);
    expect(level('shareVideo', f), 0);
    expect(level('githubStar', f), 0);
    expect(level('githubStar', AchievementFacts(events: {'support.star'})), 1, reason: 'the GitHub page opened from 「賞我星星」');
    expect(level('challenger', f), 1, reason: '88 after importing an 85');
    final explore = AchievementFacts(
      takes: [for (final (i, s) in ['a', 'b', 'c', 'd', 'e', 'f'].indexed) take(s, '2026-11-1${i}T20:00:00', 80)],
      songYears: {'a': 1985, 'b': 1999, 'c': 2004, 'not sung': 1975},
      artists: {'a': '周杰倫', 'b': '周杰倫 ', 'c': 'YOASOBI', 'd': 'yoasobi', 'e': 'Ado'},
      importedReplays: 12,
      shares: 21,
    );
    expect(achievements.firstWhere((a) => a.id == 'decades').measure(explore), 3, reason: 'the 80s, 90s and 2000s; songs with no year are left out');
    expect(achievements.firstWhere((a) => a.id == 'artists').measure(explore), 3, reason: 'the same artist however it is spaced or cased');
    expect(level('replaysIn', explore), 2);
    expect(level('shares', explore), 2);
    final before = AchievementFacts(takes: [take('b', '2026-11-10T20:00:00', 88)], replays: [(songId: 'b', total: 85, importedAt: DateTime.parse('2026-11-11T00:00:00'))]);
    expect(level('challenger', before), 0, reason: 'only takes after the import count');
  });

  test('secrets: night owl, marathon, high and low notes and the first song of the day', () {
    final f = AchievementFacts(takes: [
      take('a', '2026-11-11T01:30:00', 70),
      for (var i = 0; i < 20; i++) take('b', DateTime(2026, 11, 12, 10).add(Duration(minutes: 10 * i)).toIso8601String(), 70),
      take('c', '2026-11-13T19:00:00', 92, rank: 'S', high: 74.6, low: 45.4),
    ]);
    expect(level('nightOwl', f), 1);
    expect(level('marathon', f), 1);
    expect(level('highNote', f), 0, reason: 'the range is not measured');
    expect(level('lowNote', f), 0, reason: 'the range is not measured');
    // Range A2..C5 (45..72): 3 keys past it is D#5 (75) and F#2 (42).
    final measured = AchievementFacts(takes: f.takes, ownHigh: 72, ownLow: 45);
    expect(level('highNote', measured), 1, reason: '74.6 rounds to D#5, 3 keys above C5');
    expect(level('lowNote', measured), 0, reason: 'A2 is the bottom of the range, not below it');
    expect(level('highNote', AchievementFacts(takes: f.takes, ownHigh: 73, ownLow: 45)), 0, reason: 'only 2 keys above C#5');
    expect(level('lowNote', AchievementFacts(takes: [take('d', '2026-11-13T20:00:00', 80, low: 42.4)], ownHigh: 72, ownLow: 45)), 1, reason: 'F#2, 3 keys below A2');
    expect(level('warmup', f), 1, reason: 'the 13th starts with an S');
    expect(level('earlyBird', f), 0, reason: 'no day starts between 7 and 9');
    final early = AchievementFacts(takes: [take('a', '2026-11-14T07:30:00', 70), take('a', '2026-11-14T10:00:00', 80)]);
    expect(level('earlyBird', early), 1);
    final late = AchievementFacts(takes: [take('a', '2026-11-14T06:40:00', 70), take('a', '2026-11-14T07:30:00', 80)]);
    expect(level('earlyBird', late), 0, reason: 'the day\'s first song was before 7');
  });

  test('beginner tasks: library, settings, takes and actions, then graduate', () {
    final none = AchievementFacts(takes: const []);
    for (final id in ['firstSong', 'firstTake', 'calibrated', 'keyChange', 'wholeSong', 'browseCharts', 'graduate']) {
      expect(level(id, none), 0, reason: id);
    }
    final t = TakeFact(songId: 'a', language: 'zh', startedAt: DateTime(2026, 11, 10, 20), createdAt: DateTime(2026, 11, 10, 20), seconds: 190, total: 75, rank: 'B', perfect: 0, judged: 0, misses: 0, highPitch: null, subScores: const {}, pitchShift: -2, songSeconds: 200);
    final f = AchievementFacts(takes: [t], songs: 1, readySongs: 1, lyricsSongs: 1, customLyricsSongs: 1, ownBackingSongs: 1, latencySet: true, named: true, ownHigh: 72, events: {'basics.preview', 'basics.results', 'basics.replay', 'basics.charts', 'basics.demo', 'basics.deleteNote'});
    for (final a in achievements.where((a) => a.category == AchievementCategory.basics)) {
      expect(achievementLevels(f)[a.id], 1, reason: a.id);
    }
    expect(achievements.firstWhere((a) => a.id == 'graduate').pointsOf(1), 25);
    expect(achievements.firstWhere((a) => a.id == 'firstSong').pointsOf(1), 5);
    // A task done before still counts towards graduating.
    final later = AchievementFacts(takes: [t], songs: 1, readySongs: 1, lyricsSongs: 1, customLyricsSongs: 1, ownBackingSongs: 1, latencySet: true, named: true, ownHigh: 72, events: {'basics.preview', 'basics.results', 'basics.replay', 'basics.charts', 'basics.deleteNote'}, unlocked: {'watchDemo'});
    expect(level('graduate', later), 1);
    final short = TakeFact(songId: 'a', language: 'zh', startedAt: t.startedAt, createdAt: t.createdAt, seconds: 120, total: 60, rank: 'C', perfect: 0, judged: 0, misses: 0, highPitch: null, subScores: const {}, songSeconds: 200);
    expect(level('wholeSong', AchievementFacts(takes: [short])), 0, reason: '60% of the song');
    expect(level('keyChange', AchievementFacts(takes: [short])), 0);
  });

  test('live: the first stream, songs sung on stream and days streamed', () {
    expect(level('firstLive', AchievementFacts()), 0);
    final f = AchievementFacts(live: [
      for (var i = 0; i < 12; i++) DateTime(2026, 11, 10 + i % 3, 21, i),
      DateTime(2026, 11, 14, 2), // 2 a.m.: still the 13th's stream
    ]);
    expect(level('firstLive', f), 1);
    expect(level('liveSongs', f), 1, reason: '13 songs on stream: bronze (10)');
    expect(level('liveDays', f), 1, reason: 'four days: the 10th to 12th, and the 13th for the 2 a.m. song');
    expect(achievements.firstWhere((a) => a.id == 'liveDays').measure(f), 4);
  });

  test('a chart split by language gives its songs\' language', () {
    expect(chartLanguage('Mandarin Requests'), 'zh');
    expect(chartLanguage('Taiwanese New Songs'), 'nan');
    expect(chartLanguage('Cantonese Requests'), 'yue');
    expect(chartLanguage('Japanese Requests'), 'ja');
    expect(chartLanguage('Weekly Top 100'), isNull);
  });

  test('chart titles match a whole part of a song title, not a word inside it', () {
    expect(titleParts('【歌ってみた】食虫植物 / covered by 多帕 Topa'), contains('食虫植物'));
    expect(titleParts('【歌回剪輯】從前說 / 小阿七｜covered by 多帕'), contains('從前說'));
    expect(titleParts('食虫植物_短'), contains('食虫植物'));
    expect(titleParts('晴天'), contains('晴天'));
    expect(titleParts('【自己紹介】Vtuber一問一答自己紹介【多帕/臺灣Vtuber】(中文ver.)'), isNot(contains('vtuber')));
  });

  test('the sung span only counts pitch on the song\'s notes, near them', () {
    // Notes at A2 (45) for 0..2 s and C4 (60) for 2..4 s; 10 ms frames.
    final notes = NoteList(Float64List.fromList([0, 2]), Float64List.fromList([2, 4]), Float64List.fromList([45, 60]));
    F0Curve curve(double Function(double t) midi, {double to = 5}) {
      final n = (to / 0.01).round();
      final times = Float64List.fromList([for (var i = 0; i < n; i++) i * 0.01]);
      return F0Curve(times, Float64List.fromList([for (final t in times) midi(t)]), Float64List(n));
    }
    final sung = sungSpan(curve((t) => t < 2 ? 43 : 61), notes, 0)!;
    expect(sung.low, 43);
    expect(sung.high, 61);
    // Mains hum at A#1 (34) under every note, and noise after the last one.
    expect(sungSpan(curve((t) => t < 4 ? (t * 100).floor().isEven ? 34 : 45 : 90), notes, 0)!.low, 45, reason: 'hum under C2 never counts, even an octave under A2');
    expect(sungSpan(curve((t) => t < 2 ? 33 : 48), notes, 0)!.high, 48, reason: 'C3 is C4 an octave down; G#1 is hum');
    expect(sungSpan(curve((t) => 47, to: 4), notes, 2)!.low, 47, reason: 'the key change moves the notes up 2');
    expect(sungSpan(curve((t) => 45, to: 0.5), notes, 0), isNull, reason: 'under 1.6 s on the notes');
  });

  test('points follow how hard it is, on 5 / 10 / 25 / 50 / 100, one per tier', () {
    int pts(String id, [int tier = 1]) => achievements.firstWhere((a) => a.id == id).pointsOf(tier);
    for (final a in achievements) {
      expect(achievementPoints[a.id]?.length, a.thresholds.length, reason: a.id);
      for (final p in achievementPoints[a.id]!) {
        expect([5, 10, 25, 50, 100], contains(p), reason: a.id);
      }
    }
    expect(achievementPoints.keys.toSet(), achievements.map((a) => a.id).toSet(), reason: 'no points for a removed id');
    expect([for (var t = 1; t <= 3; t++) pts('takes', t)], [10, 25, 100]);
    expect([pts('rankS'), pts('rankSS'), pts('rankSSS')], [25, 50, 100]);
    expect(pts('shareCard'), 10);
    expect(pts('nightOwl'), lessThan(pts('rankSSS')), reason: 'a time of day is not an SSS');
    final secrets = achievements.where((a) => a.category == AchievementCategory.secret).fold<int>(0, (s, a) => s + a.pointsOf(1));
    expect(secrets, 300, reason: 'the secrets are worth double');
    expect(pts('graduate'), lessThan(pts('takes', 3)));
    final basics = achievements.where((a) => a.category == AchievementCategory.basics).fold<int>(0, (s, a) => s + a.pointsOf(1));
    expect(basics, 110, reason: '17 tasks of 5 and graduating');
  });

  group('service', () {
    late Directory tmp;
    late AchievementService svc;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      tmp = Directory.systemTemp.createTempSync('ach');
      final paths = AppPaths.forTest(tmp.path);
      svc = AchievementService(
        library: SongLibrary(paths),
        replays: ReplayLibrary(paths, Sidecars(paths, SidecarCatalog({}))),
        settings: await AppSettings.load(),
        dataRoot: tmp.path,
        cacheDir: p.join(tmp.path, 'cache'),
      );
    });
    tearDown(() {
      svc.dispose();
      tmp.deleteSync(recursive: true);
    });

    test('what was unlocked stays unlocked, whatever happens to the takes', () async {
      File(p.join(tmp.path, 'achievements.json')).writeAsStringSync(jsonEncode({
        'unlocked': {'takes.1': '2026-11-01T00:00:00.000', 'rankSSS': '2026-11-02T00:00:00.000'},
      }));
      await svc.start();
      expect(svc.tierOf(achievements.firstWhere((a) => a.id == 'takes')), 1, reason: 'no takes now, still bronze');
      expect(svc.unlocked.containsKey('rankSSS'), isTrue);
      expect(svc.points, 10 + 100);
    });

    test('SSS songs tiers from before the change are given back quietly only when still reached', () async {
      File(p.join(tmp.path, 'achievements.json')).writeAsStringSync(jsonEncode({
        'unlocked': {'sssSongs.1': '2026-11-01T00:00:00.000', 'rankSSS': '2026-11-01T00:00:00.000'},
      }));
      final batches = <List<AchievementUnlock>>[];
      final sub = svc.unlocks.listen(batches.add);
      await svc.start();
      await Future<void>.delayed(Duration.zero);
      expect(svc.unlocked.containsKey('sssSongs.1'), isFalse, reason: 'no takes: not three SSS songs');
      expect(svc.unlocked.containsKey('rankSSS'), isTrue);
      expect(batches, isEmpty);
      final saved = jsonDecode(File(p.join(tmp.path, 'achievements.json')).readAsStringSync()) as Map;
      expect(saved['version'], 4);
      expect((saved['unlocked'] as Map).containsKey('sssSongs.1'), isFalse);
      await sub.cancel();
    });

    test('an old two-tier silver becomes the new gold, with the silver below it', () async {
      File(p.join(tmp.path, 'achievements.json')).writeAsStringSync(jsonEncode({
        'version': 2,
        'unlocked': {'practice.1': '2026-11-01T00:00:00.000', 'practice.2': '2026-11-05T00:00:00.000', 'genres.2': '2026-11-06T00:00:00.000'},
      }));
      await svc.start();
      final practice = achievements.firstWhere((a) => a.id == 'practice');
      expect(svc.tierOf(practice), 3, reason: '30 takes of one song is the gold now');
      expect(svc.unlocked['practice.2'], DateTime.parse('2026-11-05T00:00:00.000'));
      expect(svc.tierOf(achievements.firstWhere((a) => a.id == 'genres')), 3, reason: 'ten genres (the old silver) is past the gold of 7 now');
      final saved = jsonDecode(File(p.join(tmp.path, 'achievements.json')).readAsStringSync()) as Map;
      expect(saved['version'], 4);
    });

    test('a take sung live is kept once, saved, and unlocks the first stream', () async {
      await svc.start();
      final batches = <List<AchievementUnlock>>[];
      final sub = svc.unlocks.listen(batches.add);
      await svc.recordLive('song/take1');
      await svc.recordLive('song/take1');
      await Future<void>.delayed(Duration.zero);
      expect(svc.live.length, 1);
      expect(batches.single.single.def.id, 'firstLive');
      final saved = jsonDecode(File(p.join(tmp.path, 'achievements.json')).readAsStringSync()) as Map;
      expect((saved['live'] as Map).keys, ['song/take1']);
      await sub.cancel();
    });

    test('version 4: single goals became bronze, genres moved up, shares counted from the firsts', () async {
      File(p.join(tmp.path, 'achievements.json')).writeAsStringSync(jsonEncode({
        'version': 3,
        'unlocked': {'chartSong': '2026-11-01T00:00:00.000', 'challenger': '2026-11-02T00:00:00.000', 'genres.1': '2026-11-03T00:00:00.000'},
        'events': {'share.card': '2026-11-04T00:00:00.000', 'share.video': '2026-11-05T00:00:00.000'},
      }));
      await svc.start();
      AchievementDef d(String id) => achievements.firstWhere((a) => a.id == id);
      expect(svc.tierOf(d('chartSong')), 1);
      expect(svc.unlocked['challenger.1'], DateTime.parse('2026-11-02T00:00:00.000'));
      expect(svc.tierOf(d('genres')), 2, reason: 'five genres is the silver now');
      expect(svc.counts['shares'], 2);
      await svc.recordEvent('share.card');
      expect(svc.counts['shares'], 3, reason: 'every share counts, not just the first');
      final saved = jsonDecode(File(p.join(tmp.path, 'achievements.json')).readAsStringSync()) as Map;
      expect(saved['version'], 4);
      expect((saved['counts'] as Map)['shares'], 3);
    });

    test('an action is recorded once and unlocks its achievement, saved to the data folder', () async {
      await svc.start();
      final batches = <List<AchievementUnlock>>[];
      final sub = svc.unlocks.listen(batches.add);
      await svc.recordEvent('share.video');
      await Future<void>.delayed(Duration.zero);
      expect(batches.single.single.def.id, 'shareVideo');
      final saved = jsonDecode(File(p.join(tmp.path, 'achievements.json')).readAsStringSync()) as Map;
      expect((saved['unlocked'] as Map).containsKey('shareVideo'), isTrue);
      expect((saved['events'] as Map).containsKey('share.video'), isTrue);
      await sub.cancel();
    });
  });
}
