// Which language each Whisper size detects on each song (first sung window,
// as the app's engine and the Space do). Prints no lyrics.
//   node eval/detect_language.mjs --model small=<dir> ... <song dir> ...
import fs from 'node:fs';
import path from 'node:path';
import { loadWhisper } from './node_models.mjs';
import { resample, toMono } from '../lib/resample.js';
import { SAMPLE_RATE } from '../lib/whisper.js';
import { readWav } from './wav.mjs';

const args = process.argv.slice(2);
const models = [], songs = [];
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--model') {
    const [name, dir] = args[++i].split('=');
    models.push({ name, dir });
  } else songs.push(args[i]);
}
const audio = songs.map((s) => {
  const w = readWav(path.join(s, 'vocals.wav'));
  // Only up to the first window matters for detection; 45 s covers the first sung window of these songs.
  return resample(toMono(w.planes.map((p) => p.subarray(0, Math.min(p.length, 45 * w.sr)))), w.sr, SAMPLE_RATE);
});
for (const m of models) {
  const model = await loadWhisper(m.dir, { intraOpNumThreads: 4, graphOptimizationLevel: 'all' });
  for (let i = 0; i < songs.length; i++) {
    const meta = JSON.parse(fs.readFileSync(path.join(songs[i], 'meta.json'), 'utf8'));
    let lang = null;
    // Stop after the first window: detection happens there.
    await model.recognize(audio[i], { language: null, onWindow: () => { throw Object.assign(new Error('stop'), { stop: true }); } }).catch((e) => { if (!e.stop) throw e; });
    lang = model.lastDetected;
    console.log(m.name, path.basename(songs[i]).slice(0, 8), `metadata ${meta.language}`, `detected ${lang}`);
  }
}
