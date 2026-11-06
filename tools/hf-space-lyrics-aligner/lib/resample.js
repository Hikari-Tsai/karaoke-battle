// Windowed-sinc resampler: port of the app's engine/src/core/resample.cpp
// (Blackman window, 32 taps per side at the slower rate, cut-off 0.95 x
// Nyquist, table lookup with linear interpolation, kernel-sum normalised).

const kernels = new Map();

function kernel(ratio) {
  const key = ratio.toFixed(12);
  if (kernels.has(key)) return kernels.get(key);
  const scale = Math.min(1.0, ratio);
  const cutoff = 0.95 * scale * 0.5;
  const halfWidth = 32;
  const halfTaps = Math.ceil(halfWidth / scale);
  const phases = 128;
  const n = 2 * halfTaps * phases + 1;
  const table = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    const x = i / phases - halfTaps;
    const s = Math.abs(x) < 1e-9 ? 2.0 * cutoff : Math.sin(2.0 * Math.PI * cutoff * x) / (Math.PI * x);
    const u = (x * scale) / halfWidth;
    let w = 0.0;
    if (u > -1.0 && u < 1.0) w = 0.42 + 0.5 * Math.cos(Math.PI * u) + 0.08 * Math.cos(2.0 * Math.PI * u);
    table[i] = s * w;
  }
  const k = { halfTaps, phases, table };
  kernels.set(key, k);
  return k;
}

/** Resamples one channel (Float32Array) from inRate to outRate. */
export function resample(input, inRate, outRate) {
  if (inRate === outRate || input.length === 0) return input;
  const ratio = outRate / inRate;
  const outLen = Math.round(input.length * ratio);
  const out = new Float32Array(outLen);
  const { halfTaps, phases, table } = kernel(ratio);
  const tlen = table.length;
  const nIn = input.length;
  for (let n = 0; n < outLen; n++) {
    const center = n / ratio;
    const c = Math.floor(center);
    const i0 = Math.max(0, c - halfTaps + 1);
    const i1 = Math.min(nIn - 1, c + halfTaps);
    // float32 arithmetic throughout, as the C++ (Whisper's greedy decoding
    // can flip on differences this small).
    const f = Math.fround;
    let acc = 0, wsum = 0;
    for (let i = i0; i <= i1; i++) {
      const pos = (i - center + halfTaps) * phases;
      const j = Math.trunc(pos);
      if (j < 0 || j + 1 >= tlen) continue;
      const w = f(table[j] + f(f(table[j + 1] - table[j]) * f(pos - j)));
      acc = f(acc + f(input[i] * w));
      wsum = f(wsum + w);
    }
    out[n] = wsum !== 0 ? f(acc / wsum) : 0;
  }
  return out;
}

/** Average of the channels (Float32Array[]). */
export function toMono(planes) {
  if (planes.length === 1) return planes[0];
  const n = planes[0].length;
  const m = new Float32Array(n);
  const g = 1 / planes.length;
  for (const p of planes) for (let i = 0; i < n; i++) m[i] += p[i] * g;
  return m;
}
