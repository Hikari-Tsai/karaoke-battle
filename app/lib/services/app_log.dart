// The app's log: engine log lines, uncaught Flutter/Dart errors and errors
// shown to the user, kept in memory (the recent lines, for problem reports)
// and appended to <data>/logs/app.log (the previous run's file is kept as
// app.1.log). Home folders are written as "~" so a report does not carry the
// user name.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

class AppLog {
  AppLog._();

  /// Lines kept in memory.
  static const keepLines = 1500;

  /// app.log is rotated at startup once it is larger than this.
  static const rotateBytes = 2 * 1024 * 1024;

  static final List<String> _lines = [];
  static IOSink? _sink;
  static String? _dir;
  static bool _hooked = false;

  /// The logs folder, once [init] has run.
  static String? get directory => _dir;
  static String? get file => _dir == null ? null : p.join(_dir!, 'app.log');

  /// Opens the log file in [logsDir]; lines logged before this are written
  /// out first. Safe to call more than once (later calls are ignored).
  static Future<void> init(String logsDir, {String? header}) async {
    if (_dir != null) return;
    try {
      await Directory(logsDir).create(recursive: true);
      final f = File(p.join(logsDir, 'app.log'));
      if (await f.exists() && await f.length() > rotateBytes) {
        await f.rename(p.join(logsDir, 'app.1.log'));
      }
      _dir = logsDir;
      final sink = f.openWrite(mode: FileMode.append);
      sink.writeln('');
      sink.writeln('===== ${DateTime.now().toIso8601String()} ${header ?? ''}'.trimRight());
      for (final l in _lines) {
        sink.writeln(l);
      }
      _sink = sink;
    } catch (e) {
      _dir = null;
      debugPrint('AppLog: cannot open $logsDir: $e');
    }
  }

  /// Records uncaught framework and platform errors (keeping Flutter's own
  /// reporting).
  static void hookErrors() {
    if (_hooked) return;
    _hooked = true;
    final prevFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      error(details.exception, details.stack, 'flutter${details.library != null ? ' (${details.library})' : ''}');
      prevFlutter?.call(details);
    };
    final dispatcher = PlatformDispatcher.instance;
    final prevPlatform = dispatcher.onError;
    dispatcher.onError = (e, st) {
      error(e, st, 'uncaught');
      return prevPlatform?.call(e, st) ?? false;
    };
  }

  /// One line; [level] is D, I, W or E.
  static void log(String level, String message) {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${t.millisecond.toString().padLeft(3, '0')}';
    for (final line in redact(message).split('\n')) {
      final l = '$stamp $level $line';
      _lines.add(l);
      _sink?.writeln(l);
    }
    if (_lines.length > keepLines) _lines.removeRange(0, _lines.length - keepLines);
  }

  static void info(String message) => log('I', message);
  static void warn(String message) => log('W', message);

  /// An error with its stack (the first lines) and where it happened.
  static void error(Object e, [StackTrace? st, String? where]) {
    final head = where == null ? '$e' : '[$where] $e';
    final stack = st == null ? '' : '\n${_shortStack(st)}';
    log('E', '$head$stack');
  }

  /// A log line from the native engine ("[W] text").
  static void engine(String line) {
    final m = RegExp(r'^\[([DIWE])\] ').firstMatch(line);
    if (m == null) {
      log('I', 'engine: $line');
    } else {
      log(m.group(1)!, 'engine: ${line.substring(m.end)}');
    }
  }

  static String _shortStack(StackTrace st, [int maxLines = 12]) {
    final lines = st.toString().split('\n').where((l) => l.trim().isNotEmpty).toList();
    final kept = lines.take(maxLines).map((l) => '    $l').join('\n');
    return lines.length > maxLines ? '$kept\n    ...' : kept;
  }

  /// The recent lines in memory, oldest first.
  static List<String> get recent => List.unmodifiable(_lines);

  /// Writes the recent lines to logs/report-<time>.log for attaching to an
  /// issue; null when there is no logs folder.
  static Future<String?> writeSnapshot() async {
    final dir = _dir;
    if (dir == null) return null;
    try {
      await _sink?.flush();
      final t = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final name = 'report-${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}.log';
      final f = File(p.join(dir, name));
      await f.writeAsString('${_lines.join('\n')}\n');
      return f.path;
    } catch (_) {
      return null;
    }
  }

  /// Home folders become "~": /Users/name, /home/name, C:\Users\name.
  static String redact(String s) {
    var out = s;
    final home = _home;
    if (home != null && home.length > 3) out = out.replaceAll(home, '~');
    return out
        .replaceAll(RegExp(r'/Users/[^/\s]+'), '~')
        .replaceAll(RegExp(r'/home/[^/\s]+'), '~')
        .replaceAll(RegExp(r'[A-Za-z]:\\Users\\[^\\\s]+', caseSensitive: false), '~');
  }

  static final String? _home = (() {
    try {
      return Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
    } catch (_) {
      return null;
    }
  })();

  /// For tests: forgets everything (the file stays).
  @visibleForTesting
  static Future<void> reset() async {
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
    _dir = null;
    _lines.clear();
  }
}
