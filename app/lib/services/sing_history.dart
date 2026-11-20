// The sing history ("歌單"): every scored take of every song, newest first.
// Clearing it only hides what came before a moment (the recordings and the
// library's best scores stay) unless the user also asks to delete them.
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
  const HistoryEntry(this.song, this.take, {this.started});
  final Song song;
  final TakeInfo take;

  /// From take.json; older takes may not say.
  final DateTime? started;

  /// When the singing started (the take folder is named when it stopped).
  DateTime get startedAt => started ?? take.createdAt;
}

/// A sing day starts at this hour, so a stream past midnight stays one day.
const kDayStartHour = 5;

/// The sing day of [t] (local; before [kDayStartHour] counts as the day before).
DateTime dayOf(DateTime t) {
  final l = t.toLocal().subtract(const Duration(hours: kDayStartHour));
  return DateTime(l.year, l.month, l.day);
}

/// Scored takes of [library]'s songs sung after [clearedAt], newest first.
Future<List<HistoryEntry>> loadSingHistory(SongLibrary library, {DateTime? clearedAt}) async {
  final out = <HistoryEntry>[];
  for (final song in library.songs) {
    for (final take in await library.takes(song)) {
      if (take.total == null) continue;
      if (clearedAt != null && !take.createdAt.isAfter(clearedAt)) continue;
      out.add(HistoryEntry(song, take, started: await _startedAt(take)));
    }
  }
  out.sort((a, b) => b.take.createdAt.compareTo(a.take.createdAt));
  return out;
}

Future<DateTime?> _startedAt(TakeInfo take) async {
  try {
    final f = File(take.infoJson);
    if (!await f.exists()) return null;
    final j = jsonDecode(await f.readAsString());
    return j is Map ? DateTime.tryParse('${j['started_at']}') : null;
  } catch (_) {
    return null;
  }
}

String _two(int n) => n.toString().padLeft(2, '0');

String formatDay(DateTime day) => '${day.year}-${_two(day.month)}-${_two(day.day)}';

/// A video timestamp, H:MM:SS (YouTube links these in comments).
String formatTimestamp(Duration d) {
  if (d.isNegative) d = Duration.zero;
  return '${d.inHours}:${_two(d.inMinutes % 60)}:${_two(d.inSeconds % 60)}';
}

/// [entries] as a setlist in singing order: numbered with clock times, or,
/// given [timelineStart] (when the stream started), one "H:MM:SS title" line
/// per song for video timestamps.
String formatSetlist(List<HistoryEntry> entries, {required DateTime day, bool scores = true, DateTime? timelineStart}) {
  final sorted = [...entries]..sort((a, b) => a.startedAt.compareTo(b.startedAt));
  final lines = <String>[tr('setlist.header', {'date': formatDay(day), 'n': sorted.length})];
  for (final (i, e) in sorted.indexed) {
    final score = scores ? '  ${e.take.total!.toStringAsFixed(1)} ${e.take.rank ?? ''}'.trimRight() : '';
    if (timelineStart != null) {
      lines.add('${formatTimestamp(e.startedAt.difference(timelineStart))} ${e.song.title}$score');
    } else {
      final t = e.startedAt.toLocal();
      lines.add('${i + 1}. ${_two(t.hour)}:${_two(t.minute)}  ${e.song.title}$score');
    }
  }
  return '${lines.join('\n')}\n';
}

/// Keeps `setlist/<day>.txt` and `setlist/today.txt` up to date as takes are
/// scored, for OBS text sources and as a record of each day's singing.
class SetlistLog {
  SetlistLog(this.library, this.settings, this.dir);
  final SongLibrary library;
  final AppSettings settings;
  final String dir;

  String get todayFile => p.join(dir, 'today.txt');
  String dayFile(DateTime day) => p.join(dir, '${formatDay(day)}.txt');

  Future<void>? _writing;
  bool _again = false;

  void start() {
    library.takesChanged.addListener(update);
    update();
  }

  void stop() {
    library.takesChanged.removeListener(update);
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

  /// Writes today's setlist (every scored take today, cleared or not), and
  /// the files of earlier days that do not have one yet.
  Future<void> write({DateTime? now}) async {
    final today = dayOf(now ?? DateTime.now());
    final byDay = <DateTime, List<HistoryEntry>>{};
    for (final e in await loadSingHistory(library)) {
      (byDay[dayOf(e.startedAt)] ??= []).add(e);
    }
    await Directory(dir).create(recursive: true);
    final scores = settings.setlistScores;
    final text = formatSetlist(byDay[today] ?? const [], day: today, scores: scores);
    await File(todayFile).writeAsString(text, flush: true);
    for (final MapEntry(key: day, value: entries) in byDay.entries) {
      final f = File(dayFile(day));
      if (day == today) {
        await f.writeAsString(text, flush: true);
      } else if (!await f.exists()) {
        await f.writeAsString(formatSetlist(entries, day: day, scores: scores), flush: true);
      }
    }
  }
}
