// High level, async-friendly wrapper around the native engine.
//
// * Library location is resolved per platform (bundle vs. dev tree).
// * Long jobs (separate / transcribe / f0) run in a worker isolate so the UI
//   never blocks; progress arrives on a Stream and jobs are cancellable.
// * The live audio object is driven from the UI isolate (all calls are cheap).
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'engine_bindings.dart';

class EngineException implements Exception {
  EngineException(this.code, this.message);
  final int code;
  final String message;
  bool get cancelled => code == KeError.cancelled;
  @override
  String toString() => 'EngineException($code): $message';
}

class JobProgress {
  const JobProgress(this.fraction, this.stage);
  final double fraction;
  final String stage;
}

/// Handle for a running job: progress stream + cancellation + completion.
class EngineJob {
  EngineJob._(this.progress, this._cancelFlag, this.done);
  final Stream<JobProgress> progress;
  final Pointer<Int32> _cancelFlag;
  final Future<void> done;
  void cancel() => _cancelFlag.value = 1;
}

/// Resolves where the engine and ONNX Runtime libraries live.
class EngineLocator {
  EngineLocator._();

  static String? _override(String key) {
    final v = Platform.environment[key];
    return (v != null && v.isNotEmpty) ? v : null;
  }

  /// Directory of the running executable's bundle resources.
  static String get executableDir => p.dirname(Platform.resolvedExecutable);

  /// Repository root when running from `flutter run` in app/ (dev only).
  static String? get devRepoRoot {
    var dir = Directory.current.path;
    for (var i = 0; i < 4; i++) {
      if (File(p.join(dir, 'engine', 'CMakeLists.txt')).existsSync()) return dir;
      dir = p.dirname(dir);
    }
    return null;
  }

  static String engineLibraryPath() {
    final o = _override('KE_ENGINE_LIB');
    if (o != null) return o;
    if (Platform.isMacOS) {
      final bundled = p.join(executableDir, '..', 'Frameworks', 'libkaraoke_engine.dylib');
      if (File(bundled).existsSync()) return p.normalize(bundled);
      final root = devRepoRoot;
      if (root != null) {
        for (final b in ['build', 'build-audio', 'build-game', 'build-mdx']) {
          final f = p.join(root, 'engine', b, 'libkaraoke_engine.dylib');
          if (File(f).existsSync()) return f;
        }
      }
      return p.normalize(bundled);
    }
    if (Platform.isWindows) {
      final bundled = p.join(executableDir, 'karaoke_engine.dll');
      if (File(bundled).existsSync()) return bundled;
      final root = devRepoRoot;
      if (root != null) {
        for (final b in ['build/Release', 'build']) {
          final f = p.join(root, 'engine', b, 'karaoke_engine.dll');
          if (File(f).existsSync()) return f;
        }
      }
      return bundled;
    }
    return p.join(executableDir, 'libkaraoke_engine.so');
  }

  /// Base (always shipped) ONNX Runtime library.
  static String ortLibraryPath() {
    final o = _override('KE_ORT_LIB');
    if (o != null) return o;
    if (Platform.isMacOS) {
      final fw = p.normalize(p.join(executableDir, '..', 'Frameworks'));
      for (final n in ['libonnxruntime.1.23.2.dylib', 'libonnxruntime.dylib']) {
        final f = p.join(fw, n);
        if (File(f).existsSync()) return f;
      }
      final root = devRepoRoot;
      if (root != null) {
        final f = p.join(root, 'engine', 'third_party', 'onnxruntime', 'osx-universal2', 'lib', 'libonnxruntime.dylib');
        if (File(f).existsSync()) return f;
      }
      return p.join(fw, 'libonnxruntime.dylib');
    }
    if (Platform.isWindows) {
      final bundled = p.join(executableDir, 'onnxruntime.dll');
      if (File(bundled).existsSync()) return bundled;
      final root = devRepoRoot;
      if (root != null) {
        final f = p.join(root, 'engine', 'third_party', 'onnxruntime', 'win-x64', 'lib', 'onnxruntime.dll');
        if (File(f).existsSync()) return f;
      }
      return bundled;
    }
    return p.join(executableDir, 'libonnxruntime.so');
  }
}

