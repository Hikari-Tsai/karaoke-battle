/*
 * karaoke_engine.h — C API of the Karaoke Battle native engine.
 *
 * The engine is a shared library (libkaraoke_engine.dylib / karaoke_engine.dll)
 * loaded by the Flutter app through dart:ffi. Everything heavy lives here:
 * ONNX Runtime sessions (GAME, MDX-Net, SwiftF0), real-time audio I/O,
 * pitch detection, STFT, resampling and pitch shifting.
 *
 * Conventions
 * -----------
 * - All functions return 0 on success and a negative KE_ERR_* code on failure.
 *   ke_last_error() returns a thread-local, human readable message for the
 *   most recent failure on the calling thread.
 * - Strings are UTF-8. JSON strings are used for structured data so the
 *   Dart side never has to mirror C structs.
 * - Output buffers of unknown size follow the "query then fill" pattern:
 *   pass NULL/0 to get the required size (including the NUL terminator).
 * - Long running calls (separate, transcribe, f0_extract) are blocking.
 *   Call them from a worker isolate/thread. They report progress through
 *   ke_progress_cb and can be cancelled by returning non-zero from it.
 * - The live audio object (ke_audio) is real-time safe inside its callbacks;
 *   all ke_audio_* functions are safe to call from the UI thread.
 */
#ifndef KARAOKE_ENGINE_H
#define KARAOKE_ENGINE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#  if defined(KE_BUILD_SHARED)
#    define KE_API __declspec(dllexport)
#  else
#    define KE_API __declspec(dllimport)
#  endif
#else
#  define KE_API __attribute__((visibility("default")))
#endif

/* ------------------------------------------------------------------ */
/* Errors, logging, version                                            */
/* ------------------------------------------------------------------ */

enum {
    KE_OK                 = 0,
    KE_ERR_INVALID_ARG    = -1,
    KE_ERR_IO             = -2,   /* file not found / unreadable / unwritable */
    KE_ERR_ORT_LOAD       = -3,   /* onnxruntime library could not be loaded  */
    KE_ERR_ORT            = -4,   /* onnxruntime reported an error            */
    KE_ERR_EP_UNAVAILABLE = -5,   /* requested execution provider not usable  */
    KE_ERR_MODEL          = -6,   /* model file missing / wrong shape         */
    KE_ERR_AUDIO_DEVICE   = -7,   /* miniaudio device error                   */
    KE_ERR_STATE          = -8,   /* call not valid in the current state      */
    KE_ERR_CANCELLED      = -9,   /* progress callback asked to stop          */
    KE_ERR_BUFFER_TOO_SMALL = -10,
    KE_ERR_INTERNAL       = -99
};

enum {
    KE_LOG_DEBUG = 0,
    KE_LOG_INFO  = 1,
    KE_LOG_WARN  = 2,
    KE_LOG_ERROR = 3
};

typedef void (*ke_log_cb)(int level, const char* message, void* user);

/* Progress: fraction in [0,1], stage is a short machine-readable id
 * ("decode", "stft", "model", "istft", "encoder", "segmenter", ...).
 * Return 0 to continue, non-zero to cancel the running job. */
typedef int (*ke_progress_cb)(float fraction, const char* stage, void* user);

KE_API const char* ke_version(void);
/* Synchronous callback, invoked on whatever engine thread produced the line.
 * The message pointer is only valid during the call (hosts that process logs
 * asynchronously should use the queue below instead). */
KE_API void        ke_set_log_callback(ke_log_cb cb, void* user);
KE_API const char* ke_last_error(void);

/* Log queue: when enabled, log lines are buffered (capped at ~1000 lines) and
 * ke_log_drain returns the pending ones as "<level>\t<message>\n" records using
 * the query-then-fill pattern. Safe to call from any thread. */
KE_API void        ke_log_set_queue(int enabled, int min_level);
KE_API int         ke_log_drain(char* out, size_t cap, size_t* needed);

/* ------------------------------------------------------------------ */
/* Runtime: dynamically loaded ONNX Runtime + execution provider       */
/* ------------------------------------------------------------------ */

typedef struct ke_runtime ke_runtime;

enum {
    KE_EP_CPU      = 0,
    KE_EP_CUDA     = 1,   /* Windows: needs the CUDA pack (ORT gpu build + NVIDIA runtime DLLs) */
    KE_EP_DIRECTML = 2,   /* Windows: ORT DirectML build */
    KE_EP_COREML   = 3    /* macOS: CoreML EP, falls back to CPU per node */
};

