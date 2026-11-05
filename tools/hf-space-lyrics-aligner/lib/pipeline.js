// Glue between the models and the alignment, as the app's
// app/lib/services/lyrics_recognizer.dart: language / style prompt rules,
// the filters on Whisper's segments, and SRT / LRC output.
import { TimedText, alignToNotes, alignWithWhisper, echoesPrompt, isLikelyHallucination, linesFromSegments, splitLyricLines } from './lyric_align.js';

/** Style prompts: Whisper writes Simplified Chinese unless the context is
 * Traditional. Other languages get none (a Japanese prompt was echoed back
 * instead of the lyrics). As app/lib/services/lyrics_recognizer.dart. */
export const STYLE_PROMPTS = { zh: '以下是繁體中文的歌詞。', yue: '以下係粵語歌詞。' };

/**
 * Whisper on the 16 kHz vocal stem -> filtered TimedText segments.
 * language: 'zh' | 'yue' | 'ja' | 'en' | 'ko', or null to detect it.
 */
export async function whisperSegments(model, vocals16k, language, onProgress) {
  const r = await model.recognize(vocals16k, {
    language: language || null,
    prompt: language ? STYLE_PROMPTS[language] ?? '' : '',
    promptByLanguage: STYLE_PROMPTS,
    condition: true,
    onProgress,
  });
  const prompts = Object.values(STYLE_PROMPTS);
  const segs = r.segments
    .map((s) => new TimedText(s.start, s.end, s.text))
    .filter((s) => s.text.length > 0 && !isLikelyHallucination(s.text) && !prompts.some((p) => echoesPrompt(s.text, p)));
  return { segments: segs, raw: r };
}

/**
 * Pasted text + notes (+ Whisper segments) -> timed lines. Without pasted
 * lines and with segments, the recognised text itself becomes the lyrics.
 */
export function timeLyrics(text, notes, segments = null) {
  const rows = splitLyricLines(text || '');
  const on = notes.map((n) => n.onset);
  const off = notes.map((n) => n.offset);
  if (rows.length === 0) return segments ? linesFromSegments(segments, on, off) : [];
  return segments ? alignWithWhisper(rows, segments, on, off) : alignToNotes(rows, on, off);
}

function pad(n, w = 2) {
  return String(n).padStart(w, '0');
}

function srtTime(t) {
  const ms = Math.max(0, Math.round(t * 1000));
  return `${pad(Math.floor(ms / 3600000))}:${pad(Math.floor(ms / 60000) % 60)}:${pad(Math.floor(ms / 1000) % 60)},${pad(ms % 1000, 3)}`;
}

function lrcTime(t) {
  const cs = Math.max(0, Math.round(t * 100));
  return `[${pad(Math.floor(cs / 6000))}:${pad(Math.floor(cs / 100) % 60)}.${pad(cs % 100)}]`;
}

/** Lines shifted by offset seconds (positive = later). */
export function shifted(lines, offset) {
  return lines.map((l) => ({ start: Math.max(0, l.start + offset), end: Math.max(0, l.end + offset), text: l.text }));
}

export function toSrt(lines) {
  return lines.map((l, i) => `${i + 1}\n${srtTime(l.start)} --> ${srtTime(Math.max(l.end, l.start + 0.05))}\n${l.text}\n`).join('\n');
}

export function toLrc(lines, { title = '' } = {}) {
  const head = title ? `[ti:${title}]\n` : '';
  return head + lines.map((l) => `${lrcTime(l.start)}${l.text}`).join('\n') + '\n';
}

export function fmtTime(t) {
  const cs = Math.max(0, Math.round(t * 100));
  return `${Math.floor(cs / 6000)}:${pad(Math.floor(cs / 100) % 60)}.${pad(cs % 100)}`;
}