/// Process-wide engine access.
class Engine {
  Engine._(this.bindings, this.libraryPath);

  static Engine? _instance;
  static Engine get instance => _instance ??= _load();

  static Engine _load() {
    final path = EngineLocator.engineLibraryPath();
    final lib = DynamicLibrary.open(path);
    final b = EngineBindings(lib);
    final e = Engine._(b, path);
    e._installLogger();
    return e;
  }

  final EngineBindings bindings;
  final String libraryPath;
  final _log = StreamController<String>.broadcast();
  Stream<String> get logs => _log.stream;
  final List<String> recentLogs = [];
  Timer? _logTimer;

  String get version => bindings.version().toDartString();

  /// Renders [input] through the hall reverb into a stereo WAV at [output]
  /// ([mix] 0 = dry, 1 = reverb only; [tailSeconds] of tail appended).
  /// Runs on a worker isolate.
  Future<void> renderReverb(String input, String output, {required double mix, double tailSeconds = 4}) async {
    final r = await _spawnReverb(libraryPath, input, output, mix.clamp(0.0, 1.0), tailSeconds);
    if (r.code != KeError.ok) throw EngineException(r.code, r.message);
  }

  // Engine threads append log lines to a queue inside the library; we poll it.
  // (A NativeCallable.listener cannot be used: the message pointer is only
  // valid during the synchronous call.)
  void _installLogger() {
    bindings.logSetQueue(1, 0);
    _logTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => drainLogs());
  }

  void drainLogs() {
    final s = bindings.readString(bindings.logDrain);
    if (s.isEmpty) return;
    const names = ['D', 'I', 'W', 'E'];
    for (final line in const LineSplitter().convert(s)) {
      final tab = line.indexOf('\t');
      if (tab < 0) continue;
      final level = int.tryParse(line.substring(0, tab)) ?? 1;
      final text = '[${names[level & 3]}] ${line.substring(tab + 1)}';
      recentLogs.add(text);
      if (recentLogs.length > 2000) recentLogs.removeRange(0, recentLogs.length - 2000);
      if (_log.hasListener) _log.add(text);
    }
  }

  void dispose() {
    _logTimer?.cancel();
  }

  void _check(int rc, String what) {
    if (rc != KeError.ok) throw EngineException(rc, '$what: ${bindings.lastErrorString()}');
  }

  // ---- system ---------------------------------------------------------------

  List<Map<String, dynamic>> gpuInfo() {
    final s = bindings.readString(bindings.systemGpuInfoJson);
    return (jsonDecode(s) as List).cast<Map<String, dynamic>>();
  }

  Map<String, dynamic> audioDevices() {
    final s = bindings.readString(bindings.audioListDevicesJson);
    return jsonDecode(s) as Map<String, dynamic>;
  }

  // ---- runtime --------------------------------------------------------------

  EngineRuntime createRuntime({required String ortLibraryPath, int ep = KeEp.cpu, int deviceId = 0, int numThreads = 0}) {
    final out = calloc<Pointer<KeRuntime>>();
    final path = ortLibraryPath.toNativeUtf8();
    try {
      final rc = bindings.runtimeCreate(path, ep, deviceId, numThreads, out);
      _check(rc, 'ke_runtime_create');
      return EngineRuntime._(this, out.value, ep);
    } finally {
      calloc.free(path);
      calloc.free(out);
    }
  }
}

class EngineRuntime {
  EngineRuntime._(this.engine, this.ptr, this.requestedEp);
  final Engine engine;
  final Pointer<KeRuntime> ptr;
  final int requestedEp;
  bool _disposed = false;