/*
 * ort_library_path: full path to libonnxruntime.dylib / onnxruntime.dll.
 *   The directory of that file is also used to locate provider libraries
 *   (onnxruntime_providers_cuda.dll, DirectML.dll, ...).
 * ep: KE_EP_*; device_id: GPU index (ignored for CPU).
 * num_threads: intra-op threads for the CPU EP (0 = ORT default).
 */
KE_API int  ke_runtime_create(const char* ort_library_path, int ep, int device_id,
                              int num_threads, ke_runtime** out);
KE_API void ke_runtime_destroy(ke_runtime* rt);

/* Which EP is actually active (may differ from the request if ORT fell back). */
KE_API int  ke_runtime_active_ep(const ke_runtime* rt);

/* JSON: {"ort_version":"1.23.2","ep":"cuda","ep_available":true,"error":"..."} */
KE_API int  ke_runtime_info_json(const ke_runtime* rt, char* out, size_t cap, size_t* needed);

/*
 * Self test: builds a tiny in-memory graph and runs it on the requested EP,
 * then (optionally) runs a short dummy inference through model_path.
 * Returns KE_OK when the EP really works. ms_out receives the model run time.
 */
KE_API int  ke_runtime_selftest(ke_runtime* rt, const char* model_path_or_null, double* ms_out);

/*
 * System GPU inventory (no ORT needed). JSON array:
 * [{"vendor":"nvidia","name":"...","vram_mb":8192,"cuda_driver_version":12080,
 *   "compute_capability":"8.6","adapter_index":0}]
 * On macOS returns the Apple GPU with vendor "apple".
 */
KE_API int  ke_system_gpu_info_json(char* out, size_t cap, size_t* needed);

/* ------------------------------------------------------------------ */
/* Offline jobs                                                        */
/* ------------------------------------------------------------------ */

/*
 * Source separation with a UVR MDX-Net ONNX model.
 * params_json: {"n_fft":7680,"hop_length":1024,"dim_f":3072,"dim_t_log2":8,
 *               "compensate":1.009,"primary_stem":"Vocals","overlap":0.25,
 *               "batch_size":1}
 *   (same keys as aaatmy/uvr-mdx-net-onnx manifest.json)
 * input_wav: any WAV (dr_wav decodable); resampled to 44.1 kHz stereo inside.
 * primary_out_wav / secondary_out_wav: 32-bit float stereo 44.1 kHz WAV.
 *   secondary = mixture - primary * compensate (UVR behaviour). Either may be NULL.
 */
KE_API int  ke_separate(ke_runtime* rt, const char* model_path, const char* params_json,
                        const char* input_wav, const char* primary_out_wav,
                        const char* secondary_out_wav,
                        ke_progress_cb progress, void* user);

/*
 * Singing transcription with GAME (openvpi). model_dir contains
 * encoder/segmenter/estimator/dur2bd/bd2dur.onnx + config.json.
 * options_json (all optional):
 *   {"language":"zh","seg_threshold":0.2,"seg_radius_seconds":0.02,
 *    "t0":0.0,"nsteps":8,"est_threshold":0.2,
 *    "slicer":{"threshold_db":-40,"min_length_ms":1000,"min_interval_ms":200,
 *              "hop_ms":20,"max_sil_kept_ms":100},
 *    "max_chunk_seconds":40}
 * Output JSON written to notes_out_json:
 *   {"timestep":0.01,"language":"zh","model":"game-large",
 *    "notes":[{"onset":1.23,"offset":1.80,"pitch":62.4}, ...]}  (pitch = MIDI, float)
 * Notes are sorted, non-overlapping, rests removed, times in seconds from file start.
 */
KE_API int  ke_transcribe(ke_runtime* rt, const char* model_dir, const char* input_wav,
                          const char* options_json, const char* notes_out_json,
                          ke_progress_cb progress, void* user);

/*
 * Offline F0 curve with SwiftF0. Input is resampled to 16 kHz mono inside.
 * Output JSON: {"hop":0.016,"sample_rate":16000,"fmin":..,"fmax":..,
 *               "times":[...],"f0":[...],"confidence":[...]}
 * f0 is in Hz (0 where unvoiced i.e. confidence < 0.5).
 */
KE_API int  ke_f0_extract(ke_runtime* rt, const char* swiftf0_model_path, const char* input_wav,
                          float fmin, float fmax, const char* f0_out_json,
                          ke_progress_cb progress, void* user);

