// Quick check: node eval/smoke_whisper.mjs <model dir> <wav> <lang> [seconds]
import { loadWhisper } from './node_models.mjs';
import { readWav } from './wav.mjs';
import { resample, toMono } from '../lib/resample.js';
import { whisperSegments } from '../lib/pipeline.js';
const [dir, wavPath, lang, secs] = process.argv.slice(2);
const w = readWav(wavPath);
let a = resample(toMono(w.planes), w.sr, 16000);
if (secs) a = a.subarray(0, Math.round(+secs * 16000));
const m = await loadWhisper(dir, { intraOpNumThreads: 2 });
const t = Date.now();
const { segments, raw } = await whisperSegments(m, a, lang);
console.log(((Date.now() - t) / 1000).toFixed(1), 's', raw.windows, 'windows', raw.segments.length, 'raw');
for (const s of segments) console.log(s.start.toFixed(2), s.end.toFixed(2), s.text);
