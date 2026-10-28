# GAME transcription: engine vs. Python reference

`engine/src/models/game.cpp` + `slicer.cpp` port openvpi/GAME v1.0.3
(`inference/me_infer.py`, `data.py`, `callbacks.py`, `slicer2.py`) onto the official
ONNX export (encoder / segmenter / estimator / dur2bd / bd2dur + `config.json`).

Files here:

| file | purpose |
|---|---|
| `game_reference.py` | pure onnxruntime + numpy implementation of the same pipeline, same JSON output |
| `compare.py` | compares two notes JSON files (onset match within 30 ms, pitch diff, counts) |
| `make_synthetic.py` | generates a deterministic 20 s synthetic "singing" WAV (several phrases with silences) |

The segmenter graph contains a `RandomUniformLike` node (D3PM boundary removal), so two
runs are never bit-identical. Validation criteria: >= 95 % of notes match within 30 ms
onset and 0.5 semitone pitch, and note counts within 5 %.

## Prerequisites

* `uv` (system python is 3.14 without packages; every script is run through
  `uv run --python 3.12 --with onnxruntime --with numpy --with soundfile python -I`).
* The ONNX model directory, e.g. `GAME-1.0.3-large-onnx/` with the five `.onnx` files
  and `config.json`.
* A 44.1 kHz WAV (mono or stereo). Convert anything else first:
  `ffmpeg -i in.ogg -t 30 -ac 1 -ar 44100 -c:a pcm_f32le clip.wav`

Set these for the commands below:

```sh
export PATH=/opt/homebrew/bin:$PATH
ENGINE=/Users/hikaritsai/karaoke-battle/engine
MODEL=/path/to/GAME-1.0.3-large-onnx
WORK=/tmp/game-test            # any scratch dir
PY="uv run --python 3.12 --with onnxruntime --with numpy --with soundfile python -I"
mkdir -p $WORK
```

## 1. Build the engine

```sh
cd $ENGINE
cmake -S . -B build-game -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build-game -j
```

## 2. Test audio

Synthetic clip (always available):

```sh
$PY $ENGINE/tests/game/make_synthetic.py $WORK/synth_20s.wav
```

Real clip: any solo-singing recording with a permissive licence, e.g. from Wikimedia
Commons "The Star-Spangled Banner - Solo vocalist - U.S. Navy Band.oga" (public domain,
US federal work) or "Twinkle Twinkle Little Star - sung with full lyrics.ogg" (CC0):

```sh
curl -L -A "karaoke-battle-dev/0.1" -o $WORK/ssb.oga \
  'https://upload.wikimedia.org/wikipedia/commons/4/4d/%22The_Star-Spangled_Banner%22_-_Solo_vocalist_-_U.S._Navy_Band.oga'
ffmpeg -y -i $WORK/ssb.oga -t 30 -ac 1 -ar 44100 -c:a pcm_f32le $WORK/real_30s.wav
```

## 3. Run the engine

```sh
cd $ENGINE
./build-game/ke_cli transcribe \
  --ort third_party/onnxruntime/osx-universal2/lib/libonnxruntime.dylib --ep cpu \
  --model-dir $MODEL --in $WORK/real_30s.wav \
  --options '{"language":"en"}' --out $WORK/cpp_real.json --verbose
```

Options JSON keys (all optional, defaults = GAME's `infer.py extract` defaults):
`language`, `seg_threshold` (0.2), `seg_radius_seconds` (0.02), `t0` (0), `nsteps` (8),
`est_threshold` (0.2), `max_chunk_seconds` (40),
`slicer: {threshold_db:-40, min_length_ms:1000, min_interval_ms:200, hop_ms:20, max_sil_kept_ms:100}`.

## 4. Run the Python reference

```sh
$PY $ENGINE/tests/game/game_reference.py --model-dir $MODEL \
  --in $WORK/real_30s.wav --out $WORK/ref_real.json --language en --verbose
```

Same tunables as the engine: `--seg-threshold --seg-radius --t0 --nsteps --est-threshold
--max-chunk-seconds --slicer-threshold-db --slicer-min-length-ms --slicer-min-interval-ms
--slicer-hop-ms --slicer-max-sil-kept-ms`. `--verbose` prints the slices, which must be
identical to the engine's `[D] GAME: slice i: a .. b s` lines (deterministic part).

## 5. Compare

```sh
$PY $ENGINE/tests/game/compare.py $WORK/cpp_real.json $WORK/ref_real.json
# add --dump to list every unmatched or pitch-mismatched note
```

Exit code 0 = PASS. Because of the stochastic segmenter, also compare two reference runs
with each other to see the intrinsic run-to-run variation.

Deterministic check: with a single D3PM step the random boundary removal never fires
(`prev_boundaries == known_boundaries` at the first step), so engine and reference must be
bit-identical (100 % match, zero onset/offset/pitch differences):

```sh
./build-game/ke_cli transcribe ... --options '{"language":"en","nsteps":1}' --out $WORK/cpp_n1.json
$PY $ENGINE/tests/game/game_reference.py --model-dir $MODEL --in $WORK/real_30s.wav \
  --out $WORK/ref_n1.json --language en --nsteps 1
$PY $ENGINE/tests/game/compare.py $WORK/cpp_n1.json $WORK/ref_n1.json
```

Results obtained on 2026-10-28 (GAME-1.0.3-large-onnx, CPU EP, Apple Silicon):

| clip | C++ vs ref | ref vs ref | note |
|---|---|---|---|
| Star-Spangled Banner 30 s (real) | 95.1 % / 97.6 %, 41 = 41 notes, max pitch diff 0.011 st on matched notes | 95.1 % | PASS |
| Twinkle 40 s, `max_chunk_seconds=2` (30 slices) | 94.3 %, 70 vs 69 notes | n/a | slices identical |
| synthetic 20 s | 82.9 % / 97.3 % | 85.4 %, 12 % count diff | synthetic audio is out of distribution: boundaries unstable run to run |
| both clips, `nsteps=1` | 100 %, all diffs 0 | deterministic | PASS |

The synthetic clip is checked the same way with `$WORK/synth_20s.wav`. To exercise the
`max_chunk_seconds` split path, pass `--options '{"language":"en","max_chunk_seconds":6}'`
to the engine and `--max-chunk-seconds 6` to the reference and check the slice lists match.
