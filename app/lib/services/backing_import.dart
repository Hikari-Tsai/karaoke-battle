// Importing your own backing track (an official instrumental or a karaoke
// track) to stand in for the separated accompaniment.
//
//   analyze: decode the file to WAV, align it with the song (the engine's
//            ke_align_backing_wav, against the separated accompaniment);
//   preview: a few seconds around a point, as the separated vocals over the
//            backing (sounds like the song when aligned) or the mix minus
//            the backing (the music cancels when aligned);
//   apply:   write inst.user.wav, the backing moved by the delay and cut or
//            padded to the song's length; the app then plays it wherever the
//            accompaniment played (SongFiles.backingWav);
//   revert:  delete it, back to the separated accompaniment.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../engine/engine.dart';
import '../state/loudness.dart';
import 'app_paths.dart';
import 'prep_pipeline.dart';
import 'sidecars.dart';
import 'song_library.dart';

/// The engine's alignment result.
class BackingAlignment {
  const BackingAlignment({
    required this.verdict,
    required this.delay,
    required this.confidence,
    this.driftPpm = 0,
    this.spreadMs = 0,
    this.cancelDb = 0,
    this.gain = 1,
    this.keyShift = 0,
    this.keyMargin = 0,
    this.bandSpreadMs = 0,
    this.bandWarning = false,
    this.mixSeconds = 0,
    this.backingSeconds = 0,
  });

  /// `aligned` (same version), `drift` (a speed difference) or `mismatch`.
  final String verdict;

  /// Seconds to move the backing so it lines up: positive = pad its start
  /// with silence, negative = cut that much from its start.
  final double delay;
  final double confidence;
  final double driftPpm;
  final double spreadMs;
  final double cancelDb;

  /// Least-squares gain of the backing against the reference (negative when
  /// its polarity is inverted).
  final double gain;

  /// The backing is this many semitones above the song (reliable when
  /// [keyMargin] is clear).
  final int keyShift;
  final double keyMargin;

  /// Bands (bass, mids, highs) whose offsets disagree by this much; above
  /// 2 ms [bandWarning] is set (the two were mixed differently).
  final double bandSpreadMs;
  final bool bandWarning;
  final double mixSeconds, backingSeconds;

  bool get aligned => verdict == 'aligned';
  bool get keyChanged => keyShift != 0 && keyMargin >= 0.1;

  factory BackingAlignment.fromJson(Map<String, dynamic> j) {
    double d(String k) => (j[k] as num?)?.toDouble() ?? 0;
    return BackingAlignment(
      verdict: j['verdict'] as String? ?? 'mismatch',
      delay: d('delay'),
      confidence: d('confidence'),
      driftPpm: d('drift_ppm'),
      spreadMs: d('spread_ms'),
      cancelDb: d('cancel_db'),
      gain: (j['gain'] as num?)?.toDouble() ?? 1,
      keyShift: (j['key_shift'] as num?)?.toInt() ?? 0,
      keyMargin: d('key_margin'),
      bandSpreadMs: d('band_spread_ms'),
      bandWarning: j['band_warning'] == true,
      mixSeconds: d('mix_seconds'),
      backingSeconds: d('backing_seconds'),
    );
  }
}

/// What a preview plays.
enum BackingPreview {
  /// The separated vocals over the backing: sounds like the song when aligned.
  vocals,

  /// The original mix minus the backing: the music cancels when aligned.
  cancel,
}

/// Envelopes (RMS, 100 per second) for the alignment view.
class BackingEnvelopes {
  const BackingEnvelopes(this.reference, this.backing);
  final Float32List reference, backing;
  static const rate = 100;
}

class BackingImport {
  BackingImport({required this.library, required this.sidecars, required this.engine, required this.paths, required this.pipeline});

  final SongLibrary library;
  final Sidecars sidecars;
  final Engine engine;
  final AppPaths paths;
  final PrepPipeline pipeline;

  static const sampleRate = 44100;

