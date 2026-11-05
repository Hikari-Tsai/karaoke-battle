// GAME Large vs Small for the default "notes" path: transcribes each song's
// vocals.wav with this repository's GAME port and times the truth lines
// with alignToNotes (same metric as eval_whisper.mjs). Local songs only.
//
//   node eval/eval_game.mjs --threads 4 --runs 5 --model large=<dir> --model small=<dir> <song dir> ...
import fs from 'node:fs';
import path from 'node:path';
import ort from 'onnxruntime-node';
import { alignToNotes } from '../lib/lyric_align.js';
import { GameModel } from '../lib/game.js';
import { toMono } from '../lib/resample.js';
import { readWav } from './wav.mjs';

const args = process.argv.slice(2);
const models = [];
const songs = [];
let threads = 4, runs = 1;
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--model') {
    const [name, dir] = args[++i].split('=');
    models.push({ name, dir });
  } else if (args[i] === '--threads') threads = +args[++i];
  else if (args[i] === '--runs') runs = +args[++i];
  else songs.push(args[i]);
}

function stats(errs) {
  const a = [...errs].sort((x, y) => x - y);
  const med = a.length % 2 ? a[(a.length - 1) / 2] : (a[a.length / 2 - 1] + a[a.length / 2]) / 2;
  const pct = (t) => Math.round((100 * a.filter((e) => e <= t).length) / a.length);
  return { median: +med.toFixed(2), le05: pct(0.5), le1: pct(1.0), worst: +a[a.length - 1].toFixed(2) };
}

const opts = { intraOpNumThreads: threads, graphOptimizationLevel: 'all' };
for (const song of songs) {
  const meta = JSON.parse(fs.readFileSync(path.join(song, 'meta.json'), 'utf8'));
  const L = JSON.parse(fs.readFileSync(path.join(song, 'lyrics.json'), 'utf8'));
  const truth = L.tracks.find((t) => t.lang === L.primary).lines;
  const rows = truth.map((l) => l.text);
  const mono = toMono(readWav(path.join(song, 'vocals.wav')).planes);
  const score = (notes) => stats(alignToNotes(rows, notes.map((n) => n.onset), notes.map((n) => n.offset)).map((p, i) => Math.abs(p.start - truth[i].start)));
  for (const f of ['notes.json', 'notes.orig.json']) {
    const p = path.join(song, f);
    if (fs.existsSync(p)) console.log(path.basename(song), meta.language, `app ${f}`, JSON.stringify(score(JSON.parse(fs.readFileSync(p, 'utf8')).notes)));
  }
  for (const m of models) {
    const s = {};
    for (const k of ['encoder', 'segmenter', 'estimator', 'bd2dur']) s[k] = await ort.InferenceSession.create(path.join(m.dir, `${k}.onnx`), opts);
    const game = new GameModel(ort, s, JSON.parse(fs.readFileSync(path.join(m.dir, 'config.json'), 'utf8')));
    // The segmenter samples (RandomUniformLike in the D3PM loop), so every run differs: several runs.
    for (let r = 0; r < runs; r++) {
      const t = Date.now();
      const notes = await game.transcribe(mono, { language: meta.language });
      const secs = (Date.now() - t) / 1000;
      console.log(path.basename(song), meta.language, `GAME ${m.name} run ${r + 1}`, JSON.stringify({ seconds: +secs.toFixed(1), notes: notes.length, ...score(notes) }));
    }
  }
}
