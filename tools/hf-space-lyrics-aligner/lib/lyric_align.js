// Timing lyrics the user pasted (plain lines, no times).
//
// JavaScript port of app/lib/state/lyric_align.dart in the Karaoke Battle
// repository (https://github.com/Hikari-Tsai/karaoke-battle). The Dart file
// is the source of truth: keep every constant and tie-break identical, and
// port changes from there to here, not the other way round.
//
//  * alignToNotes: from the transcribed notes (GAME). Notes know when
//    something is sung, not what, so lines are matched to runs of notes by
//    syllable count, preferring breaks at rests.
//  * alignWithWhisper: the notes give the exact times, Whisper's recognised
//    text where each line roughly is (a light pull).
//  * alignToSegments / linesFromSegments: from Whisper's text only.

/** A recognised piece of text with its time span (a Whisper segment). */
export class TimedText {
  constructor(start, end, text) {
    this.start = start;
    this.end = end;
    this.text = text;
  }
}

/** A timed lyric line. */
export class LyricLine {
  constructor(start, end, text) {
    this.start = start;
    this.end = end;
    this.text = text;
  }
}

/** Text Whisper is known to invent over music (credits, video outros). */
const hallucination = new RegExp(
  '^(作词|作詞|作曲|词曲|詞曲|编曲|編曲|演唱|原唱|混音|母带|母帶|监制|監製|制作人|製作人|和声|和聲|词|詞|曲)\\s*[:：]' +
    '|^(作词|作詞|作曲|词曲|詞曲|编曲|編曲|演唱|原唱|混音|和声|和聲)\\s' +
    '|字幕|订阅|訂閱|点赞|點贊|打赏|打賞|感谢观看|感謝觀看|谢谢观看|謝謝觀看|ご視聴|チャンネル登録|amara\\.org|thanks? for watching|subtitles? by|please subscribe',
  'iu',
);

export function isLikelyHallucination(text) {
  return hallucination.test(text.trim());
}

const phraseSplit =
  /[，。、！？；,.!?;]+|\s{2,}|　|(?<=[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}ー])\s+(?=[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}])/u;

/**
 * Recognised text cut into phrases (Whisper often returns a whole verse as
 * one segment): at punctuation and at spaces between CJK characters, then
 * short neighbours joined again up to maxSyllables.
 */
export function splitPhrases(text, maxSyllables = 12) {
  const parts = text
    .split(phraseSplit)
    .filter((s) => s !== undefined)
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
  const out = [];
  for (const p of parts) {
    if (out.length > 0 && syllableCount(out[out.length - 1]) + syllableCount(p) <= maxSyllables) {
      out[out.length - 1] = `${out[out.length - 1]} ${p}`;
    } else {
      out.push(p);
    }
  }
  return out;
}

/** Splits pasted text into lyric lines (trimmed, empty rows dropped). */
export function splitLyricLines(text) {
  return text
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l.length > 0);
}

// ---------------------------------------------------------------------------
// Units: what is compared and counted
// ---------------------------------------------------------------------------

const letterOrDigit = /[\p{L}\p{N}]/u;
const cjkOrKana = /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Hangul}]/u;
const smallKana = /[ゃゅょぁぃぅぇぉゎャュョァィゥェォヮ]/;

/**
 * Comparable characters of s (code points): letters and digits only, lower
 * case, full-width ASCII folded, katakana folded to hiragana.
 */
export function comparableUnits(s) {
  const out = [];
  for (const ch0 of s.toLowerCase()) {
    let c = ch0.codePointAt(0);
    if (c >= 0xff01 && c <= 0xff5e) c -= 0xfee0; // full width -> ASCII
    if (c >= 0x30a1 && c <= 0x30f6) c -= 0x60; // katakana -> hiragana
    if (letterOrDigit.test(String.fromCodePoint(c))) out.push(c);
  }
  return out;
}

/**
 * Roughly how many sung syllables (≈ notes) a line has: one per CJK
 * character or kana (small kana join the one before), one per vowel group
 * of a Latin word.
 */
export function syllableCount(line) {
  let n = 0;
  for (const ch of line) {
    if (cjkOrKana.test(ch) && !smallKana.test(ch) && ch !== 'ー') n++;
  }
  for (const m of line.matchAll(/[A-Za-zÀ-ÿ]+/g)) {
    const w = m[0];
    const groups = (w.match(/[aeiouyàâäéèêëïîôöùûü]+/gi) || []).length;
    let s = Math.max(1, groups);
    const lw = w.toLowerCase();
    if (s > 1 && lw.endsWith('e') && !lw.endsWith('le')) s--; // silent e
    n += s;
  }
  return Math.max(1, n);
}

