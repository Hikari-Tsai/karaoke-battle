// Checks that lib/lyric_align.js gives exactly what the app's Dart code gives.
//   node eval/parity/check_parity.mjs        (needs `dart` on PATH)
// Cases are synthetic: random notes, lines made of a fixed character pool,
// Whisper-like segments with merged, garbled and hallucinated text.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import * as A from '../../lib/lyric_align.js';

const here = path.dirname(new URL(import.meta.url).pathname);
let seed = 7;
const rnd = () => ((seed = (seed * 1103515245 + 12345) % 2147483648) / 2147483648);
const pick = (s) => s[Math.floor(rnd() * s.length)];
const POOLS = ['我你他的了是在有不這個人天心愛走看想說星光雨風夜夢', 'あいうえおかきくけこさしすせそたちつてとなにぬねのきゃっ', 'ABCDEFGHIJKLMNOP'];

function makeCase(name, nLines, pool, latin) {
  const lines = [];
  for (let i = 0; i < nLines; i++) {
    const n = 3 + Math.floor(rnd() * 10);
    let s = '';
    for (let k = 0; k < n; k++) s += latin ? (k ? ' ' : '') + ['love', 'the', 'night', 'beautiful', 'go', 'time', 'fire'][Math.floor(rnd() * 7)] : pick(pool);
    lines.push(s);
  }
  const onsets = [], offsets = [];
  let t = 2 + rnd() * 5;
  const truth = [];
  for (const l of lines) {
    truth.push(t);
    const k = A.syllableCount(l) + Math.floor(rnd() * 5) - 2;
    for (let j = 0; j < Math.max(1, k); j++) {
      const d = 0.15 + rnd() * 0.5;
      onsets.push(+t.toFixed(3));
      offsets.push(+(t + d).toFixed(3));
      t += d + (rnd() < 0.15 ? rnd() * 0.4 : 0.02);
    }
    t += 0.3 + rnd() * 2;
  }
  const segments = [];
  for (let i = 0; i < lines.length; ) {
    const k = 1 + Math.floor(rnd() * 3);
    const g = lines.slice(i, i + k);
    let txt = g.join(rnd() < 0.5 ? '，' : ' ');
    if (rnd() < 0.2) txt = [...txt].filter((_, j) => j % 2 === 0).join('');
    segments.push([+(truth[i] + rnd() - 0.5).toFixed(2), +(truth[Math.min(lines.length - 1, i + k - 1)] + 2 + rnd()).toFixed(2), txt]);
    i += k;
  }
  segments.push([0.2, 1.5, '作詞：某人'], [0.0, 0.5, 'Thanks for watching!'], [1.0, 1.4, '繁體中文的歌詞']);
  segments.sort((a, b) => a[0] - b[0]);
  return { name, lines, onsets, offsets, segments };
}

const cases = [];
for (let i = 0; i < 12; i++) cases.push(makeCase(`case${i}`, 5 + Math.floor(rnd() * 30), POOLS[i % 3], i % 3 === 2));
cases.push({ name: 'empty', lines: [], onsets: [], offsets: [], segments: [] });
cases.push({ name: 'nonotes', lines: ['一二三', '四五'], onsets: [], offsets: [], segments: [[1, 2, '一二三']] });

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'align-parity-'));
const file = path.join(tmp, 'cases.json');
fs.writeFileSync(file, JSON.stringify({ cases }));
const ref = JSON.parse(execFileSync('dart', ['run', path.join(here, 'dart_ref.dart'), file], { maxBuffer: 1 << 28 }).toString());
const f = (ls) => ls.map((l) => [l.start, l.end, l.text]);
let bad = 0, total = 0;
for (const c of cases) {
  const segs = c.segments.map((s) => new A.TimedText(s[0], s[1], s[2]));
  const got = {
    notes: f(A.alignToNotes(c.lines, c.onsets, c.offsets)),
    whisper: f(A.alignWithWhisper(c.lines, segs, c.onsets, c.offsets)),
    segments: f(A.alignToSegments(c.lines, segs)),
    segments_snap: f(A.alignToSegments(c.lines, segs, { onsets: c.onsets })),
    from_segments: f(A.linesFromSegments(segs, c.onsets, c.offsets)),
    syl: c.lines.map(A.syllableCount),
    units: c.lines.map(A.comparableUnits),
    phrases: segs.map((s) => A.splitPhrases(s.text)),
    halluc: segs.map((s) => A.isLikelyHallucination(s.text)),
    echo: segs.map((s) => A.echoesPrompt(s.text, '以下是繁體中文的歌詞。')),
  };
  for (const k of Object.keys(got)) {
    total++;
    if (JSON.stringify(got[k]) !== JSON.stringify(ref[c.name][k])) {
      bad++;
      console.log('DIFF', c.name, k);
    }
  }
}
console.log(bad === 0 ? `lyric_align.js matches lyric_align.dart (${total} checks)` : `${bad} of ${total} checks differ`);
process.exit(bad ? 1 : 0);
