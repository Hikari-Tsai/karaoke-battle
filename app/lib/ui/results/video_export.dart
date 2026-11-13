// "Export video": renders a take's replay to an MP4 (1920x1080, 30 fps).
//
// The picture is the replay's stage drawn offscreen frame by frame on a
// fixed clock (scrolling notes, the sung pitch line, lyrics, judgement
// pop-ups, a title strip) and piped as raw RGBA into ffmpeg, which lays it
// over the song's video (or uses it as is on the dark roll background),
// mixes the backing and the voice (with the reverb and the MIX balance set
// for replays) and encodes H.264 + AAC, preferring the computer's hardware
// encoder. The last seconds show the score. Nothing is uploaded anywhere.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path/path.dart' as p;

import '../../services/replay_mix.dart';
import '../../services/sidecars.dart';
import '../../services/song_library.dart';
import '../../state/app_services.dart';
import '../../state/i18n.dart';
import '../sing/lyrics_overlay.dart';
import '../sing/piano_roll.dart';
import '../widgets/judgement_popups.dart';
import '../widgets/rank.dart';
import 'replay_data.dart';

class VideoExportCancelled implements Exception {}

/// Output size and rate. The stage is laid out at 1280x720 and drawn at
/// 1.5x, so it looks like the app at that window size, sharp at 1080p.
const exportWidth = 1920, exportHeight = 1080, exportFps = 30;
const _layoutScale = 1.5;

/// Seconds of score card after the take.
const scoreCardSeconds = 4.0;

/// Renders a widget tree offscreen, one frame at a time.
class _OffscreenStage {
  _OffscreenStage(Widget child, ui.FlutterView view) {
    final logical = Size(exportWidth / _layoutScale, exportHeight / _layoutScale);
    _renderView = RenderView(
      view: view,
      child: RenderPositionedBox(alignment: Alignment.center, child: _boundary),
      configuration: ViewConfiguration(
        logicalConstraints: BoxConstraints.tight(logical),
        physicalConstraints: BoxConstraints.tight(logical * _layoutScale),
        devicePixelRatio: _layoutScale,
      ),
    );
    _pipeline.rootNode = _renderView;
    _renderView.prepareInitialFrame();
    _root = RenderObjectToWidgetAdapter<RenderBox>(
      container: _boundary,
      child: MediaQuery(
        data: MediaQueryData(size: logical, devicePixelRatio: _layoutScale),
        child: Directionality(textDirection: TextDirection.ltr, child: child),
      ),
    ).attachToRenderTree(_build);
  }

  final _boundary = RenderRepaintBoundary();
  final _pipeline = PipelineOwner();
  final _build = BuildOwner(focusManager: FocusManager());
  late final RenderView _renderView;
  late final RenderObjectToWidgetElement<RenderBox> _root;

