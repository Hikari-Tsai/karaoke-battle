# Karaoke Battle — architecture

Desktop karaoke scoring app for streamers. macOS (universal) + Windows, Flutter UI,
native C++ engine, all ML models downloaded on first run from Hugging Face (`aaatmy/*`).

```
┌──────────────────────────── Flutter app (app/) ────────────────────────────┐
│ UI: library · prep pipeline · sing (piano roll + live F0) · results · settings │
│ Dart services: sidecars (yt-dlp, ffmpeg) · model downloader · song store ·     │
│                scoring (alignment + metrics) · engine FFI (dart:ffi)          │
└───────────────┬───────────────────────────────────────────────┬──────────────┘
                │ dart:ffi (karaoke_engine.h)                    │ Process.start
┌───────────────▼──────────── C++ engine (engine/) ──────────────▼──────────────┐
│ core: ORT loader (dlopen) · WAV · resample · GPU info          sidecars/       │
│ models: MDX-Net separation · GAME transcription · SwiftF0 F0    yt-dlp, ffmpeg │
│ dsp: STFT (pocketfft) · MPM pitch · signalsmith-stretch                        │
│ audio: miniaudio duplex device, playback clock, capture ring, F0 frames        │
└────────────────────────────────────────────────────────────────────────────────┘
```

## Directory layout

| Path | What |
| --- | --- |
| `engine/include/karaoke_engine.h` | **The contract.** C API used by Dart. Change it only with matching Dart bindings. |
| `engine/src/core/` | error/log, ONNX Runtime dynamic loading + `OrtSession` helper, WAV I/O, resampler, GPU inventory |
| `engine/src/dsp/` | `Stft` (pocketfft, mixed radix), `Mpm` pitch tracker |
| `engine/src/models/` | `mdx` (separation), `game` (+ `slicer`), `swiftf0` |
| `engine/src/audio/` | `ke_audio_*` implementation (miniaudio) |
| `engine/tools/ke_cli.cpp` | CLI mirroring the C API; used by tests and CI |
| `engine/tests/` | numerical reference tests (Python + ke_cli) |
| `engine/third_party/` | vendored single-header libs (MIT / BSD / public domain). `onnxruntime/` is fetched, not committed. |
| `app/` | Flutter project |
| `scripts/` | `fetch_ort.sh`, sidecar/model manifests |
| `.github/workflows/` | macOS universal + Windows builds |

## Engine conventions

* C++17, no exceptions across the C boundary, no RTTI needed. Every public call
  returns `KE_OK`/`KE_ERR_*` and sets `ke_last_error()` through `ke::fail()`.
* Logging through `KE_LOGI/W/E`. `ke_cli` installs a synchronous callback; the
  Flutter app enables the engine's log queue (`ke_log_set_queue`) and polls
  `ke_log_drain` every 500 ms (a `NativeCallable.listener` cannot be used because the
  message pointer is only valid during the synchronous call).
* Resampling: `ke::resample` is a table-driven windowed-sinc (Blackman, 32 taps per side at
  the slower rate); 30 s of 48 kHz audio converts in ~130 ms.

### Verification tools

| Command | What it checks |
| --- | --- |
| `engine/tests/mdx/README.md` | C++ separation vs `audio-separator` (SNR ≥ 30 dB; measured 110–134 dB) |
| `engine/tests/game/README.md` | C++ GAME vs Python onnxruntime reference (bit-identical with `nsteps=1`) |
| `engine/tests/audio/README.md` | SwiftF0 vs pip `swift-f0` (bit-identical at 16 kHz), live loopback test |
| `cd app && KE_TEST_SONG=<song dir> KE_TEST_SWIFTF0=<model.onnx> flutter test test/engine` | Dart bindings: runtime, isolate job with progress, live playback + capture |
| `cd app && flutter test test/scoring` | scoring unit tests + real-data fixtures (identical take = 100, random < 20) |
| `cd app && dart run tool/score_files.dart notes.json take_f0.json ref_f0.json` | score any engine output |
* Long jobs take a `ke_progress_cb`; call `ke::report_progress()` at least every
  second of work and honour cancellation (return its error code).
* Audio buffers are `ke::AudioBuffer` (planar float). All model code works at the
  model's native sample rate and converts with `ke::resample()`.