// ---------------------------------------------------------------------------
// GAME notes
// ---------------------------------------------------------------------------

/**
 * Times lines from notes (onsets / offsets, sorted). Each line gets a
 * contiguous run of notes; notes between lines may be left over (ad-libs,
 * backing vocals). Returns one LyricLine per input line.
 */
export function alignToNotes(
  lines,
  onsets,
  offsets,
  {
    // Tuned on a Chinese and a Japanese song against their YouTube subtitles.
    skipCost = 0.2, // per note left out
    mismatchCost = 2.0, // per relative syllable difference
    restReward = 0.5, // for a line boundary on a rest (per second, capped at 1 s)
    startHints = null, // where each line probably starts (from Whisper), or null
    hintWeight = 0.1, // per second away from the hint, up to hintCap
    hintCap = 2.0,
  } = {},
) {
  const n = onsets.length;
  const l = lines.length;
  if (l === 0) return [];
  if (n === 0) return spread(lines, 0, lines.length * 3.0);
  const syl = lines.map(syllableCount);
  // Rest before note k (0 for the first note) and after note k.
  const restBefore = (k) => (k <= 0 ? 1.0 : Math.max(0.0, onsets[k] - offsets[k - 1]));
  const restAfter = (k) => (k >= n - 1 ? 1.0 : Math.max(0.0, onsets[k + 1] - offsets[k]));

  const lineCost = (i, from, to) => {
    const count = to - from;
    const s = syl[i];
    let c = (mismatchCost * Math.abs(count - s)) / s;
    const hint = startHints != null && i < startHints.length ? startHints[i] : null;
    if (hint != null) c += hintWeight * Math.min(Math.abs(onsets[from] - hint), hintCap);
    c -= restReward * Math.min(restBefore(from), 1.0);
    c -= restReward * Math.min(restAfter(to - 1), 1.0);
    return c;
  };

  const inf = 1e18;
  // best[i][j]: cost of placing lines < i using notes < j (line i-1 ends at j).
  const best = Array.from({ length: l + 1 }, () => new Float64Array(n + 1).fill(inf));
  const lineStart = Array.from({ length: l + 1 }, () => new Int32Array(n + 1));
  const prevEnd = Array.from({ length: l + 1 }, () => new Int32Array(n + 1));
  best[0][0] = 0;
  for (let i = 0; i < l; i++) {
    // Leaving notes out before line i: running minimum with a per-note cost.
    const start = new Float64Array(n + 1);
    const startAt = new Int32Array(n + 1);
    for (let k = 0; k <= n; k++) {
      const skipped = k === 0 ? inf : start[k - 1] + skipCost;
      if (best[i][k] <= skipped) {
        start[k] = best[i][k];
        startAt[k] = k;
      } else {
        start[k] = skipped;
        startAt[k] = startAt[k - 1];
      }
    }
    const maxLen = syl[i] * 3 + 6;
    for (let k = 0; k < n; k++) {
      if (start[k] >= inf) continue;
      const jEnd = Math.min(n, k + maxLen);
      for (let j = k + 1; j <= jEnd; j++) {
        const c = start[k] + lineCost(i, k, j);
        if (c < best[i + 1][j]) {
          best[i + 1][j] = c;
          lineStart[i + 1][j] = k;
          prevEnd[i + 1][j] = startAt[k];
        }
      }
    }
  }
  // Notes after the last line are left out too.
  let end = 0;
  let endCost = inf;
  for (let j = 0; j <= n; j++) {
    const c = best[l][j] + skipCost * (n - j);
    if (c < endCost) {
      endCost = c;
      end = j;
    }
  }
  if (endCost >= inf) return spread(lines, onsets[0], offsets[offsets.length - 1]);
  const spans = new Array(l);
  for (let i = l; i > 0; i--) {
    spans[i - 1] = [lineStart[i][end], end];
    end = prevEnd[i][end];
  }
  return lines.map((t, i) => new LyricLine(onsets[spans[i][0]], offsets[spans[i][1] - 1], t));
}