  /// Lays out and paints the current state; returns straight-alpha RGBA.
  Future<Uint8List> frame() async {
    _build.buildScope(_root);
    _build.finalizeTree();
    _pipeline.flushLayout();
    _pipeline.flushCompositingBits();
    _pipeline.flushPaint();
    final image = await _boundary.toImage(pixelRatio: _layoutScale);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      return data!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  void dispose() {
    _build.lockState(() => _root.update(RenderObjectToWidgetAdapter<RenderBox>(container: _boundary)));
    _build.finalizeTree();
  }
}

/// Picks the first H.264 encoder this ffmpeg can actually run (hardware
/// first; listed encoders may still fail without the hardware).
Future<List<String>> _videoEncoder(String ff) async {
  const candidates = <List<String>>[
    ['h264_videotoolbox', '-b:v', '10M', '-allow_sw', '1'],
    ['h264_nvenc', '-b:v', '10M'],
    ['h264_qsv', '-b:v', '10M'],
    ['h264_amf', '-b:v', '10M'],
    ['h264_mf', '-b:v', '10M'],
    ['libx264', '-preset', 'veryfast', '-crf', '20'],
    ['libopenh264', '-b:v', '10M'],
  ];
  final listed = (await Process.run(ff, ['-hide_banner', '-encoders'])).stdout.toString();
  for (final c in candidates) {
    if (!listed.contains(' ${c.first} ')) continue;
    final probe = await Process.run(ff, [
      '-hide_banner', '-v', 'error', '-f', 'lavfi', '-i', 'color=c=black:s=640x360:r=30:d=0.2',
      '-pix_fmt', 'yuv420p', '-c:v', ...c, '-f', 'null', '-',
    ]);
    if (probe.exitCode == 0) return ['-c:v', ...c];
  }
  throw StateError('No H.264 encoder available in ffmpeg');
}

/// Exports [take] of [song] to [outPath]. [onProgress] gets 0..1;
/// [cancel] completing stops it (throws [VideoExportCancelled]).
Future<void> exportTakeVideo({
  required AppServices services,
  required Song song,
  required TakeInfo take,
  required ThemeData theme,
  required ui.FlutterView view,
  required String outPath,
  String? player,
  void Function(double fraction, String stage)? onProgress,
  Future<void>? cancel,
}) async {
  var cancelled = false;
  cancel?.then((_) => cancelled = true);
  onProgress?.call(0, 'video.preparing');
  final ff = await services.sidecars.resolve(SidecarKind.ffmpeg);
  if (ff == null) throw StateError('ffmpeg not available');
  final d = await loadReplayData(services, song, take);
  if (cancelled) throw VideoExportCancelled();
  final files = services.library.files(song);
  final settings = services.settings;
  await Directory(services.paths.cache).create(recursive: true);
  final work = await Directory(services.paths.cache).createTemp('video_');
  try {
    // Voice with the replay's reverb (rendered offline, same hall).
    String? voice = d.stems.voice;
    if (voice != null && settings.reverbOn && settings.reverbMix > 0) {
      final wet = p.join(work.path, 'voice_reverb.wav');
      await services.engine.renderReverb(voice, wet, mix: settings.reverbMix, tailSeconds: 3);
      voice = wet;
    }
    if (cancelled) throw VideoExportCancelled();
    final (music, voiceGain) = replayStemGains(settings.replayBalance);
    final hasVideo = song.hasVideo && await File(files.videoMp4).exists();
    await renderReplayVideo(
      ffmpeg: ff,
      data: d,
      title: song.title,
      trackSeconds: song.durationSec,
      videoPath: hasVideo ? files.videoMp4 : null,
      voicePath: voice,
      musicGain: music,
      voiceGain: voiceGain,
      theme: theme,
      view: view,
      workDir: work.path,
      outPath: outPath,
      player: player,
      onProgress: onProgress,
      cancel: cancel,
    );
  } finally {
    try {
      await work.delete(recursive: true);
    } catch (_) {}
  }
}

/// Encodes the replay in [data] to [outPath] (see the header). [voicePath]
/// replaces the dry voice stem (e.g. with reverb); [maxSeconds] cuts the
/// take short (tests).
Future<void> renderReplayVideo({
  required String ffmpeg,
  required ReplayData data,
  required String title,
  required double? trackSeconds,
  required String? videoPath,
  required String? voicePath,
  required double musicGain,
  required double voiceGain,
  required ThemeData theme,
  required ui.FlutterView view,
  required String workDir,
  required String outPath,
  String? player,
  double? maxSeconds,
  void Function(double fraction, String stage)? onProgress,
  Future<void>? cancel,
}) async {
  var cancelled = false;
  cancel?.then((_) => cancelled = true);
  final ff = ffmpeg;
  final d = data;
  final voice = voicePath;
  final encoder = await _videoEncoder(ff);
  if (cancelled) throw VideoExportCancelled();

  // Length: the take (plus a breath), never past the track.
  final track = trackSeconds ?? (d.notes.endTime + 2);
  var sung = d.takeSeconds == null ? track : (d.takeSeconds! + 1.0).clamp(1.0, track);
  if (maxSeconds != null && sung > maxSeconds) sung = maxSeconds;
  final total = sung + scoreCardSeconds;
  final frames = (total * exportFps).ceil();

  final hasVideo = videoPath != null;
  final video = <String>[
    if (hasVideo) ...[
      '[1:v]scale=$exportWidth:$exportHeight:force_original_aspect_ratio=decrease,'
          'pad=$exportWidth:$exportHeight:(ow-iw)/2:(oh-ih)/2:black,setsar=1,fps=$exportFps,'
          'tpad=stop_mode=clone:stop_duration=${total.ceil() + 5}[bg]',
      '[bg][0:v]overlay=0:0:format=auto,format=yuv420p[v]',
    ] else
      '[0:v]format=yuv420p[v]',
  ];
  final a0 = hasVideo ? 2 : 1;
  final audio = voice == null
      ? '[$a0:a]volume=${musicGain.toStringAsFixed(3)},apad[a]'
      : '[$a0:a]volume=${musicGain.toStringAsFixed(3)},apad[m];[${a0 + 1}:a]volume=${voiceGain.toStringAsFixed(3)},apad[s];'
          '[m][s]amix=inputs=2:duration=longest:normalize=0,alimiter=limit=0.95[a]';
  // The music fades out under the score card.
  final fade = 'afade=t=out:st=${(sung + 0.5).toStringAsFixed(2)}:d=${(scoreCardSeconds - 0.5).toStringAsFixed(2)}';
  final audioOut = audio.replaceFirst(RegExp(r'\[a\]$'), ',$fade[a]');
  final tmpOut = p.join(workDir, 'out.mp4');
  final proc = await Process.start(ff, [
    '-y', '-hide_banner', '-nostdin', '-v', 'error',
    '-f', 'rawvideo', '-pix_fmt', 'rgba', '-s', '${exportWidth}x$exportHeight', '-framerate', '$exportFps', '-i', 'pipe:0',
    if (hasVideo) ...['-i', videoPath],
    '-i', d.stems.backing,
    if (voice != null) ...['-i', voice],
    '-filter_complex', [...video, audioOut].join(';'),
    '-map', '[v]', '-map', '[a]',
    ...encoder,
    '-c:a', 'aac', '-b:a', '192k',
    '-t', total.toStringAsFixed(3),
    '-movflags', '+faststart',
    tmpOut,
  ]);
  final errors = StringBuffer();
  final errDone = proc.stderr.transform(const SystemEncoding().decoder).forEach(errors.write);
  final outDone = proc.stdout.drain<void>();
  var finished = false;
  try {
    // The stage, driven by a fixed clock.
    final position = ValueNotifier<double>(0);
    final ending = ValueNotifier<double>(0);
    final stage = _OffscreenStage(
      Theme(
        data: theme,
        child: _ExportStage(title: title, data: d, position: position, ending: ending, hasVideo: hasVideo, player: player),
      ),
      view,
    );
    try {
      for (var f = 0; f < frames; f++) {
        if (cancelled) throw VideoExportCancelled();
        final t = f / exportFps;
        position.value = t < sung ? t : sung;
        ending.value = ((t - sung) / 0.6).clamp(0.0, 1.0);
        proc.stdin.add(await stage.frame());
        await proc.stdin.flush();
        if (f % 10 == 0) onProgress?.call(f / frames, 'video.rendering');
      }
    } finally {
      stage.dispose();
      position.dispose();
      ending.dispose();
    }
    await proc.stdin.close();
    final code = await proc.exitCode;
    finished = true;
    await outDone;
    await errDone;
    if (code != 0) throw StateError('ffmpeg exited with $code: ${errors.toString().trim()}');
    onProgress?.call(1, 'video.saving');
    await File(tmpOut).copy(outPath);
  } catch (_) {
    if (!finished) Sidecars.killTree(proc);
    if (cancelled) throw VideoExportCancelled();
    rethrow;
  }
}

/// The exported picture: the replay stage, a title strip, the score card.
class _ExportStage extends StatelessWidget {
  const _ExportStage({
    required this.title,
    required this.data,
    required this.position,
    required this.ending,
    required this.hasVideo,
    this.player,
  });
  final String title;
  final ReplayData data;
  final ValueNotifier<double> position;
  final ValueNotifier<double> ending;
  final bool hasVideo;
  final String? player;