* ONNX Runtime is **never linked**. `ke_runtime` dlopens the library the app
  points at (`ke_runtime_create`). Model code creates sessions with
  `ke::OrtSession::create(rt, path, &err)` and runs them with
  `session->run(inputs, {names}, outputs)`; inputs are `ke::tensor_f32/i64/bool(...)`
  views on host memory, outputs are copied into `ke::TensorOut`.
* Headers compiled against ORT 1.23.2 (`ORT_API_VERSION 23`). Newer runtimes
  (DirectML 1.24.x, CUDA 1.31.x) serve that API version.
* macOS: universal binary (`CMAKE_OSX_ARCHITECTURES=arm64;x86_64`). Nothing may
  depend on arch-specific intrinsics without a scalar fallback.

## Execution providers

| Platform | Base (always shipped) | Optional pack (downloaded on demand) |
| --- | --- | --- |
| macOS | ORT 1.23.2 universal2, CPU EP (CoreML EP tried for fixed-shape models) | none |
| Windows | ORT DirectML 1.24.4 (`onnxruntime.dll` + `DirectML.dll`) | CUDA pack: ORT 1.31.1 `win-x64-gpu_cuda12` + cudart/cublas/cufft/cudnn 9 DLLs (from PyPI `nvidia-*-cu12` wheels) |

Backend order: CUDA → DirectML → CPU. Decision tree and dialogs: `docs/BACKENDS.md`.

## Models (all from Hugging Face `aaatmy/*`, verified by manifest sha256)

| Repo | Use | Notes |
| --- | --- | --- |
| `aaatmy/uvr-mdx-net-onnx` | vocal/instrumental separation | `Kim_Vocal_2` (vocals), `UVR-MDX-NET-Inst_HQ_4` (instrumental). STFT params in manifest. |
| `aaatmy/game-large-onnx` / `game-small-onnx` | vocal → notes | 5 graphs, D3PM loop, opset 17 |
| `aaatmy/swift-f0-onnx` | F0 (live mic + offline reference) | 16 kHz, 16 ms hop |

### MDX-Net pipeline (engine/src/models/mdx.cpp)

Reference: UVR `separate.py` (`SeperateMDX`) and `audio-separator`'s `MDXSeparator`.

1. Input → 44.1 kHz stereo float.
2. `Stft(n_fft, hop=1024, HannPeriodic, center=true)` per channel. Keep bins `[0, dim_f)`.
3. Model input `[B, 4, dim_f, 256]` = `[L.re, L.im, R.re, R.im]` per 256-frame chunk.
   Chunk the frame axis with overlap; UVR uses a `chunk_size = hop * (256 - 1)` sample window
   with `overlap` fraction and a triangular/linear crossfade window — reproduce that.
4. Model output has the same layout; zero-pad bins `[dim_f, n_fft/2+1)`, ISTFT → primary stem.
5. `secondary = mixture - primary * compensate` (UVR applies `compensate` to the primary
   before subtraction; keep the primary itself unscaled when writing it).
6. Write 32-bit float WAVs.

Validate against `audio-separator` (pip) output on a 20 s clip: SNR of
(ours vs reference) ≥ 30 dB on the primary stem.

### GAME pipeline (engine/src/models/game.cpp)

Reference: `inference/me_infer.py`, `inference/data.py`, `inference/callbacks.py`,
`inference/slicer2.py` from openvpi/GAME v1.0.3 (copy in `engine/tests/reference/game/`).

1. Mono 44.1 kHz. Slice by silence with `Slicer(threshold=-40 dB, min_length=1000 ms,
   min_interval=200 ms, hop=20 ms, max_sil_kept=100 ms)`. Each slice has an `offset` (s).
   Additionally split slices longer than `max_chunk_seconds` at the quietest frame.
