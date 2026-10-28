# Audio / SwiftF0 tests

Numerical tests for `engine/src/models/swiftf0.cpp` (offline F0) and smoke/accuracy
tests for the live audio engine `engine/src/audio/audio_engine.cpp`, driven through
`ke_cli`. Python dependencies are resolved with `uv` (no venv to maintain).

```sh
cd engine
cmake -S . -B build-audio -G Ninja -DCMAKE_BUILD_TYPE=Release && cmake --build build-audio -j
ORT=third_party/onnxruntime/osx-universal2/lib/libonnxruntime.dylib
MODEL=/path/to/swift-f0-onnx/model.onnx            # aaatmy/swift-f0-onnx (same bytes as the pip wheel)
PY="uv run --python 3.12 --with swift-f0 --with soundfile --with soxr --with numpy python -I"
```

## 1. Synthetic test signal

`make_test_wav.py` writes a tone glide (log sweep, default 130 -> 520 Hz) with 5.5 Hz
vibrato (+-40 cents), six harmonics, a slow level envelope, silent gaps (digital
silence and sub-1e-3 noise, which exercises swift-f0's silence gate) and a
`<out>.truth.json` with the instantaneous f0 every 1 ms.

```sh
$PY tests/audio/make_test_wav.py /tmp/ke/test48k.wav --rate 48000 --seconds 8
$PY tests/audio/make_test_wav.py /tmp/ke/test16k.wav --rate 16000 --seconds 8 --seed 1
$PY tests/audio/make_test_wav.py /tmp/ke/long44k.wav --rate 44100 --seconds 70 --seed 2 --stereo --gaps 6   # > 30 s: exercises windowing
$PY tests/audio/make_test_wav.py /tmp/ke/track.wav --rate 48000 --seconds 6 --seed 3 --f-start 220 --f-end 330 --stereo  # playback track for the live test
```

## 2. Offline SwiftF0 vs the upstream `swift-f0` package

```sh
./build-audio/ke_cli f0 --ort $ORT --model $MODEL --in /tmp/ke/test48k.wav --out /tmp/ke/f0.json --verbose
$PY tests/audio/compare_swiftf0.py --wav /tmp/ke/test48k.wav --ke-json /tmp/ke/f0.json --truth /tmp/ke/test48k.wav.truth.json
```

Pass criteria: same frame count and timestamps, median |cents| < 5 on frames both call
voiced, voicing agreement > 95 %. Results on this machine (swift-f0 0.3.0, ORT 1.23.2 CPU):

| file | frames | voicing agreement | median / p95 / max cents | max confidence diff |
| --- | --- | --- | --- | --- |
| test16k.wav (16 kHz, no resampling) | 500 | 100 % | 0.000 / 0.000 / 0.001 | 0.00000 |
| test48k.wav (48 kHz) | 500 | 100 % | 0.063 / 0.195 / 0.725 | 0.00246 |
| long44k.wav (44.1 kHz stereo, 70 s) | 4375 | 100 % | 0.062 / 0.187 / 0.369 | 0.00391 |

At 16 kHz the output is bit-identical; the sub-cent differences at other rates come
only from the resampler (`ke::resample` windowed sinc vs soxr). Both agree with the
synthetic ground truth to ~4 cents median (the vibrato moves 40 cents within a frame).

## 3. Live path (`ke_cli devices / live / calibrate`)

```sh
./build-audio/ke_cli devices
./build-audio/ke_cli live --ort $ORT --model $MODEL --track /tmp/ke/track.wav --seconds 5 --save /tmp/ke/take.wav --verbose
./build-audio/ke_cli calibrate --verbose
uv run --python 3.12 --with soundfile --with numpy python -I tests/audio/live_test.py \
    --ke-cli build-audio/ke_cli --ort $ORT --model $MODEL --work-dir /tmp/ke/live
```

`live_test.py` runs the three commands and checks:

1. `devices` returns non-empty capture/playback lists.
2. `live` on the default devices exits 0, logs device info and latencies, produces
   MPM (`source=0`, 100 frames/s) and SwiftF0 (`source=1`, 62.5 frames/s) frames and
   writes `take.wav` + `take.wav.json`. Pitch content is not checked here: it depends
   on what the microphone hears.
3. If a loopback device exists (BlackHole, Loopback, VB-Cable, ... — pass
   `--loopback <name>` to choose, `--loopback none` to skip) the run is repeated with
   playback and capture on that device so the capture "hears" the track. Frames are
   compared with the ground truth (median |cents| < 10 after the best time offset),
   the offset is compared with the cross-correlation of `take.wav` against the track
   and with `ke_cli calibrate` (must agree within 5 ms).

`ke_cli live` extras for manual tests: `--mode 0|1|2`, `--pitch <semitones>`
(signalsmith stretch), `--volume <gain>`, `--seek <s>` (applied before play),
`--latency <s>` (timestamp compensation), `--capture/--playback <id>` (ids from
`devices`), `--rate <hz>`.

Results on this machine (macOS, Core Audio, 48 kHz, 480-frame periods x 3):

* default devices (headset mic / headphones): 494 MPM + 300 SwiftF0 frames in 5 s,
  MPM 0.19 ms mean per call, SwiftF0 8 ms mean per 1 s window, ring backlog <= 10 ms.
* loopback (BlackHole): MPM median 2.1 cents / SwiftF0 4.8 cents vs ground truth;
  frame timestamps were 20 ms late with the default compensation (= output latency
  30 ms) while the measured round trip was 50 ms -> after `calibrate` (50.0 ms, five
  clicks all 50.0 ms) and `--latency 0.050` the mapping is exact. `take.wav.json`'s
  `track_start_offset`/`latency` reproduce the cross-correlation lag to the sample.
* `--pitch 3`: frames track the shifted glide (+3 semitones), position stays
  continuous (stretcher latency 7200 frames is compensated in `ke_audio_position`).
* `--seek 2.0`: frames start at track time 2.0 s.
* `calibrate` on the headset mic / headphones and on built-in speakers / mic fails
  cleanly with "no click detected" (peak/mean 4.3): the mic cannot hear the output
  acoustically in this setup; the algorithm itself is verified by the loopback run.
