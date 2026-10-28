# MDX-Net separation tests

Numerical validation of `engine/src/models/mdx.cpp` (UVR MDX-Net pipeline)
against the `audio-separator` Python package, whose `MDXSeparator` is a port of
UVR's `SeperateMDX`.

Files:

| file | purpose |
|---|---|
| `make_test_mix.py` | synthesises a 20 s / 44.1 kHz stereo mixture (`mix.wav`) plus the true `vocal_true.wav` / `inst_true.wav` |
| `run_reference.py` | runs `MDXSeparator.demix()` with explicit manifest parameters and writes `primary` / `secondary = mix - primary * compensate` as float32 WAV |
| `compare.py` | SNR (dB) of the engine stems vs the reference stems, exit 1 below `--min-snr` (default 30 dB) |

## Setup

```sh
export PATH=/opt/homebrew/bin:$PATH
WORK=/path/to/scratch            # anywhere outside the repo
MODELS=/path/to/uvr-mdx-net-onnx  # Kim_Vocal_2.onnx, UVR-MDX-NET-Inst_HQ_4.onnx, manifest.json
ENGINE=/Users/hikaritsai/karaoke-battle/engine

# Python reference environment (audio-separator pulls torch + onnxruntime; audioread is
# an undeclared dependency of its spec_utils module)
uv venv --python 3.12 $WORK/venv
uv pip install --python $WORK/venv/bin/python "audio-separator[cpu]" soundfile numpy audioread
PY=$WORK/venv/bin/python

# Engine
cd $ENGINE
cmake -S . -B build-mdx -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build-mdx -j
ORT=third_party/onnxruntime/osx-universal2/lib/libonnxruntime.dylib
```

## Test audio

```sh
$PY -I $ENGINE/tests/mdx/make_test_mix.py $WORK/data --seconds 20
# optional real clip (CC-BY, Josh Woodward "Swansong" from Wikimedia Commons), cut to 30 s
curl -L -o $WORK/dl/Josh_Woodward_-_Swansong.ogg \
  "https://commons.wikimedia.org/wiki/Special:FilePath/Josh_Woodward_-_Swansong.ogg"
ffmpeg -y -ss 30 -t 30 -i $WORK/dl/Josh_Woodward_-_Swansong.ogg -ac 2 -ar 44100 -c:a pcm_f32le $WORK/data/swansong30.wav
```

## Reference stems

```sh
for m in Kim_Vocal_2 UVR-MDX-NET-Inst_HQ_4; do
  $PY -I $ENGINE/tests/mdx/run_reference.py --model $MODELS/$m.onnx --manifest $MODELS/manifest.json \
      --in $WORK/data/mix.wav --primary $WORK/ref/${m}_primary.wav --secondary $WORK/ref/${m}_secondary.wav
done
```

`run_reference.py` deliberately bypasses `MDXSeparator.separate()`: that method
scales the primary by the input peak (`demix(mix) * peak`), re-normalises every
stem to `normalization_threshold` and writes through pydub as integer PCM, none
of which is part of the UVR `demix` maths that `ke_separate` implements.
`--full-dir DIR` additionally runs the stock path if you want to look at it.

## Engine stems and comparison