  EngineBindings get _b => engine.bindings;

  int get activeEp => _b.runtimeActiveEp(ptr);

  Map<String, dynamic> info() {
    final s = _b.readString((buf, cap, needed) => _b.runtimeInfoJson(ptr, buf, cap, needed));
    return jsonDecode(s) as Map<String, dynamic>;
  }

  /// Returns the model run time in ms, throws on failure.
  double selftest([String? modelPath]) {
    final ms = calloc<Double>();
    final path = modelPath?.toNativeUtf8() ?? nullptr;
    try {
      final rc = _b.runtimeSelftest(ptr, path, ms);
      engine._check(rc, 'ke_runtime_selftest');
      return ms.value;
    } finally {
      calloc.free(ms);
      if (path != nullptr) calloc.free(path);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _b.runtimeDestroy(ptr);
  }

  // ---- jobs (run in a worker isolate) -----------------------------------------

  EngineJob separate({
    required String modelPath,
    required Map<String, dynamic> params,
    required String inputWav,
    String? primaryOut,
    String? secondaryOut,
  }) {
    return _runJob(_SeparateArgs(modelPath, jsonEncode(params), inputWav, primaryOut, secondaryOut));
  }

  EngineJob transcribe({
    required String modelDir,
    required String inputWav,
    required Map<String, dynamic> options,
    required String notesOut,
  }) {
    return _runJob(_TranscribeArgs(modelDir, inputWav, jsonEncode(options), notesOut));
  }

  EngineJob f0Extract({
    required String modelPath,
    required String inputWav,
    required String f0Out,
    double fmin = 46.875,
    double fmax = 2093.75,
  }) {
    return _runJob(_F0Args(modelPath, inputWav, fmin, fmax, f0Out));
  }

  /// Beat / downbeat tracking (Beat This!) of [inputWav] into [beatsOut].
  EngineJob beats({required String modelDir, required String inputWav, required String beatsOut}) {
    return _runJob(_BeatsArgs(modelDir, inputWav, beatsOut));
  }

  EngineJob _runJob(_JobArgs args) {
    final cancel = calloc<Int32>();
    final progressCtrl = StreamController<JobProgress>.broadcast();
    final port = ReceivePort();
    final libPath = engine.libraryPath;
    final rtAddr = ptr.address;
    final cancelAddr = cancel.address;
    final sendPort = port.sendPort;

    port.listen((msg) {
      if (msg is List && msg.length == 2) progressCtrl.add(JobProgress((msg[0] as num).toDouble(), msg[1] as String));
    });

    final done = _spawnJob(libPath, rtAddr, cancelAddr, sendPort, args).then((r) {
      if (r.code != KeError.ok) throw EngineException(r.code, r.message);
    }).whenComplete(() {
      port.close();
      progressCtrl.close();
      calloc.free(cancel);
    });
    return EngineJob._(progressCtrl.stream, cancel, done);
  }
}

// ---- isolate side ------------------------------------------------------------

// Separate function so the closure passed to Isolate.run only captures
// sendable values (a closure created inside _runJob would drag its whole
// context, including the ReceivePort, into the isolate message).
Future<_JobResult> _spawnJob(String libPath, int rtAddr, int cancelAddr, SendPort progress, _JobArgs args) {
  return Isolate.run<_JobResult>(() => _jobEntry(libPath, rtAddr, cancelAddr, progress, args));
}

sealed class _JobArgs {}

class _SeparateArgs extends _JobArgs {
  _SeparateArgs(this.model, this.params, this.input, this.primary, this.secondary);
  final String model, params, input;
  final String? primary, secondary;
}

class _TranscribeArgs extends _JobArgs {
  _TranscribeArgs(this.modelDir, this.input, this.options, this.out);
  final String modelDir, input, options, out;
}

class _F0Args extends _JobArgs {
  _F0Args(this.model, this.input, this.fmin, this.fmax, this.out);
  final String model, input, out;
  final double fmin, fmax;
}

class _BeatsArgs extends _JobArgs {
  _BeatsArgs(this.modelDir, this.input, this.out);
  final String modelDir, input, out;
}

class _JobResult {
  _JobResult(this.code, this.message);
  final int code;
  final String message;
}

_JobResult _jobEntry(String libPath, int rtAddr, int cancelAddr, SendPort progress, _JobArgs args) {
  final b = EngineBindings(DynamicLibrary.open(libPath));
  final rt = Pointer<KeRuntime>.fromAddress(rtAddr);
  final cancel = Pointer<Int32>.fromAddress(cancelAddr);
  var lastSent = DateTime.fromMillisecondsSinceEpoch(0);
  // isolateLocal: invoked synchronously on this isolate's thread by the C job,
  // so it can return the cancellation flag.
  final cb = NativeCallable<KeProgressCbNative>.isolateLocal((double frac, Pointer<Utf8> stage, Pointer<Void> _) {
    final now = DateTime.now();
    if (now.difference(lastSent).inMilliseconds >= 50 || frac >= 1.0) {
      lastSent = now;
      progress.send([frac, stage.toDartString()]);
    }
    return cancel.value;
  }, exceptionalReturn: 0);
  final strings = <Pointer<Utf8>>[];
  Pointer<Utf8> s(String? v) {
    if (v == null) return nullptr;
    final ptr = v.toNativeUtf8();
    strings.add(ptr);
    return ptr;
  }

  try {
    final int rc = switch (args) {
      _SeparateArgs a =>
        b.separate(rt, s(a.model), s(a.params), s(a.input), s(a.primary), s(a.secondary), cb.nativeFunction, nullptr),
      _TranscribeArgs a => b.transcribe(rt, s(a.modelDir), s(a.input), s(a.options), s(a.out), cb.nativeFunction, nullptr),
      _F0Args a => b.f0Extract(rt, s(a.model), s(a.input), a.fmin, a.fmax, s(a.out), cb.nativeFunction, nullptr),
      _BeatsArgs a => b.beats(rt, s(a.modelDir), s(a.input), s(a.out), cb.nativeFunction, nullptr),
    };
    return _JobResult(rc, rc == KeError.ok ? '' : b.lastErrorString());
  } finally {
    for (final ptr in strings) {
      calloc.free(ptr);
    }
    cb.close();
  }
}

// ---- offline reverb (worker isolate) ------------------------------------------------

Future<_CalibResult> _spawnReverb(String libPath, String input, String output, double mix, double tail) {
  return Isolate.run<_CalibResult>(() {
    // The last error is thread-local: read it on the isolate that made the call.
    final b = EngineBindings(DynamicLibrary.open(libPath));
    final i = input.toNativeUtf8(), o = output.toNativeUtf8();
    try {
      final rc = b.reverbRenderWav(i, o, mix, tail);
      return _CalibResult(rc, rc == KeError.ok ? '' : 'ke_reverb_render_wav: ${b.lastErrorString()}', 0);
    } finally {
      calloc.free(i);
      calloc.free(o);
    }
  });
}

// ---- latency calibration (worker isolate) ------------------------------------------

class _CalibResult {
  _CalibResult(this.code, this.message, this.seconds);
  final int code;
  final String message;
  final double seconds;
}

Future<_CalibResult> _spawnCalibrate(String libPath, String? capture, String? playback, int sampleRate) {
  return Isolate.run<_CalibResult>(() => _calibrateEntry(libPath, capture, playback, sampleRate));
}

_CalibResult _calibrateEntry(String libPath, String? capture, String? playback, int sampleRate) {
  // The engine's last error is thread-local: create, calibrate, read the
  // error and destroy all on this isolate's thread.
  final b = EngineBindings(DynamicLibrary.open(libPath));
  final out = calloc<Pointer<KeAudio>>();
  final secs = calloc<Double>();
  final c = capture?.toNativeUtf8() ?? nullptr;
  final pb = playback?.toNativeUtf8() ?? nullptr;
  Pointer<KeAudio> dev = nullptr;
  try {
    var rc = b.audioCreate(c, pb, sampleRate, out);
    if (rc != KeError.ok) return _CalibResult(rc, 'ke_audio_create: ${b.lastErrorString()}', 0);
    dev = out.value;
    rc = b.audioCalibrateLatency(dev, secs);
    if (rc != KeError.ok) return _CalibResult(rc, 'ke_audio_calibrate_latency: ${b.lastErrorString()}', 0);
    return _CalibResult(KeError.ok, '', secs.value);
  } finally {
    if (dev != nullptr) b.audioDestroy(dev);
    if (c != nullptr) calloc.free(c);
    if (pb != nullptr) calloc.free(pb);
    calloc.free(out);
    calloc.free(secs);
  }
}

// ---- live audio ------------------------------------------------------------------

class PitchFrame {
  const PitchFrame(this.time, this.f0, this.confidence, this.rmsDb, this.source);
  final double time;
  final double f0;
  final double confidence;
  final double rmsDb;
  final int source; // 0 = DSP (MPM), 1 = SwiftF0
  bool get voiced => f0 > 0;
}

class LiveAudio {
  LiveAudio._(this.engine, this.ptr) : _buf = calloc<Float>(5 * _maxFrames);
  static const _maxFrames = 1024;