/** Evenly spread lines over [start, end] (nothing to align to). */
function spread(lines, start, end) {
  const step = (end - start) / lines.length;
  return lines.map((t, i) => new LyricLine(start + i * step, start + (i + 0.9) * step, t));
}

// ---------------------------------------------------------------------------
// Whisper segments
// ---------------------------------------------------------------------------

/**
 * Times lines with both: the notes give the exact times, Whisper's
 * recognised text where each line roughly is (a light pull, so it only
 * matters where counting notes alone would drift onto the wrong phrase).
 */
export function alignWithWhisper(lines, segments, onsets, offsets) {
  if (onsets.length === 0) return alignToSegments(lines, segments);
  const m = segmentMatch(lines, segments);
  // Whisper's line starts came out ~0.3 s early against subtitle timings.
  return alignToNotes(lines, onsets, offsets, { startHints: m.matched.map((h) => (h == null ? null : h + 0.3)) });
}

/**
 * Lyric lines from recognised segments: a segment may hold a whole verse,
 * so it is cut into phrases at punctuation, which are timed on the notes
 * sung within it.
 */
export function linesFromSegments(segments, onsets, offsets) {
  const lines = [];
  for (const s of segments) {
    const phrases = splitPhrases(s.text);
    if (phrases.length === 0) continue;
    const on = [];
    const off = [];
    for (let i = 0; i < onsets.length; i++) {
      if (onsets[i] >= s.start - 0.4 && onsets[i] < s.end) {
        on.push(onsets[i]);
        off.push(offsets[i]);
      }
    }
    const timed =
      phrases.length > 1 && on.length >= phrases.length
        ? alignToNotes(phrases, on, off)
        : [new LyricLine(snapToOnset(onsets, s.start), s.end, phrases.join(' '))];
    for (const l of timed) {
      const last = lines[lines.length - 1];
      const start = last && l.start < last.end ? last.end : l.start;
      if (l.end > start) lines.push(new LyricLine(start, l.end, l.text));
    }
  }
  return lines;
}

/**
 * True when text only repeats the style prompt (Whisper sometimes
 * continues the prompt instead of listening).
 */
export function echoesPrompt(text, prompt) {
  const t = String.fromCodePoint(...comparableUnits(text));
  return t.length > 0 && String.fromCodePoint(...comparableUnits(prompt)).includes(t);
}

/**
 * Times lines from recognised segments only. Lines without enough matched
 * characters are placed between their neighbours by length. With note
 * onsets, line starts snap to the nearest onset within 0.4 s.
 */
export function alignToSegments(lines, segments, { onsets = null } = {}) {
  const l = lines.length;
  if (l === 0) return [];
  const m = segmentMatch(lines, segments);
  const start = [...m.matched];
  const end = [...m.matchedEnd];
  const lineUnits = m.units;
  // Unmatched lines: between their neighbours, by length.
  for (let i = 0; i < l; ) {
    if (start[i] != null) {
      i++;
      continue;
    }
    let j = i;
    while (j < l && start[j] == null) j++;
    const from = i > 0 ? end[i - 1] : j < l ? Math.max(0.0, start[j] - 3.0 * (j - i)) : 0.0;
    const to = j < l ? start[j] : from + 3.0 * (j - i);
    let total = 0;
    for (let k = i; k < j; k++) total += Math.max(1, lineUnits[k]);
    let t = from;
    for (let k = i; k < j; k++) {
      const d = ((to - from) * Math.max(1, lineUnits[k])) / total;
      start[k] = t;
      end[k] = t + d * 0.9;
      t += d;
    }
    i = j;
  }
  // Snap starts to note onsets, keep order and positive lengths.
  const out = [];
  for (let i = 0; i < l; i++) {
    let s = start[i];
    if (onsets != null) s = snapToOnset(onsets, s);
    if (out.length > 0 && s < out[out.length - 1].start + 0.05) s = out[out.length - 1].start + 0.05;
    const e = Math.max(end[i], s + 0.3);
    out.push(new LyricLine(s, e, lines[i]));
  }
  for (let i = 0; i + 1 < out.length; i++) {
    if (out[i].end > out[i + 1].start) {
      out[i] = new LyricLine(out[i].start, Math.max(out[i].start + 0.05, out[i + 1].start), out[i].text);
    }
  }
  return out;
}

/**
 * Start / end of each line from the recognised characters it matched (null
 * when too few matched), and each line's character count.
 */