  @override
  Widget build(BuildContext context) {
    final range = pitchRangeFor(data.notes, data.pitchShift);
    final score = data.score;
    const shadow = [Shadow(color: Colors.black, blurRadius: 6)];
    return Stack(fit: StackFit.expand, children: [
      PianoRollView(
        notes: data.notes,
        refF0: data.refF0,
        trace: data.trace,
        minMidi: range.min,
        maxMidi: range.max,
        position: position,
        pitchShift: data.pitchShift,
        overlay: hasVideo,
        traceUntilPlayhead: true,
      ),
      if (data.lyrics != null)
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: LyricsOverlay(lyrics: data.lyrics!, position: position, noteOnsets: data.notes.onset, noteOffsets: data.notes.offset),
        ),
      JudgementLayer(position: position, marks: data.judgements, minMidi: range.min, maxMidi: range.max),
      // Title strip.
      Positioned(
        left: 16,
        top: 12,
        right: 16,
        child: Text(
          [title, if ((player ?? '').isNotEmpty) player].join('  ·  '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700, shadows: shadow),
        ),
      ),
      // Score card at the end.
      ValueListenableBuilder<double>(
        valueListenable: ending,
        builder: (context, e, _) => e <= 0 || score == null
            ? const SizedBox.shrink()
            : Opacity(
                opacity: e,
                child: ColoredBox(
                  color: const Color(0xCC000000),
                  child: Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(title, style: const TextStyle(color: Colors.white70, fontSize: 22, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 12),
                      Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(
                          score.total.toStringAsFixed(1),
                          style: TextStyle(color: rankColor(score.rank), fontSize: 96, fontWeight: FontWeight.w900, shadows: shadow),
                        ),
                        const SizedBox(width: 20),
                        RankChip(rank: score.rank, fontSize: 40),
                      ]),
                      const SizedBox(height: 10),
                      Text(tr('video.cardFooter'), style: const TextStyle(color: Colors.white54, fontSize: 14)),
                    ]),
                  ),
                ),
              ),
      ),
    ]);
  }
}
