// Debug builds only (flutter run): import a vocal recording as a take of a
// song, as if it had just been sung. The file is decoded, lined up with the
// song's separated vocal (the engine's aligner, as for imported backing
// tracks), and saved like a recording (48 kHz mono take.wav with its
// take.json and take.wav.json), ready to be scored.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'backing_import.dart';
import 'sidecars.dart';
import 'song_library.dart';
import '../engine/engine.dart';

class ImportedTake {
  const ImportedTake(this.take, this.delay, this.alignment);
  final TakeInfo take;

  /// Seconds the file was moved to line up (positive: silence added in
  /// front, negative: its start cut).
  final double delay;

  /// Null when the file was taken as it is.
  final BackingAlignment? alignment;
}

class TakeImport {
  TakeImport({required this.library, required this.sidecars, required this.engine, required this.cacheDir});
  final SongLibrary library;
  final Sidecars sidecars;
  final Engine engine;
  final String cacheDir;

  /// Live recordings are saved at this rate, one channel.
  static const takeRate = 48000;

  Future<ImportedTake> importVocal(Song song, String source, {bool align = true, void Function(double fraction, String stage)? onProgress}) async {
    final f = library.files(song);
    await Directory(cacheDir).create(recursive: true);
    final wav = p.join(cacheDir, 'take_import_${song.id}.wav');
    final json = p.join(cacheDir, 'take_import_${song.id}.json');
    onProgress?.call(0, 'decode');
    await sidecars.toWav(source, wav, sampleRate: BackingImport.sampleRate, onProgress: (x) => onProgress?.call(0.5 * x, 'decode'));
    var delay = 0.0;
    BackingAlignment? alignment;
    if (align && File(f.vocalsWav).existsSync()) {
      onProgress?.call(0.5, 'align');
      await engine.alignBacking(reference: f.vocalsWav, backing: wav, outJson: json);
      alignment = BackingAlignment.fromJson(jsonDecode(await File(json).readAsString()) as Map<String, dynamic>);
      delay = alignment.delay;
    }
    onProgress?.call(0.8, 'save');
    final ff = await sidecars.resolve(SidecarKind.ffmpeg);
    if (ff == null) throw StateError('ffmpeg not available');
    final take = await library.newTake(song);
    final code = await sidecars.run(ff, [
      '-y', '-hide_banner', '-nostdin', '-i', wav, //
      '-af', BackingImport.shiftFilter(delay),
      '-ar', '$takeRate', '-ac', '1', '-c:a', 'pcm_f32le', take.wav,
    ]);
    if (code != 0) {
      await Directory(take.dir).delete(recursive: true);
      throw StateError('ffmpeg exited with $code');
    }
    final seconds = await sidecars.duration(take.wav) ?? 0;
    final shift = delay == 0 ? '' : (delay > 0 ? ', ${delay.toStringAsFixed(2)} s of silence added in front' : ', first ${(-delay).toStringAsFixed(2)} s cut');
    final note = 'imported file$shift to line up with the song';
    const enc = JsonEncoder.withIndent('  ');
    await File(take.infoJson).writeAsString(enc.convert({
      'song_id': song.id,
      'pitch_shift': 0.0,
      'latency': 0.0,
      'started_at': take.createdAt.toIso8601String(),
      'track': 'inst',
      'duration': seconds,
      'imported_from': '${p.basename(source)}$shift',
    }));
    await File('${take.wav}.json').writeAsString(enc.convert({
      'duration': seconds,
      'frames': (seconds * takeRate).round(),
      'input_latency': 0.0,
      'latency': 0.0,
      'output_latency': 0.0,
      'note': note,
      'sample_rate': takeRate,
      'track_start_offset': 0.0,
      'track_synced': true,
    }));
    for (final t in [wav, json]) {
      try {
        await File(t).delete();
      } catch (_) {}
    }
    onProgress?.call(1, 'save');
    library.markTakesChanged(f);
    return ImportedTake(take, delay, alignment);
  }
}
