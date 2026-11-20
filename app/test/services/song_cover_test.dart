import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/app_paths.dart';
import 'package:karaoke_battle/services/sidecars.dart';
import 'package:karaoke_battle/services/song_cover.dart';
import 'package:karaoke_battle/services/song_library.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  late Sidecars sidecars;
  late SongFiles files;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('cover_test');
    sidecars = Sidecars(AppPaths.forTest(tmp.path), SidecarCatalog({}));
    files = SongFiles((Directory(p.join(tmp.path, 'song'))..createSync()).path);
  });

  tearDown(() => tmp.delete(recursive: true));

  test('with ffmpeg: a picture becomes the shown cover, at most 640 px wide; removing it shows the thumbnail again', () async {
    final ff = await sidecars.resolve(SidecarKind.ffmpeg);
    if (ff == null) {
      markTestSkipped('ffmpeg not installed');
      return;
    }
    final png = p.join(tmp.path, 'big.png');
    final gen = await Process.run(ff, ['-y', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'color=c=red:s=1200x800', '-frames:v', '1', png]);
    expect(gen.exitCode, 0, reason: '${gen.stderr}');
    expect(files.shownThumb, files.thumbJpg);

    await setSongCover(sidecars, files, png);
    expect(files.shownThumb, files.coverJpg);
    expect(isJpeg(File(files.coverJpg).readAsBytesSync()), isTrue);
    final probe = await Process.run(ff, ['-hide_banner', '-i', files.coverJpg]);
    expect('${probe.stderr}', contains('640x426'));

    // Not an image: the cover stays as it was.
    final bad = File(p.join(tmp.path, 'bad.png'))..writeAsStringSync('not an image');
    await expectLater(setSongCover(sidecars, files, bad.path), throwsStateError);
    expect(File(files.coverJpg).existsSync(), isTrue);
    expect(Directory(files.dir).listSync().map((e) => p.basename(e.path)), ['cover.jpg']);

    await removeSongCover(files);
    expect(files.shownThumb, files.thumbJpg);
  });
}
