// UVR MDX-Net vocal separation (Kim_Vocal_2 ONNX): port of the app's
// engine/src/models/mdx.cpp, itself a port of audio-separator's
// MDXSeparator.demix() (UVR's SeperateMDX). Same geometry:
//
//   trim = n_fft/2, chunk = hop*(dim_t-1), gen = chunk - 2*trim,
//   pad = gen + trim - n % gen, mixture = [zeros(trim), mix, zeros(pad)],
//   step = int((1-overlap)*chunk); every chunk is STFT'ed (torch semantics),
//   bins < 3 zeroed, fed as [L.re, L.im, R.re, R.im] x dim_f x dim_t, ISTFT'ed,
//   cross-faded with a symmetric Hann window and normalised by its sum.
import { Stft } from './fft.js';

export const KIM_VOCAL_2 = { n_fft: 7680, hop_length: 1024, dim_f: 3072, dim_t_log2: 8, compensate: 1.009, overlap: 0.25 };

/**
 * Separates the vocals of a 44.1 kHz stereo mixture ([L, R] Float32Arrays).
 * Returns [L, R] of the vocal stem. `session` is an ort.InferenceSession.
 */
export async function separateVocals(ort, session, planes, params = KIM_VOCAL_2, onProgress = () => {}) {
  const { n_fft, hop_length: hop, dim_f, dim_t_log2, overlap } = params;
  const dimT = 1 << dim_t_log2;
  const n = planes[0].length;
  const trim = n_fft / 2;
  const chunk = hop * (dimT - 1);
  const gen = chunk - 2 * trim;
  const pad = gen + trim - (n % gen);
  const total = trim + n + pad;
  const step = Math.max(1, Math.floor((1 - overlap) * chunk));
  const numChunks = Math.ceil(total / step);
  const useWindow = overlap !== 0;

  const mixture = planes.map((p) => {
    const m = new Float32Array(total);
    m.set(p, trim);
    return m;
  });
  const result = [new Float32Array(total), new Float32Array(total)];
  const divider = new Float32Array(total);
  const stft = new Stft(n_fft, hop);
  const frames = stft.numFrames(chunk);
  if (frames !== dimT) throw new Error(`mdx: ${frames} frames per chunk, expected ${dimT}`);
  const plane = dim_f * dimT;
  const input = new Float32Array(4 * plane);
  const part = new Float32Array(chunk);
  const inputName = session.inputNames[0];
  const outputName = session.outputNames[0];

  let done = 0;
  for (let start = 0; start < total; start += step) {
    const end = Math.min(start + chunk, total);
    const actual = end - start;
    input.fill(0);
    for (let c = 0; c < 2; c++) {
      part.fill(0);
      part.set(mixture[c].subarray(start, end));
      const reOff = 2 * c * plane;
      const imOff = reOff + plane;
      stft.forward(part, chunk, (f, re, im) => {
        for (let k = 3; k < dim_f; k++) {
          // spek[:, :, :3, :] *= 0
          input[reOff + k * dimT + f] = re[k];
          input[imOff + k * dimT + f] = im[k];
        }
      });
    }
    const feeds = { [inputName]: new ort.Tensor('float32', input, [1, 4, dim_f, dimT]) };
    const out = (await session.run(feeds))[outputName].data;
    let window = null;
    if (useWindow) {
      window = new Float32Array(actual);
      if (actual === 1) window[0] = 1;
      else for (let k = 0; k < actual; k++) window[k] = 0.5 - 0.5 * Math.cos((2 * Math.PI * k) / (actual - 1));
    }
    for (let c = 0; c < 2; c++) {
      const reOff = 2 * c * plane;
      const imOff = reOff + plane;
      const wave = stft.inverse(frames, chunk, (f, re, im) => {
        re.fill(0);
        im.fill(0);
        for (let k = 0; k < dim_f; k++) {
          re[k] = out[reOff + k * dimT + f];
          im[k] = out[imOff + k * dimT + f];
        }
      });
      const acc = result[c];
      if (useWindow) for (let k = 0; k < actual; k++) acc[start + k] += wave[k] * window[k];
      else for (let k = 0; k < actual; k++) acc[start + k] += wave[k];
    }
    if (useWindow) for (let k = 0; k < actual; k++) divider[start + k] += window[k];
    else for (let k = 0; k < actual; k++) divider[start + k] += 1;
    done++;
    await onProgress(done / numChunks);
  }
  return result.map((r) => {
    const o = new Float32Array(n);
    for (let i = 0; i < n; i++) {
      const d = divider[trim + i];
      o[i] = d > 0 ? r[trim + i] / d : 0;
    }
    return o;
  });
}
