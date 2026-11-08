import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/app_paths.dart';
import 'package:karaoke_battle/services/song_library.dart';

void main() {
  test('takesChanged fires for every scored take, also of the same song', () {
    final lib = SongLibrary(AppPaths.forTest('/tmp/ke-unused'));
    final seen = <String>[];
    lib.takesChanged.addListener(() => seen.add(lib.takesChanged.value!.songId));

    lib.markTakesChanged(SongFiles('/data/songs/abc'));
    lib.markTakesChanged(SongFiles('/data/songs/abc')); // sing again: same song
    lib.markTakesChanged(SongFiles('/data/songs/xyz'));

    expect(seen, ['abc', 'abc', 'xyz']);
  });
}