2. Per slice (batch 1):
   * `encoder(waveform[1,L], duration[1]=L/sr)` → `x_seg[1,T,C]`, `x_est`, `maskT[1,T]`
   * `known_boundaries = dur2bd(durations=[[duration]], maskT)`
   * `boundaries = known_boundaries`; for `t in t0 + i*(1-t0)/nsteps, i=0..nsteps-1` (default 0, 0.125, …, 0.875):
     `boundaries = segmenter(x_seg, language[1], known_boundaries, prev_boundaries=boundaries, t[1], maskT, threshold=0.2, radius=round(0.02/0.01)=2)`
   * `durations, maskN = bd2dur(boundaries, maskT)`
   * `presence, scores = estimator(x_est, boundaries, maskT, maskN, threshold=0.2)`
   * notes: `onset = offset + cumsum([0]+durations)`, `offset_time = offset + cumsum(durations)`,
     both clamped to `offset + slice_length`; drop `presence == false` and zero-length.
3. Merge all slices: sort by (onset, offset, pitch); enforce monotonic non-overlap exactly
   like `SaveCombinedFileCallback.save_file`.
4. Output JSON `{"timestep","language","model","notes":[{onset,offset,pitch}]}`.

Validate against the Python reference runner (`engine/tests/game_reference.py`, pure
onnxruntime + numpy, same loop) on a 30 s vocal clip: identical note count and
max |pitch diff| < 0.01 given the same random boundaries… note the segmenter has a
`RandomUniformLike` node, so runs are stochastic: compare note onsets within 30 ms and
pitches within 0.5 semitone for ≥ 95 % of notes instead.

### SwiftF0 (engine/src/models/swiftf0.cpp)

`audio[1,N] f32 @16 kHz, fmin f32 scalar, fmax f32 scalar → pitch[1,F] f64 (Hz), confidence[1,F] f32`.
Frame hop 256 samples (16 ms). Voiced when confidence ≥ 0.5. Offline: resample whole file,
run in ≤ 60 s windows with 0.5 s overlap, stitch (drop overlap halves). Live: see audio.

Validate against `pip install swift-f0` on the same WAV: median |cents| < 5 on voiced frames.

### Audio (engine/src/audio/audio_engine.cpp)

* One miniaudio duplex device (`ma_device_type_duplex`) at the requested rate, f32,
  capture mono, playback stereo. Device ids from `ma_context_get_devices`.
* **Playback clock** = frames rendered by the device callback; `ke_audio_position()` =
  track frame cursor / sample rate, interpolated with `ma_device_get_…` not needed —
  frames are exact.
* Track is decoded fully into memory (`read_wav` → resample to device rate).
  Pitch shift via `signalsmith::stretch::SignalsmithStretch<float>` (preset `presetDefault`,
  `setTransposeSemitones`) processed in the callback thread in blocks; bypass when 0.
* Capture: lock-free SPSC ring buffer (`ma_pcm_rb`) → (a) MPM on 2048-sample windows every
  10 ms in a worker thread, (b) SwiftF0 worker: resample 48k→16k, run on 1 s windows every 160 ms
  with 176 ms lookahead; emit frames with `source=1`.
* Each frame timestamp = capture sample time − latency compensation, mapped to the
  playback clock when a track is playing (capture start is recorded against the playback cursor).
* `ke_audio_save_capture` writes the whole capture (kept in a growable buffer, mono f32) and a
  JSON sidecar with `track_start_offset` and `latency`.
* Latency calibration: play 5 clicks 200 ms apart, record, cross-correlate, median.
* Everything in the device callback is allocation-free and lock-free.

## Dart side (app/lib)

* `engine/engine_bindings.dart` — hand-written `dart:ffi` bindings of karaoke_engine.h.
* `engine/engine.dart` — high level async wrappers; long jobs run in `Isolate.run`,
  progress via `NativeCallable.listener`.
* `services/sidecars.dart` — locate/download/update yt-dlp + ffmpeg (+ deno) in the app
  support dir, run with progress parsing.
* `services/models.dart` — model registry (HF repo, files, sha256) and downloader.
* `services/backend.dart` — GPU detection, CUDA pack management, backend selection UI logic.
* `services/library.dart` — song store (JSON index + per-song folder).
* `scoring/` — alignment (global semitone shift, DTW), chroma/pitch metrics, note metrics,
  vibrato/stability/dynamics.
* `ui/` — screens and the piano roll `CustomPainter`.

Song folder: `<support>/songs/<id>/{source.*, video.mp4, mix.wav, vocals.wav, inst.wav,
notes.json, ref_f0.json, meta.json, takes/<timestamp>/{take.wav, take.json, score.json}}`.
