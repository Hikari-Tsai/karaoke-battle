import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/app_paths.dart';
import 'package:karaoke_battle/services/sidecars.dart';
import 'package:path/path.dart' as p;

/// A stand-in yt-dlp: `-U` prints [update]; a download fails with a 403
/// until an update has happened, then writes `source.mp4` and prints its path.
Future<void> _fakeYtDlp(AppPaths paths, {required String update}) async {
  await Directory(paths.sidecars).create(recursive: true);
  final exe = File(p.join(paths.sidecars, 'yt-dlp'));
  final marker = p.join(paths.sidecars, 'updated');
  await exe.writeAsString('''#!/bin/sh
if [ "\$1" = "-U" ]; then
  case "$update" in Updated*) touch "$marker";; esac
  echo "$update"; exit 0
fi
if [ ! -f "$marker" ]; then
  echo "ERROR: unable to download video data: HTTP Error 403: Forbidden" >&2; exit 1
fi
prev=""; for a; do [ "\$prev" = "-o" ] && tmpl="\$a"; prev="\$a"; done
f="\$(dirname "\$tmpl")/source.mp4"; touch "\$f"; echo "\$f"
''');
  await Process.run('chmod', ['+x', exe.path]);
}

void main() {
  late Directory tmp;
  late AppPaths paths;
  late Sidecars sidecars;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sidecars_test');
    paths = AppPaths.forTest(tmp.path);
    sidecars = Sidecars(paths, SidecarCatalog({}));
  });

  tearDown(() => tmp.delete(recursive: true));

  final skip = Platform.isWindows ? 'the fake yt-dlp is a shell script' : null;

  test('a failed download updates yt-dlp and tries again', skip: skip, () async {
    await _fakeYtDlp(paths, update: 'Updated yt-dlp to stable@2026.10.26');
    final out = await Directory(p.join(tmp.path, 'song')).create();
    final lines = <String>[];
    final file = await sidecars.downloadVideo('https://youtu.be/x', out.path, onProgress: (_, l) => lines.add(l));
    expect(file, p.join(out.path, 'source.mp4'));
    expect(lines, contains('Updated yt-dlp to stable@2026.10.26'));
  });

  test('without a newer yt-dlp the error carries its ERROR line', skip: skip, () async {
    await _fakeYtDlp(paths, update: 'yt-dlp is up to date (stable@2026.10.26)');
    final out = await Directory(p.join(tmp.path, 'song')).create();
    await expectLater(
      sidecars.downloadVideo('https://youtu.be/x', out.path),
      throwsA(isA<StateError>().having((e) => e.message, 'message', 'yt-dlp exited with 1: ERROR: unable to download video data: HTTP Error 403: Forbidden')),
    );
  });
}