  String _cache(Song song, String name) => p.join(paths.cache, 'backing_${song.id}_$name');

  /// The track to align against: the separated accompaniment when there is
  /// one (no vocal onsets to blur the match), else the original mix.
  String reference(SongFiles f) => File(f.instWav).existsSync() ? f.instWav : f.mixWav;

  /// Decodes [source] and aligns it with the song. Returns the decoded WAV
  /// (in the cache; pass it to [apply], [preview], [envelopes]) and the result.
  Future<(String, BackingAlignment)> analyze(Song song, String source, {void Function(double fraction, String stage)? onProgress}) async {
    final f = library.files(song);
    await Directory(paths.cache).create(recursive: true);
    final wav = _cache(song, 'source.wav'), json = _cache(song, 'align.json');
    onProgress?.call(0, 'decode');
    await sidecars.toWav(source, wav, sampleRate: sampleRate, onProgress: (x) => onProgress?.call(0.6 * x, 'decode'));
    onProgress?.call(0.6, 'align');
    await engine.alignBacking(reference: reference(f), backing: wav, outJson: json);
    final a = BackingAlignment.fromJson(jsonDecode(await File(json).readAsString()) as Map<String, dynamic>);
    onProgress?.call(1, 'align');
    return (wav, a);
  }

  /// ffmpeg filter that moves a [sampleRate] stream by [delay] seconds:
  /// silence in front (positive) or its start cut (negative).
  static String shiftFilter(double delay) {
    final n = (delay.abs() * sampleRate).round();
    if (n == 0) return 'anull';
    return delay > 0 ? 'adelay=delays=${n}S:all=1' : 'atrim=start_sample=$n,asetpts=PTS-STARTPTS';
  }

  /// Writes inst.user.wav: [wav] moved by [delay] and cut or padded to the
  /// song's length, then measures its loudness for the automatic volume.
  Future<void> apply(Song song, String wav, double delay, {String? sourceName, BackingAlignment? alignment}) async {
    final f = library.files(song);
    final ff = await sidecars.resolve(SidecarKind.ffmpeg);
    if (ff == null) throw StateError('ffmpeg not available');
    final seconds = await sidecars.duration(f.mixWav) ?? song.durationSec;
    if (seconds == null || seconds <= 0) throw StateError('song length unknown');
    final end = (seconds * sampleRate).round();
    final tmp = '${f.userInstWav}.part.wav';
    final code = await sidecars.run(ff, [
      '-y', '-hide_banner', '-nostdin', '-i', wav, //
      '-af', '${shiftFilter(delay)},apad,atrim=end_sample=$end',
      '-ar', '$sampleRate', '-ac', '2', '-c:a', 'pcm_f32le', tmp,
    ]);
    if (code != 0) throw StateError('ffmpeg exited with $code');
    await File(tmp).rename(f.userInstWav);
    await File(f.userInstJson).writeAsString(const JsonEncoder.withIndent('  ').convert({
      'source': ?sourceName,
      'delay': delay,
      'verdict': ?alignment?.verdict,
      'confidence': ?alignment?.confidence,
      'imported_at': DateTime.now().toIso8601String(),
    }));
    await _remeasure(f, song);
  }

  /// Back to the separated accompaniment.
  Future<void> revert(Song song) async {
    final f = library.files(song);
    for (final path in [f.userInstWav, f.userInstJson]) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
    await _remeasure(f, song);
  }

  /// The accompaniment's loudness changed: forget it and measure again.
  Future<void> _remeasure(SongFiles f, Song song) async {
    final known = await SongLoudness.load(f.loudnessJson);
    await SongLoudness(mix: known?.mix).save(f.loudnessJson);
    await pipeline.ensureLoudness(song);
  }

