// Builds the audio of a take replay as two stems the engine plays together:
// the backing track the singer heard (pitch-shifted by the same key change)
// and the recorded voice placed on the track timeline (take time + offset =
// track time). The engine mixes the voice in through the hall reverb while
// it plays, so the reverb switch and mix apply at once. Cached in the take
// folder; take.wav itself always stays dry.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import 'sidecars.dart';

/// The two files a replay plays; [voice] is null for a replay shared
/// without its recording.
class ReplayStems {
  const ReplayStems(this.backing, this.voice);
  final String backing;
  final String? voice;
}

/// Levels (music, voice) of a replay balance in -1..1: 0 plays both as
/// mixed; moving right fades the music out (equal-power curve, -3 dB half
/// way, silent at +1) and moving left fades the voice the same way.
(double, double) replayStemGains(double balance) {
  final b = balance.clamp(-1.0, 1.0);
  double fade(double x) => math.cos(x * math.pi / 2);
  return (b > 0 ? fade(b) : 1.0, b < 0 ? fade(-b) : 1.0);
}

/// 2: the cache records which backing file it was made from.
const _stemsVersion = 2;

String _backingPath(String takeDir) => p.join(takeDir, 'replay_backing.wav');
String _voicePath(String takeDir) => p.join(takeDir, 'replay_voice.wav');
String _metaPath(String takeDir) => p.join(takeDir, 'replay_stems.json');

/// Removes the cached replay audio (also the single-file mix of older
/// versions), e.g. when a replay is linked to another song.
Future<void> deleteReplayCache(String takeDir) async {
  for (final f in [
    _backingPath(takeDir),
    _voicePath(takeDir),
    _metaPath(takeDir),
    p.join(takeDir, 'replay.wav'),
    p.join(takeDir, 'replay.wav.json'),
  ]) {
    try {
      final file = File(f);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

/// Creates (or reuses) the replay stems. [offsetSeconds] maps take time to
/// track time; [pitchShift] is in semitones (the key the take was sung in).
Future<ReplayStems> ensureReplayStems(
  Sidecars sidecars, {
  required String takeDir,
  required String? voiceWav,
  required String backingWav,
  required double offsetSeconds,
  double pitchShift = 0,
  double voiceGain = 1.0,
  double backingGain = 0.8,
}) async {
  final backOut = _backingPath(takeDir), voiceOut = _voicePath(takeDir);
  final hasVoice = voiceWav != null && await File(voiceWav).exists();
  final source = await _backingStamp(backingWav);
  if (await replayStemsCached(takeDir, hasVoice: hasVoice, backingWav: backingWav)) {
    return ReplayStems(backOut, hasVoice ? voiceOut : null);
  }
  await deleteReplayCache(takeDir);
  final ff = await sidecars.resolve(SidecarKind.ffmpeg);
  if (ff == null) throw StateError('ffmpeg not available');

  final backing = <String>['aresample=44100'];
  if (pitchShift.abs() > 1e-3) {
    // Pitch without tempo change: speed up by r, then stretch back by 1/r.
    final r = math.pow(2, pitchShift / 12).toDouble();
    backing.addAll(['asetrate=${(44100 * r).toStringAsFixed(3)}', 'aresample=44100', 'atempo=${(1 / r).toStringAsFixed(6)}']);
  }
  backing.add('volume=${backingGain.toStringAsFixed(3)}');
  await _render(sidecars, ff, backingWav, backing, 'pcm_s16le', backOut);

  if (hasVoice) {
    // Microphone recordings are usually far quieter than the track: bring the
    // voice to about 2 dB under the backing's average level (at most +24 dB).
    final voiceDb = await _meanVolumeDb(sidecars, ff, voiceWav);
    final backDb = await _meanVolumeDb(sidecars, ff, backingWav);
    if (voiceDb != null && backDb != null) {
      final boostDb = (backDb + 20 * math.log(backingGain) / math.ln10 - 2 - voiceDb).clamp(0.0, 24.0);
      voiceGain *= math.pow(10, boostDb / 20).toDouble();
    }
    final voice = <String>['aformat=channel_layouts=mono', 'aresample=44100'];
    if (offsetSeconds > 0) {
      voice.add('adelay=${(offsetSeconds * 1000).round()}:all=1');
    } else if (offsetSeconds < 0) {
      voice.addAll(['atrim=start=${(-offsetSeconds).toStringAsFixed(4)}', 'asetpts=PTS-STARTPTS']);
    }
    voice.add('volume=${voiceGain.toStringAsFixed(3)}');
    // Float, so the boost cannot clip before the engine's limiter.
    await _render(sidecars, ff, voiceWav, voice, 'pcm_f32le', voiceOut);
  }
  await File(_metaPath(takeDir)).writeAsString(jsonEncode({'v': _stemsVersion, 'voice': hasVoice, 'backing': source}));
  return ReplayStems(backOut, hasVoice ? voiceOut : null);
}

/// Which backing file a cache was made from: a different file (an imported
/// backing track, or going back to the separated one) or the same file
/// written again means the replay must be mixed again.
Future<Map<String, Object>> _backingStamp(String path) async {
  final st = await File(path).stat();
  return {'path': p.normalize(path), 'size': st.size, 'modified': st.modified.millisecondsSinceEpoch};
}

/// Whether the replay stems in [takeDir] can be reused for [backingWav].
Future<bool> replayStemsCached(String takeDir, {required bool hasVoice, required String backingWav}) async {
  try {
    final meta = jsonDecode(await File(_metaPath(takeDir)).readAsString()) as Map;
    if (meta['v'] != _stemsVersion || meta['voice'] != hasVoice) return false;
    final made = meta['backing'];
    final now = await _backingStamp(backingWav);
    if (made is! Map || made['path'] != now['path'] || made['size'] != now['size'] || made['modified'] != now['modified']) return false;
    for (final f in [_backingPath(takeDir), if (hasVoice) _voicePath(takeDir)]) {
      final file = File(f);
      if (!await file.exists() || await file.length() <= 1024) return false;
    }
    return true;
  } catch (_) {
    return false;
  }
}

Future<void> _render(Sidecars sidecars, String ff, String input, List<String> filters, String codec, String out) async {
  final tmp = '$out.part.wav';
  final code = await sidecars.run(ff, ['-y', '-hide_banner', '-nostdin', '-i', input, '-af', filters.join(','), '-c:a', codec, tmp]);
  if (code != 0) {
    final f = File(tmp);
    if (await f.exists()) await f.delete();
    throw StateError('ffmpeg replay stem exited with $code');
  }
  await File(tmp).rename(out);
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
