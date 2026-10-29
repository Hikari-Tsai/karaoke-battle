// Builds the audio of a take replay: the recorded voice placed on the track
// timeline (take time + offset = track time) mixed over the backing track
// the singer heard, pitch-shifted by the same key change. Cached as
// replay.wav in the take folder.
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import 'sidecars.dart';

String replayWavPath(String takeDir) => p.join(takeDir, 'replay.wav');

/// Creates (or reuses) the replay mix and returns its path.
/// [offsetSeconds] maps take time to track time; [pitchShift] is in
/// semitones (the key the take was sung in).
Future<String> ensureReplayMix(
  Sidecars sidecars, {
  required String takeDir,
  required String voiceWav,
  required String backingWav,
  required double offsetSeconds,
  double pitchShift = 0,
  double voiceGain = 1.0,
  double backingGain = 0.8,
}) async {
  final out = replayWavPath(takeDir);
  if (await File(out).exists() && await File(out).length() > 1024) return out;
  final ff = await sidecars.resolve(SidecarKind.ffmpeg);
  if (ff == null) throw StateError('ffmpeg not available');

  // Microphone recordings are usually far quieter than the track: bring the
  // voice to about 2 dB under the backing's average level (at most +24 dB).
  final voiceDb = await _meanVolumeDb(sidecars, ff, voiceWav);
  final backDb = await _meanVolumeDb(sidecars, ff, backingWav);
  if (voiceDb != null && backDb != null) {
    final boostDb = (backDb + 20 * math.log(backingGain) / math.ln10 - 2 - voiceDb).clamp(0.0, 24.0);
    voiceGain *= math.pow(10, boostDb / 20).toDouble();
  }

  final voice = <String>['[1:a]aformat=channel_layouts=mono', 'aresample=44100', 'pan=stereo|c0=c0|c1=c0'];
  if (offsetSeconds > 0) {
    voice.add('adelay=${(offsetSeconds * 1000).round()}:all=1');
  } else if (offsetSeconds < 0) {
    voice.addAll(['atrim=start=${(-offsetSeconds).toStringAsFixed(4)}', 'asetpts=PTS-STARTPTS']);
  }
  voice.add('volume=${voiceGain.toStringAsFixed(3)}[v]');

  final backing = <String>['[0:a]aresample=44100'];
  if (pitchShift.abs() > 1e-3) {
    // Pitch without tempo change: speed up by r, then stretch back by 1/r.
    final r = math.pow(2, pitchShift / 12).toDouble();
    backing.addAll(['asetrate=${(44100 * r).toStringAsFixed(3)}', 'aresample=44100', 'atempo=${(1 / r).toStringAsFixed(6)}']);
  }
  backing.add('volume=${backingGain.toStringAsFixed(3)}[b]');

  final filter = '${backing.join(',')};${voice.join(',')};[b][v]amix=inputs=2:duration=first:normalize=0,alimiter=limit=0.95[out]';
  final tmp = '$out.part.wav';
  final code = await sidecars.run(ff, [
    '-y', '-hide_banner', '-nostdin',
    '-i', backingWav,
    '-i', voiceWav,
    '-filter_complex', filter,
    '-map', '[out]',
    '-c:a', 'pcm_s16le',
    tmp,
  ]);
  if (code != 0) {
    final f = File(tmp);
    if (await f.exists()) await f.delete();
    throw StateError('ffmpeg replay mix exited with $code');
  }
  await File(tmp).rename(out);
  return out;
}

final _meanVolume = RegExp(r'mean_volume:\s*(-?[0-9.]+) dB');

/// Average level of [path] in dBFS (ffmpeg volumedetect), or null.
Future<double?> _meanVolumeDb(Sidecars sidecars, String ff, String path) async {
  double? db;
  await sidecars.run(ff, ['-hide_banner', '-nostdin', '-i', path, '-af', 'volumedetect', '-f', 'null', '-'], onLine: (l) {
    final m = _meanVolume.firstMatch(l);
    if (m != null) db = double.tryParse(m.group(1)!);
  });
  return db;
}
