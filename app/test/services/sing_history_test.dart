import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/scoring/models.dart';
import 'package:karaoke_battle/services/app_paths.dart';
import 'package:karaoke_battle/services/settings.dart';
import 'package:karaoke_battle/services/sing_history.dart';
import 'package:karaoke_battle/services/song_library.dart';
import 'package:karaoke_battle/state/i18n.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tmp;
  late SongLibrary library;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('history_test');
    library = SongLibrary(AppPaths.forTest(tmp.path));
  });
  tearDown(() => tmp.delete(recursive: true));

  /// A take folder named like the app names them, scored [total] (or not).
  Directory take(Song song, String at, double? total, {String? startedAt}) {
    final d = Directory(p.join(library.files(song).takesDir, at.replaceAll(':', '_')))..createSync(recursive: true);
    if (startedAt != null) File(p.join(d.path, 'take.json')).writeAsStringSync(jsonEncode({'started_at': startedAt}));
    if (total != null) {
      File(p.join(d.path, 'score.json')).writeAsStringSync(jsonEncode({
        'total': total,
        'rank': rankForTotal(total),
        'scale': scoreScaleVersion,
        'sub_scores_flat': {'pitch': 80, 'rhythm': 70},
      }));
    }
    return d;
  }

  test('lists every scored take of every song, newest first', () async {
    final a = await library.create(title: 'A', sourceType: SourceType.file);
    final b = await library.create(title: 'B', sourceType: SourceType.file);
    take(a, '2026-11-18T20:00:00', 80);
    take(b, '2026-11-19T21:30:00', 91.5);
    take(a, '2026-11-19T22:00:00', 85);
    take(b, '2026-11-19T22:10:00', null); // stopped before scoring

    final h = await loadSingHistory(library);
    expect([for (final e in h) '${e.song.title} ${e.take.total}'], ['A 85.0', 'B 91.5', 'A 80.0']);
    expect(h.first.take.subScores['pitch'], 80);
    expect(dayOf(h[1].take.createdAt), DateTime(2026, 11, 19));
    expect(dayOf(h[2].take.createdAt), DateTime(2026, 11, 18));
  });

  test('clearing hides what came before; the takes stay unless deleted', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = await AppSettings.load();
    final a = await library.create(title: 'A', sourceType: SourceType.file);
    final old = take(a, '2026-11-18T20:00:00', 80);
    expect(settings.historyClearedAt, isNull);

    await settings.setHistoryClearedAt(DateTime(2026, 11, 19));
    expect(await loadSingHistory(library, clearedAt: settings.historyClearedAt), isEmpty);
    expect(old.existsSync(), isTrue, reason: 'clearing the list keeps the recording');
    expect((await library.takes(a)).single.total, 80);

    take(a, '2026-11-20T09:00:00', 90);
    final h = await loadSingHistory(library, clearedAt: (await AppSettings.load()).historyClearedAt);
    expect(h.single.take.total, 90, reason: 'later takes are listed again');

    await settings.setHistoryClearedAt(null);
    expect((await loadSingHistory(library, clearedAt: settings.historyClearedAt)).length, 2);
  });

  test('the start point counts from its moment on and can move back', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = await AppSettings.load();
    final a = await library.create(title: 'A', sourceType: SourceType.file);
    take(a, '2026-11-18T20:00:00', 80);
    take(a, '2026-11-20T09:00:00', 90);

    // Sung exactly at the start: counted.
    await settings.setHistoryClearedAt(DateTime.parse('2026-11-20T09:00:00'));
    expect((await loadSingHistory(library, clearedAt: settings.historyClearedAt)).single.take.total, 90);

    // Moved back to an earlier day: the earlier take is listed again.
    await settings.setHistoryClearedAt(DateTime(2026, 11, 18, kDayStartHour));
    expect((await loadSingHistory(library, clearedAt: settings.historyClearedAt)).length, 2);
  });

  test('deleting takes removes only that song\'s take folders and tells the cards', () async {
    final a = await library.create(title: 'A', sourceType: SourceType.file);
    final b = await library.create(title: 'B', sourceType: SourceType.file);
    take(a, '2026-11-18T20:00:00', 80);
    final keep = take(a, '2026-11-19T20:00:00', 82);
    final other = take(b, '2026-11-18T20:00:00', 70);
    final seq = library.takesChanged.value?.seq ?? 0;

    final takesA = await library.takes(a);
    final first = takesA.where((t) => t.total == 80).toList();
    // A take of another song passed by mistake is left alone.
    await library.deleteTakes(a, [...first, ...await library.takes(b)]);

    expect((await library.takes(a)).map((t) => t.total), [82]);
    expect(keep.existsSync(), isTrue);
    expect(other.existsSync(), isTrue);
    expect(library.takesChanged.value?.songId, a.id);
    expect(library.takesChanged.value!.seq, greaterThan(seq));
  });

  test('a sing day runs from 5 a.m. to 5 a.m.', () {
    expect(dayOf(DateTime(2026, 11, 20, 23, 59)), DateTime(2026, 11, 20));
    expect(dayOf(DateTime(2026, 11, 21, 1, 30)), DateTime(2026, 11, 20));
    expect(dayOf(DateTime(2026, 11, 21, 5, 0)), DateTime(2026, 11, 21));
    expect(formatTimestamp(const Duration(hours: 1, minutes: 2, seconds: 3)), '1:02:03');
    expect(formatTimestamp(const Duration(seconds: -4)), '0:00:00');
  });

  test('setlists list songs in singing order, by clock or as a stream timeline', () async {
    I18n.notifier.value = 'zh';
    final a = await library.create(title: '晴天', sourceType: SourceType.file);
    final b = await library.create(title: '夜曲', sourceType: SourceType.file);
    // Folders are named at the end of a take; take.json says when it began.
    take(a, '2026-11-20T21:05:10', 88.4, startedAt: '2026-11-20T21:01:00');
    take(b, '2026-11-20T21:30:00', 91.2, startedAt: '2026-11-20T21:26:30');
    take(a, '2026-11-21T00:40:00', 79.0); // no take.json: the folder time

    final day = DateTime(2026, 11, 20);
    final entries = (await loadSingHistory(library)).where((e) => dayOf(e.startedAt) == day).toList();
    expect(entries.length, 3, reason: 'after midnight is still the same stream day');

    expect(formatSetlist(entries, day: day), '''🎤 2026-11-20 歌單（3 首）
1. 21:01  晴天  88.4 ${rankForTotal(88.4)}
2. 21:26  夜曲  91.2 ${rankForTotal(91.2)}
3. 00:40  晴天  79.0 ${rankForTotal(79.0)}
''');
    expect(formatSetlist(entries, day: day, scores: false, timelineStart: DateTime(2026, 11, 20, 20, 55)), '''🎤 2026-11-20 歌單（3 首）
0:06:00 晴天
0:31:30 夜曲
3:45:00 晴天
''');
  });

  test('the setlist log keeps today.txt and the day\'s file up to date', () async {
    SharedPreferences.setMockInitialValues({'setlist_scores': false});
    I18n.notifier.value = 'zh';
    final settings = await AppSettings.load();
    final dir = p.join(tmp.path, 'setlist');
    final log = SetlistLog(library, settings, dir);
    final a = await library.create(title: '晴天', sourceType: SourceType.file);
    final now = DateTime(2026, 11, 20, 22);

    await log.write(now: now);
    expect(File(log.todayFile).readAsStringSync(), '🎤 2026-11-20 歌單（0 首）\n');
    expect(File(log.dayFile(DateTime(2026, 11, 20))).existsSync(), isFalse, reason: 'no file for a day without songs');

    take(a, '2026-11-19T21:00:00', 70, startedAt: '2026-11-19T20:56:00'); // yesterday
    take(a, '2026-11-20T21:05:00', 88, startedAt: '2026-11-20T21:01:00');
    await settings.setHistoryClearedAt(DateTime(2026, 11, 20, 23)); // the log ignores clearing
    await log.write(now: now);
    expect(File(log.todayFile).readAsStringSync(), '🎤 2026-11-20 歌單（1 首）\n1. 21:01  晴天\n');
    expect(File(log.dayFile(DateTime(2026, 11, 20))).readAsStringSync(), File(log.todayFile).readAsStringSync());
    final yesterday = File(log.dayFile(DateTime(2026, 11, 19)));
    expect(yesterday.readAsStringSync(), '🎤 2026-11-19 歌單（1 首）\n1. 20:56  晴天\n', reason: 'earlier days get their file once');
    yesterday.writeAsStringSync('edited by hand');
    await log.write(now: now);
    expect(yesterday.readAsStringSync(), 'edited by hand', reason: 'and are not rewritten');
  });

  test('the totals at the top: takes, songs, time sung, days, average and best', () async {
    I18n.notifier.value = 'zh';
    final a = await library.create(title: 'A', sourceType: SourceType.file);
    final b = await library.create(title: 'B', sourceType: SourceType.file);
    final t1 = take(a, '2026-11-19T21:05:00', 80, startedAt: '2026-11-19T21:01:00');
    File(p.join(t1.path, 'take.json')).writeAsStringSync(jsonEncode({'started_at': '2026-11-19T21:01:00', 'duration': 200.5}));
    final t2 = take(b, '2026-11-20T01:00:00', 95.5); // older take: the length is in take.wav.json
    File(p.join(t2.path, 'take.wav.json')).writeAsStringSync(jsonEncode({'duration': 3500.0}));
    take(a, '2026-11-21T20:00:00', 90); // no length known

    final st = summarizeHistory(await loadSingHistory(library));
    expect(st.takes, 3);
    expect(st.songs, 2);
    expect(st.days, 2, reason: '01:00 still counts as the 19th');
    expect(st.first, DateTime(2026, 11, 19));
    expect(st.last, DateTime(2026, 11, 21));
    expect(st.sung, const Duration(seconds: 3700, milliseconds: 500));
    expect(st.average, closeTo(88.5, 1e-9));
    expect(st.best!.song.title, 'B');
    expect(formatSungTime(st.sung), '1 小時 1 分');
    expect(formatSungTime(const Duration(minutes: 12, seconds: 30)), '12 分 30 秒');
    expect(summarizeHistory(const []).best, isNull);
  });

  test('a single take removed from the history leaves the list and the setlist log, not the library', () async {
    SharedPreferences.setMockInitialValues({'setlist_scores': false});
    I18n.notifier.value = 'zh';
    final settings = await AppSettings.load();
    final a = await library.create(title: '晴天', sourceType: SourceType.file);
    take(a, '2026-11-20T21:05:00', 88, startedAt: '2026-11-20T21:01:00');
    final bad = take(a, '2026-11-20T21:20:00', 40, startedAt: '2026-11-20T21:16:00');
    final all = await loadSingHistory(library);
    final gone = all.firstWhere((e) => e.take.total == 40);
    expect(gone.key, '${a.id}/${p.basename(bad.path)}');

    await settings.setHistoryHidden({gone.key});
    expect((await AppSettings.load()).historyHidden, {gone.key});
    final shown = await loadSingHistory(library, hidden: settings.historyHidden);
    expect(shown.map((e) => e.take.total), [88]);
    expect(bad.existsSync(), isTrue, reason: 'the recording stays');
    expect((await library.takes(a)).length, 2);

    final log = SetlistLog(library, settings, p.join(tmp.path, 'setlist'));
    await log.write(now: DateTime(2026, 11, 20, 22));
    expect(File(log.todayFile).readAsStringSync(), '🎤 2026-11-20 歌單（1 首）\n1. 21:01  晴天\n');

    await settings.setHistoryHidden({});
    expect((await loadSingHistory(library, hidden: settings.historyHidden)).length, 2, reason: 'undo');
  });
}
