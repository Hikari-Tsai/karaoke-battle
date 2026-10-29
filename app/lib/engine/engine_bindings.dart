// Hand-written dart:ffi bindings for engine/include/karaoke_engine.h.
// Keep in sync with the C header; every function below maps 1:1.
import 'dart:ffi';

import 'package:ffi/ffi.dart';

// ---- opaque handles -------------------------------------------------------
final class KeRuntime extends Opaque {}

final class KeAudio extends Opaque {}

// ---- callbacks ------------------------------------------------------------
typedef KeLogCbNative = Void Function(Int32 level, Pointer<Utf8> message, Pointer<Void> user);
typedef KeProgressCbNative = Int32 Function(Float fraction, Pointer<Utf8> stage, Pointer<Void> user);

// ---- error codes (mirror of the C enum) -----------------------------------
class KeError {
  static const ok = 0;
  static const invalidArg = -1;
  static const io = -2;
  static const ortLoad = -3;
  static const ort = -4;
  static const epUnavailable = -5;
  static const model = -6;
  static const audioDevice = -7;
  static const state = -8;
  static const cancelled = -9;
  static const bufferTooSmall = -10;
  static const internal = -99;
}

class KeEp {
  static const cpu = 0;
  static const cuda = 1;
  static const directml = 2;
  static const coreml = 3;

  static String name(int ep) => switch (ep) {
        cuda => 'cuda',
        directml => 'directml',
        coreml => 'coreml',
        _ => 'cpu',
      };

  static int fromName(String s) => switch (s) {
        'cuda' => cuda,
        'directml' || 'dml' => directml,
        'coreml' => coreml,
        _ => cpu,
      };
}