  final Engine engine;
  final Pointer<KeAudio> ptr;
  final Pointer<Float> _buf;
  bool _disposed = false;

  EngineBindings get _b => engine.bindings;

  static LiveAudio create(Engine engine, {String? captureDevice, String? playbackDevice, int sampleRate = 48000}) {
    final out = calloc<Pointer<KeAudio>>();
    final c = captureDevice?.toNativeUtf8() ?? nullptr;
    final pb = playbackDevice?.toNativeUtf8() ?? nullptr;
    try {
      final rc = engine.bindings.audioCreate(c, pb, sampleRate, out);
      engine._check(rc, 'ke_audio_create');
      return LiveAudio._(engine, out.value);
    } finally {
      if (c != nullptr) calloc.free(c);
      if (pb != nullptr) calloc.free(pb);
      calloc.free(out);
    }
  }

  void _check(int rc, String what) => engine._check(rc, what);

  ({double input, double output}) latency() {
    final i = calloc<Double>(), o = calloc<Double>();
    try {
      _b.audioGetLatency(ptr, i, o);
      return (input: i.value, output: o.value);
    } finally {
      calloc.free(i);
      calloc.free(o);
    }
  }

  void loadTrack(String wavPath) {
    final s = wavPath.toNativeUtf8();
    try {
      _check(_b.audioLoadTrack(ptr, s), 'ke_audio_load_track');
    } finally {
      calloc.free(s);
    }
  }