export function segmentMatch(lines, segments) {
  const l = lines.length;
  // Recognised units with their times.
  const rec = [];
  const recTime = [];
  const recSegStart = [];
  const recSegEnd = [];
  for (const s of segments) {
    const u = comparableUnits(s.text);
    for (let k = 0; k < u.length; k++) {
      rec.push(u[k]);
      recTime.push(s.start + ((k + 0.5) / u.length) * (s.end - s.start));
      recSegStart.push(k === 0 ? s.start : null);
      recSegEnd.push(k === u.length - 1 ? s.end : null);
    }
  }
  // Lyric units with their line and position in it.
  const lyr = [];
  const lineUnits = [];
  for (let i = 0; i < l; i++) {
    const u = comparableUnits(lines[i]);
    lineUnits.push(u.length);
    for (const c of u) lyr.push(c);
  }
  const match = lcs(lyr, rec); // lyric unit -> recognised unit or -1

  const start = new Array(l).fill(null);
  const end = new Array(l).fill(null);
  let u0 = 0;
  for (let i = 0; i < l; i++) {
    const len = lineUnits[i];
    const hits = []; // [position in line, recognised index]
    for (let k = 0; k < len; k++) {
      const r = match[u0 + k];
      if (r >= 0) hits.push([k, r]);
    }
    u0 += len;
    if (hits.length === 0 || hits.length < Math.max(1, Math.ceil(len * 0.25))) continue;
    const first = hits[0];
    const last = hits[hits.length - 1];
    const rate =
      hits.length >= 2 && last[0] > first[0]
        ? clamp((recTime[last[1]] - recTime[first[1]]) / (last[0] - first[0]), 0.08, 0.8)
        : 0.3;
    start[i] = first[0] === 0 && recSegStart[first[1]] != null ? recSegStart[first[1]] : recTime[first[1]] - (first[0] + 0.5) * rate;
    end[i] = last[0] === len - 1 && recSegEnd[last[1]] != null ? recSegEnd[last[1]] : recTime[last[1]] + (len - last[0] - 0.5) * rate;
  }
  return { matched: start, matchedEnd: end, units: lineUnits };
}

function clamp(x, lo, hi) {
  return x < lo ? lo : x > hi ? hi : x;
}

/** t moved to the nearest of the sorted note onsets when one is within `within` seconds. */
export function snapToOnset(sorted, t, within = 0.4) {
  if (sorted.length === 0) return t;
  const o = nearest(sorted, t);
  return Math.abs(o - t) <= within ? o : t;
}

function nearest(sorted, t) {
  let lo = 0;
  let hi = sorted.length - 1;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (sorted[mid] < t) lo = mid + 1;
    else hi = mid;
  }
  const a = sorted[lo];
  const b = lo > 0 ? sorted[lo - 1] : a;
  return Math.abs(a - t) < Math.abs(b - t) ? a : b;
}

/**
 * Longest common subsequence of a and b: for each index of a the matched
 * index of b, or -1.
 */
export function lcs(a, b) {
  const n = a.length;
  const m = b.length;
  const out = new Array(n).fill(-1);
  if (n === 0 || m === 0) return out;
  // Direction table: 0 diag, 1 up, 2 left.
  const dir = new Uint8Array(n * m);
  let prev = new Int32Array(m + 1);
  let cur = new Int32Array(m + 1);
  for (let i = 1; i <= n; i++) {
    const ai = a[i - 1];
    const row = (i - 1) * m;
    for (let j = 1; j <= m; j++) {
      if (ai === b[j - 1]) {
        cur[j] = prev[j - 1] + 1;
        dir[row + j - 1] = 0;
      } else if (prev[j] >= cur[j - 1]) {
        cur[j] = prev[j];
        dir[row + j - 1] = 1;
      } else {
        cur[j] = cur[j - 1];
        dir[row + j - 1] = 2;
      }
    }
    const t = prev;
    prev = cur;
    cur = t;
    cur.fill(0);
  }
  let i = n;
  let j = m;
  while (i > 0 && j > 0) {
    switch (dir[(i - 1) * m + (j - 1)]) {
      case 0:
        if (a[i - 1] === b[j - 1]) out[i - 1] = j - 1;
        i--;
        j--;
        break;
      case 1:
        i--;
        break;
      default:
        j--;
    }
  }
  return out;
}