class EngineBindings {
  EngineBindings(this.lib)
      : version = lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('ke_version'),
        setLogCallback = lib.lookupFunction<
            Void Function(Pointer<NativeFunction<KeLogCbNative>>, Pointer<Void>),
            void Function(Pointer<NativeFunction<KeLogCbNative>>, Pointer<Void>)>('ke_set_log_callback'),
        lastError = lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('ke_last_error'),
        logSetQueue = lib.lookupFunction<Void Function(Int32, Int32), void Function(int, int)>('ke_log_set_queue'),
        logDrain = lib.lookupFunction<Int32 Function(Pointer<Utf8>, Size, Pointer<Size>),
            int Function(Pointer<Utf8>, int, Pointer<Size>)>('ke_log_drain'),
        runtimeCreate = lib.lookupFunction<
            Int32 Function(Pointer<Utf8>, Int32, Int32, Int32, Pointer<Pointer<KeRuntime>>),
            int Function(Pointer<Utf8>, int, int, int, Pointer<Pointer<KeRuntime>>)>('ke_runtime_create'),
        runtimeDestroy =
            lib.lookupFunction<Void Function(Pointer<KeRuntime>), void Function(Pointer<KeRuntime>)>('ke_runtime_destroy'),
        runtimeActiveEp =
            lib.lookupFunction<Int32 Function(Pointer<KeRuntime>), int Function(Pointer<KeRuntime>)>('ke_runtime_active_ep'),
        runtimeInfoJson = lib.lookupFunction<
            Int32 Function(Pointer<KeRuntime>, Pointer<Utf8>, Size, Pointer<Size>),
            int Function(Pointer<KeRuntime>, Pointer<Utf8>, int, Pointer<Size>)>('ke_runtime_info_json'),
        runtimeSelftest = lib.lookupFunction<
            Int32 Function(Pointer<KeRuntime>, Pointer<Utf8>, Pointer<Double>),
            int Function(Pointer<KeRuntime>, Pointer<Utf8>, Pointer<Double>)>('ke_runtime_selftest'),
        systemGpuInfoJson = lib.lookupFunction<
            Int32 Function(Pointer<Utf8>, Size, Pointer<Size>),
            int Function(Pointer<Utf8>, int, Pointer<Size>)>('ke_system_gpu_info_json'),
        separate = lib.lookupFunction<
            Int32 Function(Pointer<KeRuntime>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>,
                Pointer<NativeFunction<KeProgressCbNative>>, Pointer<Void>),
            int Function(Pointer<KeRuntime>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>,
                Pointer<NativeFunction<KeProgressCbNative>>, Pointer<Void>)>('ke_separate'),
        transcribe = lib.lookupFunction<
            Int32 Function(Pointer<KeRuntime>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>,
                Pointer<NativeFunction<KeProgressCbNative>>, Pointer<Void>),
            int Function(Pointer<KeRuntime>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>,
                Pointer<NativeFunction<KeProgressCbNative>>, Pointer<Void>)>('ke_transcribe'),
        f0Extract = lib.lookupFunction<
            Int32 Function(Pointer<KeRuntime>, Pointer<Utf8>, Pointer<Utf8>, Float, Float, Pointer<Utf8>,
                Pointer<NativeFunction<KeProgressCbNative>>, Pointer<Void>),
            int Function(Pointer<KeRuntime>, Pointer<Utf8>, Pointer<Utf8>, double, double, Pointer<Utf8>,
                Pointer<NativeFunction<KeProgressCbNative>>, Pointer<Void>)>('ke_f0_extract'),
        beats = lib.lookupFunction<
            Int32 Function(Pointer<KeRuntime>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>,
                Pointer<NativeFunction<KeProgressCbNative>>, Pointer<Void>),
            int Function(Pointer<KeRuntime>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>,
                Pointer<NativeFunction<KeProgressCbNative>>, Pointer<Void>)>('ke_beats'),
        audioSetClicks = lib.lookupFunction<
            Int32 Function(Pointer<KeAudio>, Pointer<Double>, Pointer<Int32>, Int32),
            int Function(Pointer<KeAudio>, Pointer<Double>, Pointer<Int32>, int)>('ke_audio_set_clicks'),
        audioSetClickGain = lib.lookupFunction<Int32 Function(Pointer<KeAudio>, Float), int Function(Pointer<KeAudio>, double)>(
            'ke_audio_set_click_gain'),
        audioSetVocalReturn = lib.lookupFunction<Int32 Function(Pointer<KeAudio>, Int32), int Function(Pointer<KeAudio>, int)>(
            'ke_audio_set_vocal_return'),
        audioSetReverb = lib.lookupFunction<Int32 Function(Pointer<KeAudio>, Int32, Float), int Function(Pointer<KeAudio>, int, double)>(
            'ke_audio_set_reverb'),
        reverbRenderWav = lib.lookupFunction<Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Float, Float),
            int Function(Pointer<Utf8>, Pointer<Utf8>, double, double)>('ke_reverb_render_wav'),
        audioListDevicesJson = lib.lookupFunction<
            Int32 Function(Pointer<Utf8>, Size, Pointer<Size>),
            int Function(Pointer<Utf8>, int, Pointer<Size>)>('ke_audio_list_devices_json'),
        audioCreate = lib.lookupFunction<
            Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32, Pointer<Pointer<KeAudio>>),
            int Function(Pointer<Utf8>, Pointer<Utf8>, int, Pointer<Pointer<KeAudio>>)>('ke_audio_create'),
        audioDestroy = lib.lookupFunction<Void Function(Pointer<KeAudio>), void Function(Pointer<KeAudio>)>('ke_audio_destroy'),
        audioGetLatency = lib.lookupFunction<
            Int32 Function(Pointer<KeAudio>, Pointer<Double>, Pointer<Double>),
            int Function(Pointer<KeAudio>, Pointer<Double>, Pointer<Double>)>('ke_audio_get_latency'),
        audioLoadTrack = lib.lookupFunction<Int32 Function(Pointer<KeAudio>, Pointer<Utf8>),
            int Function(Pointer<KeAudio>, Pointer<Utf8>)>('ke_audio_load_track'),
        audioUnloadTrack =
            lib.lookupFunction<Int32 Function(Pointer<KeAudio>), int Function(Pointer<KeAudio>)>('ke_audio_unload_track'),
        audioTrackDuration =
            lib.lookupFunction<Double Function(Pointer<KeAudio>), double Function(Pointer<KeAudio>)>('ke_audio_track_duration'),
        audioPlay = lib.lookupFunction<Int32 Function(Pointer<KeAudio>), int Function(Pointer<KeAudio>)>('ke_audio_play'),
        audioPause = lib.lookupFunction<Int32 Function(Pointer<KeAudio>), int Function(Pointer<KeAudio>)>('ke_audio_pause'),
        audioSeek = lib.lookupFunction<Int32 Function(Pointer<KeAudio>, Double), int Function(Pointer<KeAudio>, double)>(
            'ke_audio_seek'),
        audioIsPlaying =
            lib.lookupFunction<Int32 Function(Pointer<KeAudio>), int Function(Pointer<KeAudio>)>('ke_audio_is_playing'),
        audioPosition =
            lib.lookupFunction<Double Function(Pointer<KeAudio>), double Function(Pointer<KeAudio>)>('ke_audio_position'),
        audioSetVolume = lib.lookupFunction<Int32 Function(Pointer<KeAudio>, Float), int Function(Pointer<KeAudio>, double)>(
            'ke_audio_set_volume'),
        audioSetPitchShift =
            lib.lookupFunction<Int32 Function(Pointer<KeAudio>, Float), int Function(Pointer<KeAudio>, double)>(
                'ke_audio_set_pitch_shift'),
        audioStartCapture = lib.lookupFunction<
            Int32 Function(Pointer<KeAudio>, Pointer<KeRuntime>, Pointer<Utf8>, Int32),
            int Function(Pointer<KeAudio>, Pointer<KeRuntime>, Pointer<Utf8>, int)>('ke_audio_start_capture'),
        audioStopCapture =
            lib.lookupFunction<Int32 Function(Pointer<KeAudio>), int Function(Pointer<KeAudio>)>('ke_audio_stop_capture'),
        audioIsCapturing =
            lib.lookupFunction<Int32 Function(Pointer<KeAudio>), int Function(Pointer<KeAudio>)>('ke_audio_is_capturing'),
        audioReadF0 = lib.lookupFunction<Int32 Function(Pointer<KeAudio>, Pointer<Float>, Int32),
            int Function(Pointer<KeAudio>, Pointer<Float>, int)>('ke_audio_read_f0'),
        audioSetLatencyCompensation =
            lib.lookupFunction<Int32 Function(Pointer<KeAudio>, Double), int Function(Pointer<KeAudio>, double)>(
                'ke_audio_set_latency_compensation'),
        audioCaptureElapsed =
            lib.lookupFunction<Double Function(Pointer<KeAudio>), double Function(Pointer<KeAudio>)>('ke_audio_capture_elapsed'),
        audioSaveCapture = lib.lookupFunction<Int32 Function(Pointer<KeAudio>, Pointer<Utf8>),
            int Function(Pointer<KeAudio>, Pointer<Utf8>)>('ke_audio_save_capture'),
        audioCalibrateLatency = lib.lookupFunction<Int32 Function(Pointer<KeAudio>, Pointer<Double>),
            int Function(Pointer<KeAudio>, Pointer<Double>)>('ke_audio_calibrate_latency'),
        audioInputLevelDb =
            lib.lookupFunction<Float Function(Pointer<KeAudio>), double Function(Pointer<KeAudio>)>('ke_audio_input_level_db');

  final DynamicLibrary lib;

  final Pointer<Utf8> Function() version;
  final void Function(Pointer<NativeFunction<KeLogCbNative>>, Pointer<Void>) setLogCallback;
  final Pointer<Utf8> Function() lastError;
  final void Function(int, int) logSetQueue;
  final int Function(Pointer<Utf8>, int, Pointer<Size>) logDrain;

  final int Function(Pointer<Utf8>, int, int, int, Pointer<Pointer<KeRuntime>>) runtimeCreate;
  final void Function(Pointer<KeRuntime>) runtimeDestroy;
  final int Function(Pointer<KeRuntime>) runtimeActiveEp;
  final int Function(Pointer<KeRuntime>, Pointer<Utf8>, int, Pointer<Size>) runtimeInfoJson;
  final int Function(Pointer<KeRuntime>, Pointer<Utf8>, Pointer<Double>) runtimeSelftest;
  final int Function(Pointer<Utf8>, int, Pointer<Size>) systemGpuInfoJson;

  final int Function(Pointer<KeRuntime>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>,
      Pointer<NativeFunction<KeProgressCbNative>>, Pointer<Void>) separate;
  final int Function(Pointer<KeRuntime>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>,
      Pointer<NativeFunction<KeProgressCbNative>>, Pointer<Void>) transcribe;
  final int Function(Pointer<KeRuntime>, Pointer<Utf8>, Pointer<Utf8>, double, double, Pointer<Utf8>,
      Pointer<NativeFunction<KeProgressCbNative>>, Pointer<Void>) f0Extract;
  final int Function(Pointer<KeRuntime>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>,
      Pointer<NativeFunction<KeProgressCbNative>>, Pointer<Void>) beats;
  final int Function(Pointer<KeAudio>, Pointer<Double>, Pointer<Int32>, int) audioSetClicks;
  final int Function(Pointer<KeAudio>, double) audioSetClickGain;
  final int Function(Pointer<KeAudio>, int) audioSetVocalReturn;
  final int Function(Pointer<KeAudio>, int, double) audioSetReverb;
  final int Function(Pointer<Utf8>, Pointer<Utf8>, double, double) reverbRenderWav;

  final int Function(Pointer<Utf8>, int, Pointer<Size>) audioListDevicesJson;
  final int Function(Pointer<Utf8>, Pointer<Utf8>, int, Pointer<Pointer<KeAudio>>) audioCreate;
  final void Function(Pointer<KeAudio>) audioDestroy;
  final int Function(Pointer<KeAudio>, Pointer<Double>, Pointer<Double>) audioGetLatency;
  final int Function(Pointer<KeAudio>, Pointer<Utf8>) audioLoadTrack;
  final int Function(Pointer<KeAudio>) audioUnloadTrack;
  final double Function(Pointer<KeAudio>) audioTrackDuration;
  final int Function(Pointer<KeAudio>) audioPlay;
  final int Function(Pointer<KeAudio>) audioPause;
  final int Function(Pointer<KeAudio>, double) audioSeek;
  final int Function(Pointer<KeAudio>) audioIsPlaying;
  final double Function(Pointer<KeAudio>) audioPosition;
  final int Function(Pointer<KeAudio>, double) audioSetVolume;
  final int Function(Pointer<KeAudio>, double) audioSetPitchShift;
  final int Function(Pointer<KeAudio>, Pointer<KeRuntime>, Pointer<Utf8>, int) audioStartCapture;
  final int Function(Pointer<KeAudio>) audioStopCapture;
  final int Function(Pointer<KeAudio>) audioIsCapturing;
  final int Function(Pointer<KeAudio>, Pointer<Float>, int) audioReadF0;
  final int Function(Pointer<KeAudio>, double) audioSetLatencyCompensation;
  final double Function(Pointer<KeAudio>) audioCaptureElapsed;
  final int Function(Pointer<KeAudio>, Pointer<Utf8>) audioSaveCapture;
  final int Function(Pointer<KeAudio>, Pointer<Double>) audioCalibrateLatency;
  final double Function(Pointer<KeAudio>) audioInputLevelDb;

  /// Reads a "query then fill" JSON string function.
  String readString(int Function(Pointer<Utf8>, int, Pointer<Size>) fn) {
    final needed = calloc<Size>();
    try {
      fn(nullptr, 0, needed);
      final n = needed.value;
      if (n == 0) return '';
      final buf = calloc<Uint8>(n);
      try {
        fn(buf.cast(), n, needed);
        return buf.cast<Utf8>().toDartString();
      } finally {
        calloc.free(buf);
      }
    } finally {
      calloc.free(needed);
    }
  }

  String lastErrorString() => lastError().toDartString();
}
