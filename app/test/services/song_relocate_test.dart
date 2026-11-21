// After the data folder moved (another place, another computer, macOS to
// Windows), a song's stored original file path is stale: it is pointed at
// the same file in the song's folder.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/app_paths.dart';
import 'package:karaoke_battle/services/song_library.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('relocate'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<String> song(String id, String storedPath, {bool fileHere = true}) async {
    final dir = Directory(p.join(tmp.path, 'songs', id))..createSync(recursive: true);
    if (fileHere) File(p.join(dir.path, 'source.mp4')).writeAsStringSync('x');
    File(p.join(dir.path, 'meta.json')).writeAsStringSync(jsonEncode({
      'id': id,
      'title': id,
      'source_type': 'file',
      'created_at': '2026-11-20T10:00:00.000',
      'source_file': storedPath,
    }));
    return dir.path;
  }

  test('a stale path from another computer points at the file in the song folder', () async {
    final mac = await song('a', '/Users/someone/Library/Application Support/x/KaraokeBattle/songs/a/source.mp4');
    final win = await song('b', r'C:\Users\someone\AppData\Roaming\x\KaraokeBattle\songs\b\source.mp4');
    final lib = SongLibrary(AppPaths.forTest(tmp.path));
    await lib.reload();
    expect(lib.byId('a')!.sourceFile, p.join(mac, 'source.mp4'));
    expect(lib.byId('b')!.sourceFile, p.join(win, 'source.mp4'), reason: 'a Windows path read on any computer');
    final saved = jsonDecode(File(p.join(mac, 'meta.json')).readAsStringSync()) as Map;
    expect(saved['source_file'], p.join(mac, 'source.mp4'), reason: 'kept for next time');
  });

  test('a path that still works, or a file that is gone, is left as it is', () async {
    final dir = await song('c', 'placeholder');
    final ok = p.join(dir, 'source.mp4');
    File(p.join(dir, 'meta.json')).writeAsStringSync(jsonEncode({'id': 'c', 'title': 'c', 'source_type': 'file', 'created_at': '2026-11-20T10:00:00.000', 'source_file': ok}));
    await song('d', '/old/place/songs/d/source.mp4', fileHere: false);
    final lib = SongLibrary(AppPaths.forTest(tmp.path));
    await lib.reload();
    expect(lib.byId('c')!.sourceFile, ok);
    expect(lib.byId('d')!.sourceFile, '/old/place/songs/d/source.mp4', reason: 'nothing to point at: a YouTube song downloads it again');
  });
}
