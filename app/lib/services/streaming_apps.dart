// Whether a streaming app (OBS Studio, Streamlabs, XSplit) is running, for
// the first-livestream achievement. Only process names are looked at, on
// this computer; nothing is sent anywhere.
import 'dart:io';

/// Whether [name] (a process name, as ps or tasklist give it) is a
/// streaming app.
bool isStreamingApp(String name) {
  var n = name.trim().toLowerCase();
  if (n.startsWith('"')) n = n.substring(1);
  if (n.endsWith('"')) n = n.substring(0, n.length - 1);
  if (n.endsWith('.exe')) n = n.substring(0, n.length - 4);
  return n == 'obs' || n == 'obs64' || n == 'obs32' || n.startsWith('streamlabs') || n.startsWith('xsplit');
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