/* ------------------------------------------------------------------ */
/* Live audio: capture + pitch tracking + playback with one clock      */
/* ------------------------------------------------------------------ */

typedef struct ke_audio ke_audio;

/* JSON: {"capture":[{"id":"...","name":"...","default":true}],"playback":[...]} */
KE_API int  ke_audio_list_devices_json(char* out, size_t cap, size_t* needed);

/*
 * Creates a duplex audio engine at sample_rate (44100 or 48000 recommended).
 * Device ids come from ke_audio_list_devices_json; NULL = system default.
 */
KE_API int  ke_audio_create(const char* capture_device_id, const char* playback_device_id,
                            int sample_rate, ke_audio** out);
KE_API void ke_audio_destroy(ke_audio* a);

/* Measured device latencies in seconds (input + output), best effort. */
KE_API int  ke_audio_get_latency(ke_audio* a, double* input_seconds, double* output_seconds);

/* ---- playback track (the accompaniment or the original mix) ---- */
KE_API int    ke_audio_load_track(ke_audio* a, const char* wav_path);   /* decoded fully into memory */
KE_API int    ke_audio_unload_track(ke_audio* a);
KE_API double ke_audio_track_duration(ke_audio* a);
KE_API int    ke_audio_play(ke_audio* a);
KE_API int    ke_audio_pause(ke_audio* a);
KE_API int    ke_audio_seek(ke_audio* a, double seconds);
KE_API int    ke_audio_is_playing(ke_audio* a);
/* Sample-accurate playback position in seconds (track time), monotonic while playing. */
KE_API double ke_audio_position(ke_audio* a);
KE_API int    ke_audio_set_volume(ke_audio* a, float gain);            /* linear, 1.0 = unity */
/* Pitch shift of the playback track in semitones (signalsmith-stretch), 0 = bypass. */
KE_API int    ke_audio_set_pitch_shift(ke_audio* a, float semitones);

/* ---- capture + real-time F0 ---- */

/*
 * Start capturing the microphone. If rt and swiftf0_model_path are given the
 * SwiftF0 model runs on a worker thread fed from the capture ring buffer;
 * otherwise (or additionally, see mode) a DSP pitch tracker (MPM) runs
 * directly in the capture thread.
 *   mode: 0 = DSP only, 1 = SwiftF0 only, 2 = both (DSP frames flagged source=0, model frames source=1)
 * Frames are produced every ~10 ms (DSP) / 16 ms (SwiftF0).
 */
KE_API int  ke_audio_start_capture(ke_audio* a, ke_runtime* rt_or_null,
                                   const char* swiftf0_model_path_or_null, int mode);
KE_API int  ke_audio_stop_capture(ke_audio* a);
KE_API int  ke_audio_is_capturing(ke_audio* a);

/*
 * Drain pitch frames produced since the last call. Each frame is 5 floats:
 *   [time_seconds, f0_hz (0 = unvoiced), confidence 0..1, rms_db, source]
 * time_seconds is on the playback clock when a track is playing
 * (i.e. directly comparable with ke_audio_position), otherwise capture time.
 * Returns the number of frames written (>= 0) or an error code.
 */
KE_API int  ke_audio_read_f0(ke_audio* a, float* out, int max_frames);

/* Set the latency compensation applied to frame timestamps (seconds, default = measured output latency). */
KE_API int  ke_audio_set_latency_compensation(ke_audio* a, double seconds);

/* Time since capture start in seconds. */
KE_API double ke_audio_capture_elapsed(ke_audio* a);

/* Write everything captured since ke_audio_start_capture to a mono float WAV
 * (sample rate = engine sample rate) together with a sidecar JSON
 * ("<wav_path>.json": {"track_start_offset":..., "latency":...}). */
KE_API int  ke_audio_save_capture(ke_audio* a, const char* wav_path);

/*
 * Latency calibration: plays a short click burst through the playback device
 * while recording, cross-correlates, and returns the round-trip latency in
 * seconds. Requires no track to be playing. Blocks for ~2 seconds.
 */
KE_API int  ke_audio_calibrate_latency(ke_audio* a, double* roundtrip_seconds);

/* Current input level (RMS dBFS) for a mic meter. */
KE_API float ke_audio_input_level_db(ke_audio* a);

#ifdef __cplusplus
}
#endif

#endif /* KARAOKE_ENGINE_H */
