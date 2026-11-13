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
import 'dart:math' as math;
import 'dart:typed_data';

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

  test('replay voice track: the reverb switch applies while it plays', () async {
    // Silent backing, and a voice with two short 440 Hz bursts. The onset
    // frames carry the level the engine was playing, so the reverb tail
    // shows there: none after the first burst (reverb off), a tail after the
    // second (switched on during playback).
    final dir = Directory.systemTemp.createTempSync('ke_voice_');
    const sr = 48000;
    void wav(String path, double Function(double t) f, double seconds) {
      final n = (seconds * sr).round();
      final b = BytesBuilder();
      void u32(int v) => b.add([v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255]);
      void u16(int v) => b.add([v & 255, (v >> 8) & 255]);
      b.add(ascii.encode('RIFF'));
      u32(36 + n * 2);
      b.add(ascii.encode('WAVEfmt '));
      u32(16); u16(1); u16(1); u32(sr); u32(sr * 2); u16(2); u16(16);
      b.add(ascii.encode('data'));
      u32(n * 2);
      for (var i = 0; i < n; i++) {
        u16((f(i / sr).clamp(-1.0, 1.0) * 32767).round() & 0xffff);
      }
      File(path).writeAsBytesSync(b.toBytes());
    }

    final backing = p.join(dir.path, 'backing.wav'), voice = p.join(dir.path, 'voice.wav');
    wav(backing, (_) => 0, 3.0);
    bool burst(double t) => (t >= 0.3 && t < 0.5) || (t >= 1.8 && t < 2.0);
    wav(voice, (t) => burst(t) ? 0.5 * math.sin(2 * math.pi * 440 * t) : 0, 3.0);

    final live = LiveAudio.create(Engine.instance, sampleRate: sr);
    try {
      live.loadTrack(backing, voice: voice);
      live.volume = 0.05;
      live.setReverb(false, 1.0);
      live.startCapture(mode: 0);
      live.play();
      final frames = <PitchFrame>[];
      final until = DateTime.now().add(const Duration(milliseconds: 2700));
      var switched = false;
      while (DateTime.now().isBefore(until)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        frames.addAll(live.readFrames().where((f) => f.source == 2));
        if (!switched && live.position > 1.2) {
          live.setReverb(true, 1.0);
          switched = true;
        }
      }
      live.pause();
      double loudest(double from, double to) =>
          frames.where((f) => f.time >= from && f.time < to).fold(-200.0, (m, f) => math.max(m, f.confidence));
      expect(loudest(0.3, 0.5), greaterThan(-50), reason: 'the voice plays');
      expect(loudest(0.8, 1.1), lessThan(-120), reason: 'reverb off: silence after the burst');
      expect(loudest(2.3, 2.6), greaterThan(-90), reason: 'reverb switched on while playing: a tail after the burst');
      // The balance: with the voice faded out the bursts are gone.
      live.setReverb(false, 1.0);
      live.setStemGains(1, 0);
      // Paused long enough that the level window no longer reaches the tail.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      live.readFrames();
      frames.clear();
      live.seek(0.2);
      live.play();
      final until2 = DateTime.now().add(const Duration(milliseconds: 500));
      while (DateTime.now().isBefore(until2)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        frames.addAll(live.readFrames().where((f) => f.source == 2));
      }
      live.pause();
      // (0.4 s on: the level window reaches ~150 ms back, to the first block
      // after the seek, where the reverb's old tail fades out.)
      expect(loudest(0.4, 0.5), lessThan(-120), reason: 'voice level 0: the burst is silent');
      live.stopCapture();
    } finally {
      live.dispose();
      dir.deleteSync(recursive: true);
    }
  }, skip: available ? false : 'engine not built');

  test('monitor capture: pitch frames without keeping the audio', () async {
    final live = LiveAudio.create(Engine.instance, sampleRate: 48000);
    try {
      live.startCapture(mode: 0, monitor: true);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final frames = live.readFrames();
      expect(frames.where((f) => f.source == 0), isNotEmpty, reason: 'MPM frames flow');
      live.stopCapture();
      final dir = Directory.systemTemp.createTempSync('ke_monitor_');
      final wav = p.join(dir.path, 'm.wav');
      try {
        live.saveCapture(wav);
      } catch (_) {}
      // Nothing was kept: no file, or an empty one.
      expect(!File(wav).existsSync() || File(wav).lengthSync() < 1024, isTrue);
      dir.deleteSync(recursive: true);
      // A normal capture still works afterwards.
      live.startCapture(mode: 0);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      live.stopCapture();
    } finally {
      live.dispose();
    }
  }, skip: available ? false : 'engine not built');

  test('latency can be measured again on a device that is already open', () async {
    final live = LiveAudio.create(Engine.instance, sampleRate: 48000);
    try {
      double? sec;
      try {
        sec = await live.calibrateOnThisDevice();
      } on EngineException catch (e) {
        // No mic hearing the speakers here: a clean failure is fine too.
        expect(e.message, contains('ke_audio_calibrate_latency'));
      }
      if (sec != null) expect(sec, inInclusiveRange(0.0, 0.5));
      // The device still works afterwards.
      live.startCapture(mode: 0, monitor: true);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      live.stopCapture();
    } finally {
      live.dispose();
    }
  }, skip: available ? false : 'engine not built');
}