  /// Renders [seconds] around song time [at] for listening ([mode]).
  /// [gain] scales the backing (the cancel mode needs it matched to the mix).
  Future<String> preview(Song song, String wav, double delay, double at, BackingPreview mode, {double seconds = 6, double gain = 1}) async {
    final f = library.files(song);
    final ff = await sidecars.resolve(SidecarKind.ffmpeg);
    if (ff == null) throw StateError('ffmpeg not available');
    final out = _cache(song, 'preview.wav');
    final start = math.max(0.0, at);
    final other = mode == BackingPreview.vocals ? f.vocalsWav : f.mixWav;
    // The backing's own time for song time `start`.
    final from = start - delay;
    final backingIn = from >= 0
        ? ['-ss', from.toStringAsFixed(4), '-t', seconds.toStringAsFixed(3), '-i', wav]
        : ['-t', math.max(0.0, seconds + from).toStringAsFixed(3), '-i', wav];
    final pad = from >= 0 ? 'anull' : 'adelay=delays=${(-from * sampleRate).round()}S:all=1';
    final g = mode == BackingPreview.cancel ? -gain : gain;
    if (from + seconds <= 0.05) {
      // The backing has not started yet here (it was padded): the other alone.
      final code = await sidecars.run(ff, ['-y', '-hide_banner', '-nostdin', '-ss', start.toStringAsFixed(4), '-t', seconds.toStringAsFixed(3), '-i', other, '-ac', '2', '-c:a', 'pcm_s16le', out]);
      if (code != 0) throw StateError('ffmpeg exited with $code');
      return out;
    }
    final code = await sidecars.run(ff, [
      '-y', '-hide_banner', '-nostdin', //
      '-ss', start.toStringAsFixed(4), '-t', seconds.toStringAsFixed(3), '-i', other,
      ...backingIn,
      '-filter_complex', '[1:a]aresample=$sampleRate,$pad,volume=${g.toStringAsFixed(4)}[b];[0:a]aresample=$sampleRate[a];[a][b]amix=inputs=2:normalize=0:duration=first',
      '-ac', '2', '-c:a', 'pcm_s16le', out,
    ]);
    if (code != 0) throw StateError('ffmpeg exited with $code');
    return out;
  }

  /// RMS envelopes of the reference and of [wav] (100 per second), for the
  /// alignment view.
  Future<BackingEnvelopes> envelopes(Song song, String wav) async {
    final f = library.files(song);
    final ff = await sidecars.resolve(SidecarKind.ffmpeg);
    if (ff == null) throw StateError('ffmpeg not available');
    Future<Float32List> env(String input, String name) async {
      final raw = _cache(song, name);
      final code = await sidecars.run(ff, ['-y', '-hide_banner', '-nostdin', '-i', input, '-ac', '1', '-ar', '8000', '-f', 'f32le', raw]);
      if (code != 0) throw StateError('ffmpeg exited with $code');
      final bytes = await File(raw).readAsBytes();
      await File(raw).delete();
      return _envelopeInIsolate(bytes);
    }

    return BackingEnvelopes(await env(reference(f), 'ref.f32'), await env(wav, 'backing.f32'));
  }

  /// A static helper, so the isolate's closure holds only the bytes (an
  /// instance method's closure would try to send this whole service).
  static Future<Float32List> _envelopeInIsolate(Uint8List bytes) =>
      Isolate.run(() => rmsEnvelope(bytes.buffer.asFloat32List(bytes.offsetInBytes, bytes.lengthInBytes ~/ 4), 80));

  /// RMS of every [hop] samples, in dB-like units scaled to 0..1 (-60 dB .. 0).
  static Float32List rmsEnvelope(Float32List x, int hop) {
    final n = x.length ~/ hop;
    final out = Float32List(n);
    for (var i = 0; i < n; i++) {
      var s = 0.0;
      for (var k = i * hop; k < (i + 1) * hop; k++) {
        s += x[k] * x[k];
      }
      final db = 10 * math.log(s / hop + 1e-12) / math.ln10;
      out[i] = ((db + 60) / 60).clamp(0.0, 1.0);
    }
    return out;
  }
}
