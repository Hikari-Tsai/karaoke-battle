# Beat This! parity check

`engine/src/models/beat_this.cpp` ports the inference pipeline of the
[beat_this](https://github.com/CPJKU/beat_this) package (as also used by
Hikari-Tsai/music-detection). It is validated against the official package at
the commit the ONNX export was made from, with the final0 checkpoint and no DBN.

```bash
# C++
engine/build/ke_cli beats --ort engine/third_party/onnxruntime/osx-universal2/lib/libonnxruntime.1.23.2.dylib \
  --model <dir with beat-this-final0.onnx + frontend.json> --in song.wav --out beats_cpp.json

# Reference (Python 3.12)
uv run --python 3.12 --with torch==2.5.1 --with torchaudio==2.5.1 \
  --with "git+https://github.com/CPJKU/beat_this@b95c8ab0c58c2d9fcfd40508ae8dffbc05ac4f5c" \
  --with soxr --with soundfile --with einops --with rotary-embedding-torch \
  python -c "from beat_this.inference import File2Beats; import json,sys; b,d=File2Beats('final0','cpu',dbn=False)(sys.argv[1]); json.dump({'beats':list(map(float,b)),'downbeats':list(map(float,d))},open('beats_ref.json','w'))" song.wav
```

Result on a 158 s pop cover (44.1 kHz stereo mix):

| | C++ | reference | matched within 20 ms | F-measure |
| --- | --- | --- | --- | --- |
| beats | 318 | 318 | 316 | 0.994 |
| downbeats | 79 | 79 | 79 | 1.000 |

The few one-frame (20 ms) differences come from resampling (the engine's
windowed-sinc resampler vs soxr in the reference).
