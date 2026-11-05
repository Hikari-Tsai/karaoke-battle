// Whisper in its own worker with the CPU-only (WASM) build of ONNX Runtime
// Web (its int8 operators have no WebGPU kernels).
//
// Keep this worker's imports as they are: with one more local module
// imported (a shared helpers file), Chrome ran the same ONNX sessions about
// 15x slower here (measured 2.3 s vs 34 s per encoder run of whisper-small).
import * as ort from 'https://cdn.jsdelivr.net/npm/onnxruntime-web@1.23.2/dist/ort.wasm.bundle.min.mjs';
import { WhisperModel, WhisperTokenizer } from './lib/whisper.js';
import { whisperSegments } from './lib/pipeline.js';
import { WHISPER, WHISPER_FILES, fetchFile } from './models.js';

ort.env.wasm.wasmPaths = 'https://cdn.jsdelivr.net/npm/onnxruntime-web@1.23.2/dist/';
ort.env.wasm.numThreads = self.crossOriginIsolated ? Math.min(8, navigator.hardwareConcurrency || 4) : 1;

const progress = (stage, fraction, extra = {}) => self.postMessage({ type: 'progress', stage, fraction, ...extra });
// Lets the progress messages out between heavy steps.
const breathe = () => new Promise((r) => setTimeout(r, 0));
const json = (bytes) => JSON.parse(new TextDecoder().decode(bytes));

self.onmessage = async (e) => {
  if (e.data.type !== 'whisper') return;
  const job = e.data;
  try {
    const m = WHISPER[job.whisper];
    // One file at a time, each session created straight from its bytes.
    let done = 0;
    const get = async (f) => {
      const b = await fetchFile(m, f, (d) => progress('download-whisper', Math.min(1, (done + d) / (m.mb * 1e6)), { download: true, mb: m.mb }));
      done += b.length;
      return b;
    };
    const small = {};
    for (const f of WHISPER_FILES.filter((f) => !f.endsWith('.onnx'))) small[f] = await get(f);
    const enc = await ort.InferenceSession.create(await get('onnx/encoder_model_quantized.onnx'), { executionProviders: ['wasm'] });
    const dec = await ort.InferenceSession.create(await get('onnx/decoder_model_merged_quantized.onnx'), { executionProviders: ['wasm'] });
    progress('whisper', 0);
    const t0 = performance.now();
    const stats = { encoder: 0, decoder: 0, steps: 0 };
    for (const [sess, key] of [[enc, 'encoder'], [dec, 'decoder']]) {
      const run = sess.run.bind(sess);
      sess.run = async (...a) => {
        const t = performance.now();
        const o = await run(...a);
        stats[key] += (performance.now() - t) / 1000;
        if (key === 'decoder') stats.steps++;
        return o;
      };
    }
    const tok = new WhisperTokenizer(json(small['vocab.json']), json(small['added_tokens.json']), WhisperTokenizer.parseMerges(new TextDecoder().decode(small['merges.txt'])));
    const model = new WhisperModel(ort, enc, dec, tok, json(small['generation_config.json']), json(small['preprocessor_config.json']).feature_size ?? 128);
    const { segments, raw } = await whisperSegments(model, job.vocals16k, job.language === 'auto' ? null : job.language, async (f) => {
      progress('whisper', f);
      await breathe();
    });
    await enc.release();
    await dec.release();
    self.postMessage({ type: 'done', segments: segments.map((s) => ({ start: s.start, end: s.end, text: s.text })), seconds: (performance.now() - t0) / 1000, stats, language: raw.language });
  } catch (err) {
    self.postMessage({ type: 'error', message: String(err?.message || err) });
  }
};