  void unloadTrack() => _b.audioUnloadTrack(ptr);
  double get trackDuration => _b.audioTrackDuration(ptr);
  void play() => _check(_b.audioPlay(ptr), 'ke_audio_play');
  void pause() => _check(_b.audioPause(ptr), 'ke_audio_pause');
  void seek(double seconds) => _check(_b.audioSeek(ptr, seconds), 'ke_audio_seek');
  bool get isPlaying => _b.audioIsPlaying(ptr) != 0;
  double get position => _b.audioPosition(ptr);
  set volume(double gain) => _b.audioSetVolume(ptr, gain);
  set pitchShift(double semitones) => _b.audioSetPitchShift(ptr, semitones);

  /// Metronome clicks (track seconds) with bar-start accents; replaces the
  /// previous list. The engine mixes them sample-accurately into playback.
  void setClicks(List<double> times, List<bool> accents) {
    final n = times.length;
    final t = calloc<Double>(n == 0 ? 1 : n);
    final a = calloc<Int32>(n == 0 ? 1 : n);
    try {
      for (var i = 0; i < n; i++) {
        t[i] = times[i];
        a[i] = i < accents.length && accents[i] ? 1 : 0;
      }
      _check(_b.audioSetClicks(ptr, t, a, n), 'ke_audio_set_clicks');
    } finally {
      calloc.free(t);
      calloc.free(a);
    }
  }