```sh
cd $ENGINE
PK='{"n_fft":7680,"hop_length":1024,"dim_f":3072,"dim_t_log2":8,"compensate":1.009,"primary_stem":"Vocals","overlap":0.25,"batch_size":1}'
PI='{"n_fft":5120,"hop_length":1024,"dim_f":2560,"dim_t_log2":8,"compensate":1.019,"primary_stem":"Instrumental","overlap":0.25,"batch_size":1}'

./build-mdx/ke_cli separate --ort $ORT --ep cpu --model $MODELS/Kim_Vocal_2.onnx --params "$PK" \
    --in $WORK/data/mix.wav --primary $WORK/out/kim_vocals.wav --secondary $WORK/out/kim_inst.wav --verbose
$PY -I tests/mdx/compare.py --ref-primary $WORK/ref/Kim_Vocal_2_primary.wav --our-primary $WORK/out/kim_vocals.wav \
    --ref-secondary $WORK/ref/Kim_Vocal_2_secondary.wav --our-secondary $WORK/out/kim_inst.wav

./build-mdx/ke_cli separate --ort $ORT --ep cpu --model $MODELS/UVR-MDX-NET-Inst_HQ_4.onnx --params "$PI" \
    --in $WORK/data/mix.wav --primary $WORK/out/inst_primary.wav --secondary $WORK/out/inst_secondary.wav --verbose
$PY -I tests/mdx/compare.py --ref-primary $WORK/ref/UVR-MDX-NET-Inst_HQ_4_primary.wav --our-primary $WORK/out/inst_primary.wav \
    --ref-secondary $WORK/ref/UVR-MDX-NET-Inst_HQ_4_secondary.wav --our-secondary $WORK/out/inst_secondary.wav
```

`--ep coreml` runs the same pipeline on the CoreML execution provider. The
Apple runtime prints `E5RT encountered an STL exception ... unbounded dimension`
once (the ONNX batch dimension is symbolic); the session still runs and the
output is numerically the same.

## Expected results (macOS, ORT 1.23.2)

Synthetic 20 s mixture, overlap 0.25:

| model | EP | primary SNR | secondary SNR | wall time |
|---|---|---|---|---|
| Kim_Vocal_2 | cpu | 133.8 dB | 132.1 dB | 18.8 s |
| Kim_Vocal_2 | coreml | 127.6 dB | 125.9 dB | 4.7 s |
| UVR-MDX-NET-Inst_HQ_4 | cpu | 126.4 dB | 115.7 dB | 28.3 s |
| UVR-MDX-NET-Inst_HQ_4 | coreml | 122.5 dB | 111.9 dB | 2.9 s |

Real 30 s clip (Josh Woodward "Swansong", CC-BY), overlap 0.25:

| model | EP | primary SNR | secondary SNR | wall time |
|---|---|---|---|---|
| Kim_Vocal_2 | cpu | 132.0 dB | 132.5 dB | 127 s (*) |
| Kim_Vocal_2 | coreml | 129.5 dB | 130.0 dB | 6.9 s |
| UVR-MDX-NET-Inst_HQ_4 | cpu | 124.3 dB | 123.6 dB | 72 s (*) |
| UVR-MDX-NET-Inst_HQ_4 | coreml | 121.3 dB | 120.5 dB | 3.7 s |

(*) CPU EP timings vary a lot with machine load (3 s/chunk on an idle machine,
9-16 s/chunk here); CoreML is consistently 4-8x realtime.

A 48 kHz mono input of the same clip (engine resamples with `ke::resample`,
the reference with librosa/soxr) still gives 109 dB / 85 dB.

(acceptance threshold is 30 dB; the remaining difference is float32 rounding.)
`batch_size` only changes how many chunks share one ONNX run; the result is
identical (136 dB vs. batch 1) and on the CPU EP batch 1 is fastest.

## What the engine reproduces (from `mdx_separator.py`)

* `trim = n_fft/2`, `chunk_size = hop * (2^dim_t_log2 - 1)`, `gen_size = chunk_size - 2*trim`,
  `pad = gen_size + trim - (n % gen_size)`, mixture = `[zeros(trim), mix, zeros(pad)]`.
* `step = int((1 - overlap) * chunk_size)`; chunks that run past the end are zero padded to
  `chunk_size`; crossfade window = `np.hanning(end - start)` (symmetric), accumulated into
  `result` and `divider`.
* Each chunk is STFT'ed on its own with torch semantics (periodic Hann, centre, reflect pad),
  bins `[0, dim_f)` are kept, bins 0..2 are zeroed, planes are `[L.re, L.im, R.re, R.im]`.
* Model output is zero padded to `n_fft/2+1` bins and ISTFT'ed (window-sum-square normalised,
  `n_fft/2` trimmed on both sides => `chunk_size` samples).
* `primary = (result / divider)[trim : trim + n]`, `secondary = mix - primary * compensate`.
