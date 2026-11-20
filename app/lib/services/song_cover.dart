// A cover image the user picked for a song from a local file: cover.jpg in
// the song folder. It is shown instead of the automatic thumbnail (a frame
// grabbed from a video, if any), and travels with a replay when the song is
// included in the export.
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'sidecars.dart';
import 'song_library.dart';

/// Image types offered when picking a cover (ffmpeg decodes them all).
const kCoverExtensions = ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif'];

/// Covers are at most this wide (the library shows them at 128 px).
const kCoverWidth = 640;

/// Whether [bytes] look like a JPEG (FF D8 FF).
bool isJpeg(Uint8List bytes) => bytes.length > 3 && bytes[0] == 0xff && bytes[1] == 0xd8 && bytes[2] == 0xff;

/// Converts [imagePath] to the song's cover.jpg (first frame, at most
/// [kCoverWidth] px wide). The previous cover stays if the image cannot be read.
Future<void> setSongCover(Sidecars sidecars, SongFiles files, String imagePath) async {
  final ff = await sidecars.resolve(SidecarKind.ffmpeg);
  if (ff == null) throw StateError('ffmpeg not available');
  final tmp = p.join(files.dir, 'cover.tmp.jpg');
  try {
    final code = await sidecars.run(ff, [
      '-y', '-hide_banner', '-nostdin', '-i', imagePath, '-frames:v', '1', //
      '-vf', 'scale=w=min($kCoverWidth\\,iw):h=-2', '-q:v', '3', tmp,
    ]);
    if (code != 0 || !await File(tmp).exists() || !isJpeg(await File(tmp).readAsBytes())) {
      throw StateError('not an image ffmpeg can read (exit $code)');
    }
    await File(tmp).rename(files.coverJpg);
  } finally {
    if (await File(tmp).exists()) await File(tmp).delete();
  }
}

Future<void> removeSongCover(SongFiles files) async {
  final f = File(files.coverJpg);
  if (await f.exists()) await f.delete();
}
