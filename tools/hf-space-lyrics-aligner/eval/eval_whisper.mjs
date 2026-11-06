// Whisper size study for the "GAME + Whisper" path, run in Node with
// onnxruntime-node on prepared Karaoke Battle songs (local only: the songs
// are not part of this repository).
//
//   npm install onnxruntime-node@1.22.0
//   node eval/eval_whisper.mjs --threads 4 --out results.json \
//        --model large-v3=<dir> --model small=<dir> ... <song dir> [<song dir> ...]
//
// A song dir holds vocals.wav (separated vocal stem), notes.json (GAME notes,
// {"notes":[{onset,offset,pitch}]}) and lyrics.json (truth = the primary
// track's lines). A model dir is an onnx-community Whisper export
// (onnx/encoder_model_quantized.onnx, onnx/decoder_model_merged_quantized.onnx,
// generation_config.json, vocab.json, added_tokens.json, tokenizer.json or
// merges.txt, preprocessor_config.json).
//
// Per line: |start - truth start|; reported as median, share <= 0.5 s and
// <= 1 s, worst (the app's evaluation). CER: edit distance of the
// recognised text against the truth text (letters / digits only).
import fs from 'node:fs';
import path from 'node:path';
import ort from 'onnxruntime-node';
import { alignToNotes, alignToSegments, alignWithWhisper, comparableUnits } from '../lib/lyric_align.js';
import { resample, toMono } from '../lib/resample.js';
import { SAMPLE_RATE } from '../lib/whisper.js';
import { loadWhisper } from './node_models.mjs';
import { whisperSegments } from '../lib/pipeline.js';
import { readWav } from './wav.mjs';

const args = process.argv.slice(2);
const models = [];
const songs = [];
let threads = 4, out = 'results.json', notesFile = 'notes.json', detect = false, forceLang = null;
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--model') {
    const [name, dir] = args[++i].split('=');
    models.push({ name, dir });
  } else if (args[i] === '--threads') threads = +args[++i];
  else if (args[i] === '--out') out = args[++i];
  else if (args[i] === '--notes') notesFile = args[++i];
  else if (args[i] === '--lang') forceLang = args[++i]; // Whisper language override (e.g. a wrong one)
  else if (args[i] === '--detect') detect = true; // let Whisper detect the language (the Space's default)
  else songs.push(args[i]);
}

function stats(errs) {
  const a = [...errs].sort((x, y) => x - y);
  const med = a.length % 2 ? a[(a.length - 1) / 2] : (a[a.length / 2 - 1] + a[a.length / 2]) / 2;
  const pct = (t) => Math.round((100 * a.filter((e) => e <= t).length) / a.length);
  return { median: +med.toFixed(2), le05: pct(0.5), le1: pct(1.0), worst: +a[a.length - 1].toFixed(2), n: a.length };
}

function lineErrors(pred, truth) {
  return truth.map((t, i) => Math.abs(pred[i].start - t.start));
}

function editDistance(a, b) {
  let prev = new Int32Array(b.length + 1).map((_, j) => j);
  let cur = new Int32Array(b.length + 1);
  for (let i = 1; i <= a.length; i++) {
    cur[0] = i;
    for (let j = 1; j <= b.length; j++) cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
    [prev, cur] = [cur, prev];
  }
  return prev[b.length];
}

const results = fs.existsSync(out) ? JSON.parse(fs.readFileSync(out, 'utf8')) : {};
const opts = { intraOpNumThreads: threads, interOpNumThreads: 1, graphOptimizationLevel: 'all' };
for (const song of songs) {
  const meta = JSON.parse(fs.readFileSync(path.join(song, 'meta.json'), 'utf8'));
  const lang = meta.language;
  const L = JSON.parse(fs.readFileSync(path.join(song, 'lyrics.json'), 'utf8'));
  const truth = L.tracks.find((t) => t.lang === L.primary).lines;
  const rows = truth.map((l) => l.text);
  const notes = JSON.parse(fs.readFileSync(path.join(song, notesFile), 'utf8')).notes;
  const on = notes.map((n) => n.onset), off = notes.map((n) => n.offset);
  const key = path.basename(song);
  results[key] ??= { language: lang, lines: truth.length, runs: {} };
  results[key].game = stats(lineErrors(alignToNotes(rows, on, off), truth));
  console.log(key, lang, 'GAME only', results[key].game);
  const wav = readWav(path.join(song, 'vocals.wav'));
  const audio = resample(toMono(wav.planes), wav.sr, SAMPLE_RATE);
  const truthUnits = comparableUnits(rows.join(''));
  for (const m of models) {
    const tLoad = Date.now();
    const model = await loadWhisper(m.dir, opts);
    const load = (Date.now() - tLoad) / 1000;
    const t = Date.now();
    const { segments, raw } = await whisperSegments(model, audio, detect ? null : forceLang || lang);
    const secs = (Date.now() - t) / 1000;
    const recUnits = comparableUnits(segments.map((s) => s.text).join(''));
    const r = {
      seconds: +secs.toFixed(1),
      load: +load.toFixed(1),
      windows: raw.windows,
      language: raw.language,
      segments: segments.length,
      rawSegments: raw.segments.length,
      cer: +(editDistance(recUnits, truthUnits) / truthUnits.length).toFixed(3),
      whisper: stats(lineErrors(alignWithWhisper(rows, segments, on, off), truth)),
      segmentsOnly: stats(lineErrors(alignToSegments(rows, segments, { onsets: on }), truth)),
      text: segments.map((s) => [+s.start.toFixed(2), +s.end.toFixed(2), s.text]),
    };
    results[key].runs[m.name] = r;
    console.log(key, m.name, JSON.stringify({ ...r, text: undefined }));
    fs.writeFileSync(out, JSON.stringify(results, null, 1));
    await model.encoder.release?.();
    await model.decoder.release?.();
  }
}
