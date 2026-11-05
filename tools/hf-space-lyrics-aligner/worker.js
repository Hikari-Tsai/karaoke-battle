// Preparation off the main thread: 44.1 kHz stereo -> Kim_Vocal_2 vocals
// -> GAME notes; also hands back the 16 kHz vocal stem for Whisper.
// MDX-Net and GAME run on WebGPU when available (much faster for MDX-Net).
import * as ort from 'https://cdn.jsdelivr.net/npm/onnxruntime-web@1.23.2/dist/ort.all.bundle.min.mjs';
import { separateVocals } from './lib/mdx.js';
import { GameModel } from './lib/game.js';
import { resample, toMono } from './lib/resample.js';
import { SAMPLE_RATE } from './lib/whisper.js';
import { GAME, GAME_FILES, MDX, fetchFile } from './models.js';

ort.env.wasm.wasmPaths = 'https://cdn.jsdelivr.net/npm/onnxruntime-web@1.23.2/dist/';
ort.env.wasm.numThreads = self.crossOriginIsolated ? Math.min(8, navigator.hardwareConcurrency || 4) : 1;

const progress = (stage, fraction, extra = {}) => self.postMessage({ type: 'progress', stage, fraction, ...extra });
// Lets the progress messages out between heavy steps.
const breathe = () => new Promise((r) => setTimeout(r, 0));
const json = (bytes) => JSON.parse(new TextDecoder().decode(bytes));

/** All files of a model, from the cache or downloaded, with progress in MB. */
async function download(model, files, stage) {
  const out = {};
  let base = 0;
  for (const f of files) {
    out[f] = await fetchFile(model, f, (done) => progress(stage, Math.min(1, (base + done) / (model.mb * 1e6)), { download: true, mb: model.mb }));
    base += out[f].length;
  }
  return out;
}

/** A session on WebGPU (with WASM for what WebGPU lacks) or WASM only. */
async function makeSession(ort, bytes, ep) {
  const options = (providers) => ({ executionProviders: providers });
  if (!(ep === 'webgpu' && 'gpu' in navigator)) return ort.InferenceSession.create(bytes, options(['wasm']));
  try {
    return await ort.InferenceSession.create(bytes, options(['webgpu', 'wasm']));
  } catch {
    return ort.InferenceSession.create(bytes, options(['wasm']));
  }
}

async function vocalsOf(job) {
  if (job.skipSeparation) return job.planes;
  const files = await download(MDX, MDX.files, 'download-mdx');
  progress('separate', 0);
  const s = await makeSession(ort, files['Kim_Vocal_2.onnx'], job.ep);
  const out = await separateVocals(ort, s, job.planes, undefined, async (f) => {
    progress('separate', f);
    await breathe();
  });
  await s.release();
  return out;
}

async function notesOf(mono44k, job) {
  const m = GAME[job.gameSize];
  const files = await download(m, GAME_FILES, 'download-game');
  progress('notes', 0);
  const s = {};
  for (const k of ['encoder', 'segmenter', 'estimator', 'bd2dur']) s[k] = await makeSession(ort, files[`${k}.onnx`], job.ep);
  const game = new GameModel(ort, s, json(files['config.json']));
  const notes = await game.transcribe(mono44k, {
    language: job.language === 'auto' ? '' : job.language,
    onProgress: async (f) => {
      progress('notes', f);
      await breathe();
    },
  });
  for (const x of Object.values(s)) await x.release();
  return notes;
}

self.onmessage = async (e) => {
  if (e.data.type !== 'prep') return;
  const job = e.data;
  try {
    const t = {};
    let t0 = performance.now();
    const vocals = await vocalsOf(job);
    if (!job.skipSeparation) t.separate = (performance.now() - t0) / 1000;
    const mono = toMono(vocals);
    t0 = performance.now();
    const notes = await notesOf(mono, job);
    t.notes = (performance.now() - t0) / 1000;
    const vocals16k = resample(mono, 44100, SAMPLE_RATE);
    self.postMessage({ type: 'done', notes, vocals16k, times: t, threads: ort.env.wasm.numThreads }, [vocals16k.buffer]);
  } catch (err) {
    self.postMessage({ type: 'error', message: String(err?.message || err) });
  }
};
