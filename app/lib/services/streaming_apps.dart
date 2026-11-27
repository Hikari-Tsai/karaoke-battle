// Whether a streaming app (OBS Studio, Streamlabs, XSplit, vMix, …) is
// running: for the first-livestream achievement, and for 直播模式, which
// masks private details on screen while one is (see StreamingWatch). Only
// process names are looked at, on this computer; nothing is sent anywhere.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../state/stream_privacy.dart';

/// Whether [name] (a process name, as ps or tasklist give it) is a
/// streaming app.
bool isStreamingApp(String name) {
  var n = name.trim().toLowerCase();
  if (n.startsWith('"')) n = n.substring(1);
  if (n.endsWith('"')) n = n.substring(0, n.length - 1);
  if (n.endsWith('.exe')) n = n.substring(0, n.length - 4);
  if (n == 'obs' || n == 'obs64' || n == 'obs32' || n.startsWith('streamlabs') || n.startsWith('xsplit')) return true;
  // vMix, PRISM Live Studio, Twitch Studio, TikTok LIVE Studio, Meld Studio,
  // Ecamm Live, Wirecast.
  final c = n.replaceAll(' ', '');
  return c.startsWith('vmix') || c.startsWith('prismlivestudio') || c.startsWith('twitchstudio') || c.startsWith('tiktoklivestudio') || c.startsWith('meldstudio') || c.startsWith('ecammlive') || c.startsWith('wirecast');
}

/// The process names in `ps -axco command` (macOS), `ps -eo comm` (Linux)
/// or `tasklist /FO CSV /NH` (Windows: the first column) output.
Iterable<String> processNames(String out) sync* {
  for (final line in out.split('\n')) {
    final l = line.trim();
    if (l.isEmpty) continue;
    yield l.startsWith('"') ? l.substring(0, l.indexOf('"', 1) + 1) : l;
  }
}

/// True when a streaming app is running; false when none is, or the list
/// could not be read.
Future<bool> streamingAppRunning() async {
  try {
    final ProcessResult r;
    if (Platform.isWindows) {
      r = await Process.run('tasklist', ['/FO', 'CSV', '/NH']);
    } else if (Platform.isMacOS) {
      r = await Process.run('/bin/ps', ['-axco', 'command']);
    } else {
      r = await Process.run('ps', ['-eo', 'comm']);
    }
    return processNames('${r.stdout}').any(isStreamingApp);
  } catch (_) {
    return false;
  }
}

/// 直播模式: checks every [interval] whether a streaming app is running and
/// keeps [StreamPrivacy.live] (and [live]) up to date.
class StreamingWatch extends ChangeNotifier {
  StreamingWatch({this.interval = const Duration(seconds: 10), Future<bool> Function()? check}) : _check = check ?? streamingAppRunning;
  final Duration interval;
  final Future<bool> Function() _check;
  Timer? _timer;
  bool _checking = false;

  bool get live => StreamPrivacy.live.value;

  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(interval, (_) => poll());
    StreamPrivacy.simulate.addListener(poll);
    poll();
  }

  @visibleForTesting
  Future<void> poll() async {
    if (_checking) return;
    _checking = true;
    try {
      // 開發模式 can act as if one were running.
      final on = StreamPrivacy.simulate.value || await _check();
      if (on != StreamPrivacy.live.value) {
        StreamPrivacy.live.value = on;
        notifyListeners();
      }
    } finally {
      _checking = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    StreamPrivacy.simulate.removeListener(poll);
    super.dispose();
  }
}
