// Exercises the real native engine through the Dart bindings. Needs the engine
// built in engine/build and the ORT library present; skipped otherwise.
//
//   KE_TEST_SONG=/path/to/song_dir flutter test test/engine
//
// song_dir must contain vocals.wav and inst.wav (any prepared song folder).
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:karaoke_battle/engine/engine.dart';
import 'package:karaoke_battle/engine/engine_bindings.dart';
import 'package:path/path.dart' as p;

void main() {
  final songDir = Platform.environment['KE_TEST_SONG'];
  final swiftF0 = Platform.environment['KE_TEST_SWIFTF0'];
  final available = File(EngineLocator.engineLibraryPath()).existsSync() && File(EngineLocator.ortLibraryPath()).existsSync();

  test('engine loads, reports GPU and creates a CPU runtime', () {
    final e = Engine.instance;
    // The engine takes its version from pubspec.yaml at build time.
    final app = RegExp(r'^version:\s*(\d+\.\d+\.\d+)', multiLine: true).firstMatch(File('pubspec.yaml').readAsStringSync())!.group(1);
    expect(e.version, app, reason: 'rebuild the engine after changing the app version');
    expect(e.gpuInfo(), isNotEmpty);
    final rt = e.createRuntime(ortLibraryPath: EngineLocator.ortLibraryPath(), ep: KeEp.cpu);
    expect(rt.info()['ort_version'], isNotEmpty);
    expect(rt.selftest(), 0.0);
    rt.dispose();
  }, skip: available ? false : 'engine not built');

  test('f0Extract job runs in an isolate with progress', () async {
    final e = Engine.instance;
    final rt = e.createRuntime(ortLibraryPath: EngineLocator.ortLibraryPath(), ep: KeEp.cpu);
    final out = p.join(Directory.systemTemp.path, 'ke_test_f0.json');
    final job = rt.f0Extract(modelPath: swiftF0!, inputWav: p.join(songDir!, 'vocals.wav'), f0Out: out);
    var ticks = 0;
    job.progress.listen((_) => ticks++);
    await job.done;
    final j = jsonDecode(File(out).readAsStringSync()) as Map<String, dynamic>;
    expect((j['f0'] as List).length, greaterThan(100));
    expect(ticks, greaterThan(0));
    rt.dispose();
  }, skip: (available && songDir != null && swiftF0 != null) ? false : 'KE_TEST_SONG / KE_TEST_SWIFTF0 not set');

  test('live audio: track playback clock advances, capture produces a take', () async {
    final e = Engine.instance;
    final devices = e.audioDevices();
    expect(devices['playback'], isNotNull);
    final live = LiveAudio.create(e, sampleRate: 48000);
    try {
      live.loadTrack(p.join(songDir!, 'inst.wav'));
      expect(live.trackDuration, greaterThan(5));
      live.volume = 0.05;
      live.startCapture(mode: 0); // DSP pitch only, no model
      live.play();
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final pos = live.position;
      expect(live.isPlaying, isTrue);
      expect(pos, greaterThan(1.0));
      expect(pos, lessThan(2.5));
      live.pitchShift = 2;
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final frames = live.readFrames();
      live.pause();
      expect(live.isPlaying, isFalse);
      live.stopCapture();
      final take = p.join(Directory.systemTemp.path, 'ke_test_take.wav');
      live.saveCapture(take);
      expect(File(take).existsSync(), isTrue);
      expect(File('$take.json').existsSync(), isTrue);
      // Pitch frames may be empty on a machine without a microphone signal, but when present they are well formed.
      for (final f in frames) {
        expect(f.source, anyOf(0, 1, 2));
        if (f.source == 2) {
          expect(f.f0, anyOf(0.0, 1.0), reason: 'onset frames carry 1 at an onset, else 0');
        } else {
          expect(f.confidence, inInclusiveRange(0, 1));
        }
      }
      expect(frames.where((f) => f.source == 2), isNotEmpty, reason: 'onset frames come every 5 ms while capturing');
      // ignore: avoid_print
      print('live test: position=$pos frames=${frames.length} latency=${live.latency()}');
    } finally {
      live.dispose();
    }
  }, skip: (available && songDir != null) ? false : 'KE_TEST_SONG not set');
}
