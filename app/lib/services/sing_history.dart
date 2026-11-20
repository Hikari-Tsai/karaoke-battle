// The sing history ("演唱紀錄"): every scored take of every song, newest first.
// Clearing it only hides what came before a moment (the recordings and the
// library's best scores stay) unless the user also asks to delete them; a
// single take can be removed the same way.
//
// For streams, a day's songs can be written out as a setlist (clock times
// or a timeline for YouTube timestamps), and the app keeps a setlist log per
// day under setlist/ in the data folder, with today.txt for OBS.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../state/i18n.dart';
import 'settings.dart';
import 'song_library.dart';

class HistoryEntry {
  const HistoryEntry(this.song, this.take, {this.started, this.seconds});
  final Song song;
  final TakeInfo take;

  /// From take.json; older takes may not say.
  final DateTime? started;

  /// How long the recording is (take.json or take.wav.json), when known.
  final double? seconds;

  /// When the singing started (the take folder is named when it stopped).
  DateTime get startedAt => started ?? take.createdAt;

  String get key => historyKey(song, take);
}

/// Names one take across songs, for takes removed from the history.
String historyKey(Song song, TakeInfo take) => '${song.id}/${take.id}';

/// A sing day starts at this hour, so a stream past midnight stays one day.
const kDayStartHour = 5;

/// The sing day of [t] (local; before [kDayStartHour] counts as the day before).
DateTime dayOf(DateTime t) {
  final l = t.toLocal().subtract(const Duration(hours: kDayStartHour));
  return DateTime(l.year, l.month, l.day);
}

/// Scored takes of [library]'s songs sung from [clearedAt] on (the History's
/// start point; null: all of them) and not in [hidden] (see [historyKey]),
/// newest first.
Future<List<HistoryEntry>> loadSingHistory(SongLibrary library, {DateTime? clearedAt, Set<String> hidden = const {}}) async {
  final out = <HistoryEntry>[];
  for (final song in library.songs) {
    for (final take in await library.takes(song)) {
      if (take.total == null) continue;
      if (clearedAt != null && take.createdAt.isBefore(clearedAt)) continue;
      if (hidden.contains(historyKey(song, take))) continue;
      final (started, seconds) = await _takeMeta(take);
      out.add(HistoryEntry(song, take, started: started, seconds: seconds));
    }
  }
  out.sort((a, b) => b.take.createdAt.compareTo(a.take.createdAt));
  return out;
}

/// When the take started and how long it is, from take.json (and the
/// recording's take.wav.json for the length of older takes).
Future<(DateTime?, double?)> _takeMeta(TakeInfo take) async {
  DateTime? started;
  double? seconds;
  for (final path in [take.infoJson, '${take.wav}.json']) {
    try {
      final f = File(path);
      if (!await f.exists()) continue;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map) continue;
      started ??= DateTime.tryParse('${j['started_at']}');
      final d = j['duration'];
      if (seconds == null && d is num && d > 0) seconds = d.toDouble();
    } catch (_) {}
    if (seconds != null) break;
  }
  return (started, seconds);
}

/// Totals over a list of history entries, for the top of 演唱紀錄.
class HistoryStats {
  const HistoryStats({required this.takes, required this.songs, required this.days, required this.sung, this.first, this.last, this.average, this.best});
  final int takes, songs, days;

  /// Time spent singing (the recordings' lengths).
  final Duration sung;

  /// The first and last sing day.
  final DateTime? first, last;
  final double? average;
  final HistoryEntry? best;
}

HistoryStats summarizeHistory(List<HistoryEntry> entries) {
  final days = {for (final e in entries) dayOf(e.startedAt)}.toList()..sort();
  var seconds = 0.0;
  var sum = 0.0;
  HistoryEntry? best;
  for (final e in entries) {
    seconds += e.seconds ?? 0;
    sum += e.take.total!;
    if (best == null || e.take.total! > best.take.total!) best = e;
  }
  return HistoryStats(
    takes: entries.length,
    songs: {for (final e in entries) e.song.id}.length,
    days: days.length,
    sung: Duration(milliseconds: (seconds * 1000).round()),
    first: days.isEmpty ? null : days.first,
    last: days.isEmpty ? null : days.last,
    average: entries.isEmpty ? null : sum / entries.length,
    best: best,
  );
}

/// A length of singing: "1 小時 5 分" from an hour up, else "12 分 30 秒".
String formatSungTime(Duration d) {
  if (d.inHours > 0) return tr('history.hm', {'h': d.inHours, 'm': d.inMinutes % 60});
  return tr('history.ms', {'m': d.inMinutes, 's': d.inSeconds % 60});
}

String _two(int n) => n.toString().padLeft(2, '0');

String formatDay(DateTime day) => '${day.year}-${_two(day.month)}-${_two(day.day)}';

