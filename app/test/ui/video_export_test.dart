// Renders a short replay video from synthetic data through the real ffmpeg
// (skipped when ffmpeg is not installed).
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/services/app_paths.dart';
import 'package:karaoke_battle/services/replay_mix.dart';
import 'package:karaoke_battle/services/sidecars.dart';
import 'package:karaoke_battle/state/song_data.dart';
import 'package:karaoke_battle/state/take_trace.dart';
import 'package:karaoke_battle/ui/results/replay_data.dart';
import 'package:karaoke_battle/ui/results/video_export.dart';

void writeSine(String path, double hz, double seconds, {int sr = 44100}) {
  final n = (seconds * sr).round();
  final b = BytesBuilder();
  void u32(int v) => b.add([v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255]);
  void u16(int v) => b.add([v & 255, (v >> 8) & 255]);
  b.add('RIFF'.codeUnits);
  u32(36 + n * 2);
  b.add('WAVEfmt '.codeUnits);
  u32(16);
  u16(1);
  u16(1);
  u32(sr);
  u32(sr * 2);
  u16(2);
  u16(16);
  b.add('data'.codeUnits);
  u32(n * 2);
  for (var i = 0; i < n; i++) {
    u16((0.3 * math.sin(2 * math.pi * hz * i / sr) * 32767).round() & 0xffff);
  }
  File(path).writeAsBytesSync(b.toBytes());
}

void main() {
  late Directory tmp;
  late Sidecars sidecars;
  String? ff;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('video_export');
    sidecars = Sidecars(AppPaths.forTest(tmp.path), SidecarCatalog({}));
  });
  tearDown(() => tmp.delete(recursive: true));

  Future<ReplayData> data() async {
    writeSine('${tmp.path}/backing.wav', 220, 3);
    writeSine('${tmp.path}/take.wav', 330, 2);
    final notes = NoteList(Float64List.fromList([0.2, 1.0]), Float64List.fromList([0.9, 1.8]), Float64List.fromList([57, 64]));
    final times = Float64List.fromList([for (var i = 0; i < 200; i++) i * 0.01]);
    final f0 = F0Curve(times, Float64List.fromList([for (var i = 0; i < 200; i++) i < 100 ? 57.0 : 64.0]), Float64List(200)..fillRange(0, 200, 1));
    final stems = await ensureReplayStems(sidecars,
        takeDir: tmp.path, voiceWav: '${tmp.path}/take.wav', backingWav: '${tmp.path}/backing.wav', offsetSeconds: 0);
    return ReplayData(
      notes: notes,
      refF0: f0,
      trace: buildTakeTrace(notes, f0, shift: 0, pitchShift: 0),
      lyrics: null,
      score: null,
      judgements: const [],
      pitchShift: 0,
      stems: stems,
      takeSeconds: 1.5,
    );
  }

  testWidgets('a take becomes a 1080p H.264 + AAC video with the score card', (tester) async {
    await tester.runAsync(() async {
      ff = await sidecars.resolve(SidecarKind.ffmpeg);
      if (ff == null) return markTestSkipped('ffmpeg not installed');
      final d = await data();
      final out = '${tmp.path}/out.mp4';
      final seen = <String>{};
      await renderReplayVideo(
        ffmpeg: ff!,
        data: d,
        title: 'Test',
        trackSeconds: 3,
        videoPath: null,
        voicePath: d.stems.voice,
        musicGain: 1,
        voiceGain: 1,
        theme: ThemeData.dark(),
        view: tester.view,
        workDir: tmp.path,
        outPath: out,
        onProgress: (_, s) => seen.add(s),
      );
      expect(seen, containsAll(['video.rendering', 'video.saving']));
      final probe = await Process.run(ff!.replaceFirst(RegExp(r'ffmpeg(\.exe)?$'), 'ffprobe'), [
        '-v', 'error', '-show_entries', 'stream=codec_name,width,height:format=duration', '-of', 'csv=p=0', out,
      ]);
      final info = probe.stdout.toString();
      expect(info, contains('h264,1920,1080'));
      expect(info, contains('aac'));
      // 1.5 s take + 1 s breath, capped at the 3 s track... plus the 4 s score card.
      final secs = double.parse(RegExp(r'^([0-9.]+)\s*$', multiLine: true).firstMatch(info)!.group(1)!);
      expect(secs, closeTo(2.5 + scoreCardSeconds, 0.2));
    });
  });

  testWidgets('cancelling stops the render and writes nothing', (tester) async {
    await tester.runAsync(() async {
      ff = await sidecars.resolve(SidecarKind.ffmpeg);
      if (ff == null) return markTestSkipped('ffmpeg not installed');
      final d = await data();
      final out = '${tmp.path}/cancelled.mp4';
      final cancel = Completer<void>();
      Object? error;
      try {
        await renderReplayVideo(
          ffmpeg: ff!,
          data: d,
          title: 'Test',
          trackSeconds: 3,
          videoPath: null,
          voicePath: d.stems.voice,
          musicGain: 1,
          voiceGain: 1,
          theme: ThemeData.dark(),
          view: tester.view,
          workDir: tmp.path,
          outPath: out,
          cancel: cancel.future,
          onProgress: (f, _) {
            if (f > 0.1 && !cancel.isCompleted) cancel.complete();
          },
        );
      } catch (e) {
        error = e;
      }
      expect(error, isA<VideoExportCancelled>());
      expect(File(out).existsSync(), isFalse);
    });
  });
}