  /// Metronome level (linear, 0 = off).
  set clickGain(double gain) => _b.audioSetClickGain(ptr, gain.clamp(0.0, 4.0));

  /// Vocal return: the microphone mixed into the output (use headphones).
  set vocalReturn(bool on) => _check(_b.audioSetVocalReturn(ptr, on ? 1 : 0), 'ke_audio_set_vocal_return');

  /// Preview sine tone at [hz] (0 fades it out); glides between pitches.
  void setTone(double hz, {double gain = 0.2}) =>
      _check(_b.audioSetTone(ptr, hz.clamp(0.0, 20000.0), hz > 0 ? gain.clamp(0.0, 1.0) : 0.0), 'ke_audio_set_tone');

  /// Hall reverb on the vocal return; [mix] 0 = dry, 1 = reverb only.
  void setReverb(bool on, double mix) => _check(_b.audioSetReverb(ptr, on ? 1 : 0, mix.clamp(0.0, 1.0)), 'ke_audio_set_reverb');

  void startCapture({EngineRuntime? runtime, String? swiftF0ModelPath, int mode = 0}) {
    final s = swiftF0ModelPath?.toNativeUtf8() ?? nullptr;
    try {
      _check(_b.audioStartCapture(ptr, runtime?.ptr ?? nullptr, s, mode), 'ke_audio_start_capture');
    } finally {
      if (s != nullptr) calloc.free(s);
    }
  }

  void stopCapture() => _b.audioStopCapture(ptr);
  bool get isCapturing => _b.audioIsCapturing(ptr) != 0;
  double get captureElapsed => _b.audioCaptureElapsed(ptr);
  set latencyCompensation(double seconds) => _b.audioSetLatencyCompensation(ptr, seconds);
  double get inputLevelDb => _b.audioInputLevelDb(ptr);

  /// Drains new pitch frames (call every UI tick).
  List<PitchFrame> readFrames() {
    final n = _b.audioReadF0(ptr, _buf, _maxFrames);
    if (n <= 0) return const [];
    final out = List<PitchFrame>.generate(n, (i) {
      final k = i * 5;
      return PitchFrame(_buf[k], _buf[k + 1], _buf[k + 2], _buf[k + 3], _buf[k + 4].round());
    });
    return out;
  }

  void saveCapture(String wavPath) {
    final s = wavPath.toNativeUtf8();
    try {
      _check(_b.audioSaveCapture(ptr, s), 'ke_audio_save_capture');
    } finally {
      calloc.free(s);
    }
  }

  /// Opens a temporary duplex device, measures the round-trip latency and
  /// closes it, all on a worker isolate so the UI keeps running (the native
  /// call blocks for up to ~3.5 s). Throws [EngineException] on failure.
  static Future<double> calibrateInBackground(Engine engine, {String? captureDevice, String? playbackDevice, int sampleRate = 48000}) async {
    final r = await _spawnCalibrate(engine.libraryPath, captureDevice, playbackDevice, sampleRate);
    if (r.code != KeError.ok) throw EngineException(r.code, r.message);
    return r.seconds;
  }

  /// Blocks the calling thread for up to ~3.5 s; prefer [calibrateInBackground].
  double calibrateLatency() {
    final out = calloc<Double>();
    try {
      _check(_b.audioCalibrateLatency(ptr, out), 'ke_audio_calibrate_latency');
      return out.value;
    } finally {
      calloc.free(out);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _b.audioDestroy(ptr);
    calloc.free(_buf);
  }
}