/// The History's start point: the sing day when it is the start of one
/// (kDayStartHour), else the date and time it was set to.
String formatStart(DateTime start) {
  final t = start.toLocal();
  if (t.hour == kDayStartHour && t.minute == 0) return formatDay(dayOf(t));
  return '${formatDay(DateTime(t.year, t.month, t.day))} ${_two(t.hour)}:${_two(t.minute)}';
}

/// A video timestamp, H:MM:SS (YouTube links these in comments).
String formatTimestamp(Duration d) {
  if (d.isNegative) d = Duration.zero;
  return '${d.inHours}:${_two(d.inMinutes % 60)}:${_two(d.inSeconds % 60)}';
}

/// [entries] as a setlist in singing order: numbered with clock times, or,
/// given [timelineStart] (when the stream started), one "H:MM:SS title" line
/// per song for video timestamps.
String formatSetlist(List<HistoryEntry> entries, {required DateTime day, DateTime? since, bool range = false, bool scores = true, DateTime? timelineStart}) {
  final sorted = [...entries]..sort((a, b) => a.startedAt.compareTo(b.startedAt));
  final n = sorted.length;
  // A day's setlist, or the History's range (from [since], or all takes).
  final header = !range
      ? tr('setlist.header', {'date': formatDay(day), 'n': n})
      : since != null
          ? tr('setlist.headerSince', {'date': formatStart(since), 'n': n})
          : tr('setlist.headerAll', {'n': n});
  final lines = <String>[header];
  // Over several days the clock times get their date.
  final multiDay = {for (final e in sorted) dayOf(e.startedAt)}.length > 1;
  for (final (i, e) in sorted.indexed) {
    final score = scores ? '  ${e.take.total!.toStringAsFixed(1)} ${e.take.rank ?? ''}'.trimRight() : '';
    if (timelineStart != null) {
      lines.add('${formatTimestamp(e.startedAt.difference(timelineStart))} ${e.song.title}$score');
    } else {
      final t = e.startedAt.toLocal();
      final date = multiDay ? '${_two(dayOf(e.startedAt).month)}/${_two(dayOf(e.startedAt).day)} ' : '';
      lines.add('${i + 1}. $date${_two(t.hour)}:${_two(t.minute)}  ${e.song.title}$score');
    }
  }
  return '${lines.join('\n')}\n';
}

/// Keeps `setlist/today.txt` (the OBS setlist: the History's range, from its
/// start point on) and `setlist/<day>.txt` (a record of each day's singing)
/// up to date as takes are scored and the start point moves.
class SetlistLog {
  SetlistLog(this.library, this.settings, this.dir);
  final SongLibrary library;
  final AppSettings settings;
  final String dir;

  String get todayFile => p.join(dir, 'today.txt');
  String dayFile(DateTime day) => p.join(dir, '${formatDay(day)}.txt');

  Future<void>? _writing;
  bool _again = false;

  DateTime? _since;

  void start() {
    library.takesChanged.addListener(update);
    settings.addListener(_onSettings);
    _since = settings.historyClearedAt;
    update();
  }

  void stop() {
    library.takesChanged.removeListener(update);
    settings.removeListener(_onSettings);
  }

  /// The History's start point moved: the OBS setlist follows it.
  void _onSettings() {
    final since = settings.historyClearedAt;
    if (since == _since) return;
    _since = since;
    update();
  }

  /// Rewrites today's files (coalesced while a write is running).
  void update() {
    if (_writing != null) {
      _again = true;
      return;
    }
    _writing = write().catchError((_) {}).whenComplete(() {
      _writing = null;
      if (_again) {
        _again = false;
        update();
      }
    });
  }

  /// Writes the OBS setlist (the History's range: every scored take from
  /// its start point on, not takes removed one by one), today's file and
  /// the files of earlier days that do not have one yet.
  Future<void> write({DateTime? now}) async {
    final today = dayOf(now ?? DateTime.now());
    final since = settings.historyClearedAt;
    final all = await loadSingHistory(library, hidden: settings.historyHidden);
    final byDay = <DateTime, List<HistoryEntry>>{};
    for (final e in all) {
      (byDay[dayOf(e.startedAt)] ??= []).add(e);
    }
    await Directory(dir).create(recursive: true);
    final scores = settings.setlistScores;
    final inRange = [for (final e in all) if (since == null || !e.take.createdAt.isBefore(since)) e];
    await File(todayFile).writeAsString(formatSetlist(inRange, day: today, since: since, range: true, scores: scores), flush: true);
    for (final MapEntry(key: day, value: entries) in byDay.entries) {
      final f = File(dayFile(day));
      if (day == today) {
        await f.writeAsString(formatSetlist(entries, day: day, scores: scores), flush: true);
      } else if (!await f.exists()) {
        await f.writeAsString(formatSetlist(entries, day: day, scores: scores), flush: true);
      }
    }
  }
}
