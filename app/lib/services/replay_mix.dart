// Builds the audio of a take replay: the recorded voice placed on the track
// timeline (take time + offset = track time) mixed over the backing track
// the singer heard, pitch-shifted by the same key change. With a reverb mix
// the voice is first rendered through the engine's hall reverb. Cached as
// replay.wav in the take folder (replay.wav.json records the reverb used);
// take.wav itself always stays dry.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import 'sidecars.dart';

String replayWavPath(String takeDir) => p.join(takeDir, 'replay.wav');

/// Renders a dry voice WAV into a stereo reverberated WAV.
typedef ReverbRenderer = Future<void> Function(String input, String output, double mix);

/// Creates (or reuses) the replay mix and returns its path.
/// [offsetSeconds] maps take time to track time; [pitchShift] is in
/// semitones (the key the take was sung in).
Future<String> ensureReplayMix(
  Sidecars sidecars, {
  required String takeDir,
  required String? voiceWav,
  required String backingWav,
  required double offsetSeconds,
  double pitchShift = 0,
  double voiceGain = 1.0,
  double backingGain = 0.8,
  double reverbMix = 0,
  ReverbRenderer? renderReverb,
}) async {
  final out = replayWavPath(takeDir);
  final hasVoice = voiceWav != null && await File(voiceWav).exists();
  // Reverb only matters when there is a voice to put it on.
  final reverbPct = hasVoice && renderReverb != null ? (reverbMix.clamp(0.0, 1.0) * 100).round() : 0;
  final meta = File('$out.json');
  if (await File(out).exists() && await File(out).length() > 1024 && await _cachedReverb(meta) == reverbPct) return out;
  final ff = await sidecars.resolve(SidecarKind.ffmpeg);
  if (ff == null) throw StateError('ffmpeg not available');

  var voicePath = voiceWav;
  var voiceStereo = false;
  if (reverbPct > 0) {
    voicePath = p.join(takeDir, 'voice_reverb.wav');
    await renderReverb!(voiceWav!, voicePath, reverbPct / 100);
    voiceStereo = true;
  }

  // Microphone recordings are usually far quieter than the track: bring the
  // voice to about 2 dB under the backing's average level (at most +24 dB).
  final voiceDb = hasVoice ? await _meanVolumeDb(sidecars, ff, voicePath!) : null;
  final backDb = hasVoice ? await _meanVolumeDb(sidecars, ff, backingWav) : null;
  if (voiceDb != null && backDb != null) {
    final boostDb = (backDb + 20 * math.log(backingGain) / math.ln10 - 2 - voiceDb).clamp(0.0, 24.0);
    voiceGain *= math.pow(10, boostDb / 20).toDouble();
  }

  final voice = voiceStereo
      ? <String>['[1:a]aformat=channel_layouts=stereo', 'aresample=44100']
      : <String>['[1:a]aformat=channel_layouts=mono', 'aresample=44100', 'pan=stereo|c0=c0|c1=c0'];
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

  // Without a voice (a replay shared without its recording) only the backing plays.
  final filter = hasVoice
      ? '${backing.join(',')};${voice.join(',')};[b][v]amix=inputs=2:duration=first:normalize=0,alimiter=limit=0.95[out]'
      : '${backing.join(',')};[b]anull[out]';
  final tmp = '$out.part.wav';
  final code = await sidecars.run(ff, [
    '-y', '-hide_banner', '-nostdin',
    '-i', backingWav,
    if (hasVoice) ...['-i', voicePath!],
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
  await meta.writeAsString(jsonEncode({'reverb_pct': reverbPct}));
  if (reverbPct > 0) {
    final f = File(voicePath!);
    if (await f.exists()) await f.delete();
  }
  return out;
}

/// Reverb (percent) the cached mix was built with; 0 for mixes made before
/// replay.wav.json existed (they were always dry).
Future<int> _cachedReverb(File meta) async {
  try {
    if (!await meta.exists()) return 0;
    return ((jsonDecode(await meta.readAsString()) as Map)['reverb_pct'] as num?)?.toInt() ?? 0;
  } catch (_) {
    return -1;
  }
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
