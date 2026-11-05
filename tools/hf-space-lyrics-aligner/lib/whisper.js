// Whisper recognition with the onnx-community ONNX exports (encoder_model +
// decoder_model_merged with KV cache). Port of the app's
// engine/src/models/whisper.cpp (front end, greedy decoding with the
// reference timestamp rules, long-form seeking, unsung-stretch filter) and
// app/lib/state/whisper_tokenizer.dart (byte-level BPE).
//
//   16 kHz mono -> 30 s windows -> log-mel (n_fft 400, hop 160, 80/128
//   Slaney mel bands, log10, max-8 clamp, (x+4)/4) -> encoder -> greedy
//   decoding -> segments.
import { FFT } from './fft.js';

export const SAMPLE_RATE = 16000;
const N_FFT = 400;
const HOP = 160;
const WINDOW_FRAMES = 3000; // 30 s of mel frames
const WINDOW_SAMPLES = WINDOW_FRAMES * HOP;

// ---------------------------------------------------------------------------
// Tokenizer
// ---------------------------------------------------------------------------

const byteToUnicode = (() => {
  const bs = [];
  for (let b = 0x21; b <= 0x7e; b++) bs.push(b);
  for (let b = 0xa1; b <= 0xac; b++) bs.push(b);
  for (let b = 0xae; b <= 0xff; b++) bs.push(b);
  const cs = [...bs];
  let n = 0;
  for (let b = 0; b < 256; b++) {
    if (!bs.includes(b)) {
      bs.push(b);
      cs.push(256 + n);
      n++;
    }
  }
  const m = new Map();
  bs.forEach((b, i) => m.set(b, cs[i]));
  return m;
})();
const unicodeToByte = new Map([...byteToUnicode].map(([b, c]) => [c, b]));
const pretokenize = /'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+/gu;

export class WhisperTokenizer {
  /** vocab: {token: id}, added: {special: id}, merges: [[a, b], ...] */
  constructor(vocab, added, merges) {
    this.toId = new Map(Object.entries({ ...vocab, ...added }));
    this.specials = new Map(Object.entries(added));
    this.toToken = new Map();
    for (const [t, id] of this.toId) this.toToken.set(id, t);
    this.ranks = new Map(merges.map((m, i) => [`${m[0]} ${m[1]}`, i]));
    this.cache = new Map();
  }

  /** merges from merges.txt text or tokenizer.json object. */
  static parseMerges(src) {
    const list = typeof src === 'string' ? src.split('\n').filter((l) => l && !l.startsWith('#version')) : src.model.merges;
    return list.map((m) => {
      if (Array.isArray(m)) return m;
      const i = m.indexOf(' ');
      return [m.slice(0, i), m.slice(i + 1)];
    });
  }

  special(token) {
    return this.specials.get(token);
  }

  get eot() {
    return this.specials.get('<|endoftext|>') ?? 50257;
  }

  /** Text of ids; special tokens and timestamps are skipped. */
  decode(ids) {
    const bytes = [];
    const eot = this.eot;
    for (const id of ids) {
      if (id >= eot) continue;
      const tok = this.toToken.get(id);
      if (tok == null) continue;
      for (const ch of tok) {
        const b = unicodeToByte.get(ch.codePointAt(0));
        if (b != null) bytes.push(b);
      }
    }
    return new TextDecoder('utf-8').decode(new Uint8Array(bytes));
  }

  /** Token ids of plain text (no special tokens). */
  encode(text) {
    const out = [];
    const enc = new TextEncoder();
    for (const m of text.matchAll(pretokenize)) {
      const piece = String.fromCodePoint(...[...enc.encode(m[0])].map((b) => byteToUnicode.get(b)));
      for (const t of this.bpe(piece)) {
        const id = this.toId.get(t);
        if (id != null) out.push(id);
      }
    }
    return out;
  }

  bpe(token) {
    const cached = this.cache.get(token);
    if (cached) return cached;
    let word = [...token];
    while (word.length > 1) {
      let best = -1;
      let bestRank = 1 << 30;
      for (let i = 0; i + 1 < word.length; i++) {
        const r = this.ranks.get(`${word[i]} ${word[i + 1]}`);
        if (r != null && r < bestRank) {
          bestRank = r;
          best = i;
        }
      }
      if (best < 0) break;
      const a = word[best], b = word[best + 1];
      const next = [];
      for (let i = 0; i < word.length; ) {
        if (i + 1 < word.length && word[i] === a && word[i + 1] === b) {
          next.push(a + b);
          i += 2;
        } else {
          next.push(word[i]);
          i++;
        }
      }
      word = next;
    }
    if (this.cache.size < 20000) this.cache.set(token, word);
    return word;
  }
}

// ---------------------------------------------------------------------------
// Front end
// ---------------------------------------------------------------------------

function hzToMel(f) {
  const minLogHz = 1000.0, minLogMel = 15.0, logstep = 27.0 / Math.log(6.4);
  return f < minLogHz ? (3.0 * f) / 200.0 : minLogMel + Math.log(f / minLogHz) * logstep;
}

function melToHz(m) {
  const minLogHz = 1000.0, minLogMel = 15.0, logstep = Math.log(6.4) / 27.0;
  return m < minLogMel ? (200.0 * m) / 3.0 : minLogHz * Math.exp(logstep * (m - minLogMel));
}

/** Slaney mel filter bank, nMels x (N_FFT/2+1), row-major. */
export function melFilters(nMels) {
  const bins = N_FFT / 2 + 1;
  const fftFreqs = new Float64Array(bins);
  for (let k = 0; k < bins; k++) fftFreqs[k] = ((SAMPLE_RATE / 2.0) * k) / (bins - 1);
  const melMin = hzToMel(0.0), melMax = hzToMel(SAMPLE_RATE / 2.0);
  const f = new Float64Array(nMels + 2);
  for (let i = 0; i < nMels + 2; i++) f[i] = melToHz(melMin + ((melMax - melMin) * i) / (nMels + 1));
  const out = new Float32Array(nMels * bins);
  for (let m = 0; m < nMels; m++) {
    const enorm = 2.0 / (f[m + 2] - f[m]);
    for (let k = 0; k < bins; k++) {
      const down = (fftFreqs[k] - f[m]) / (f[m + 1] - f[m]);
      const up = (f[m + 2] - fftFreqs[k]) / (f[m + 2] - f[m + 1]);
      out[m * bins + k] = Math.max(0.0, Math.min(down, up)) * enorm;
    }
  }
  return out;
}

const fft400 = new FFT(N_FFT);
const hann400 = (() => {
  const w = new Float64Array(N_FFT);
  for (let j = 0; j < N_FFT; j++) w[j] = 0.5 - 0.5 * Math.cos((2.0 * Math.PI * j) / N_FFT);
  return w;
})();

/** Log-mel features of one window (n samples, zero padded to 30 s): nMels x 3000. */
export function logMel(samples, from, n, filters, nMels) {
  const bins = N_FFT / 2 + 1;
  const len = WINDOW_SAMPLES;
  const x = (i) => (i >= 0 && i < n ? samples[from + i] : 0.0);
  const buf = new Float64Array(2 * N_FFT);
  const spec = new Float64Array(2 * N_FFT);
  const power = new Float64Array(bins);
  const logspec = new Float64Array(nMels * WINDOW_FRAMES);
  let peak = -Infinity;
  for (let t = 0; t < WINDOW_FRAMES; t++) {
    for (let j = 0; j < N_FFT; j++) {
      let i = t * HOP + j - N_FFT / 2;
      if (i < 0) i = -i;
      if (i >= len) i = 2 * len - 2 - i;
      buf[2 * j] = x(i) * hann400[j];
      buf[2 * j + 1] = 0;
    }
    fft400.transform(buf, spec);
    for (let k = 0; k < bins; k++) power[k] = spec[2 * k] * spec[2 * k] + spec[2 * k + 1] * spec[2 * k + 1];
    for (let m = 0; m < nMels; m++) {
      let acc = 0;
      const row = m * bins;
      for (let k = 0; k < bins; k++) acc += filters[row + k] * power[k];
      const v = Math.log10(Math.max(acc, 1e-10));
      logspec[m * WINDOW_FRAMES + t] = v;
      if (v > peak) peak = v;
    }
  }
  const out = new Float32Array(logspec.length);
  for (let i = 0; i < logspec.length; i++) out[i] = (Math.max(logspec[i], peak - 8.0) + 4.0) / 4.0;
  return out;
}

/**
 * Singing activity per 10 ms frame of the 16 kHz vocal stem: frames within
 * `hold` frames of one louder than (95th percentile - rangeDb). Relative to
 * the loud part of the stem, so instrument bleed in a separated stem's
 * intro does not count (Whisper invents text such as credits there).
 */
export function voicedFrames(audio, rangeDb = 22.0, hold = 30) {
  const frames = Math.floor(audio.length / HOP);
  if (frames === 0) return new Uint8Array(0);
  const db = new Float64Array(frames);
  for (let t = 0; t < frames; t++) {
    let e = 0;
    for (let j = 0; j < HOP; j++) e += audio[t * HOP + j] * audio[t * HOP + j];
    db[t] = 10.0 * Math.log10(e / HOP + 1e-12);
  }
  const sorted = Float64Array.from(db).sort();
  const k95 = Math.min(frames - 1, Math.floor(0.95 * frames));
  const thr = Math.max(sorted[k95] - rangeDb, -70.0);
  const out = new Uint8Array(frames);
  let last = -1000000;
  for (let t = 0; t < frames; t++) {
    if (db[t] > thr) last = t;
    if (t - last <= hold) out[t] = 1;
  }
  let next = 1000000000;
  for (let t = frames - 1; t >= 0; t--) {
    if (db[t] > thr) next = t;
    if (next - t <= hold) out[t] = 1;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Decoder with KV cache
// ---------------------------------------------------------------------------

function tokensFrom(gen) {
  const t = {
    eot: gen.eos_token_id ?? 50257,
    sot: gen.decoder_start_token_id ?? 50258,
    noTimestamps: gen.no_timestamps_token_id ?? 50364,
    maxInitialTs: gen.max_initial_timestamp_index ?? 50,
    suppress: gen.suppress_tokens ?? [],
    beginSuppress: gen.begin_suppress_tokens ?? [],
  };
  t.tsBegin = t.noTimestamps + 1;
  t.noSpeech = t.noTimestamps - 1; // <|nospeech|> / <|nocaptions|> precedes <|notimestamps|>
  t.sotPrev = gen.prev_sot_token_id ?? t.noSpeech - 1;
  return t;
}

/**
 * session.run with a fetch list, keyed by fetch name. onnxruntime-node
 * (1.22 / 1.23) labels the results of a partial fetch list with the
 * session's first output names, in fetch order; map them by position then.
 */
async function runFetch(session, feeds, fetch) {
  const res = await session.run(feeds, fetch);
  if (fetch.every((n) => n in res)) return res;
  const vals = Object.values(res);
  return Object.fromEntries(fetch.map((n, i) => [n, vals[i]]));
}

class Decoder {
  constructor(ort, session) {
    this.ort = ort;
    this.session = session;
    this.layers = session.inputNames.filter((n) => n.startsWith('past_key_values.') && n.includes('.decoder.key')).length;
    if (!this.layers || !session.inputNames.includes('use_cache_branch')) throw new Error('whisper: decoder_model_merged expected');
    this.past = [];
    this.present = [];
    for (let l = 0; l < this.layers; l++) {
      for (const part of ['decoder.key', 'decoder.value', 'encoder.key', 'encoder.value']) {
        this.past.push(`past_key_values.${l}.${part}`);
        this.present.push(`present.${l}.${part}`);
      }
    }
  }

  common(ids, useCache) {
    const T = this.ort.Tensor;
    return {
      input_ids: new T('int64', BigInt64Array.from(ids.map(BigInt)), [1, ids.length]),
      encoder_hidden_states: this.enc,
      use_cache_branch: new T('bool', new Uint8Array([useCache ? 1 : 0]), [1]),
    };
  }

  /** Starts a window on encoder output enc (an ort.Tensor); returns logits of every prefix position. */
  async start(enc, prefix, heads, headDim) {
    this.enc = enc;
    const feeds = this.common(prefix, false);
    const empty = new this.ort.Tensor('float32', new Float32Array(0), [1, heads, 0, headDim]);
    for (const n of this.past) feeds[n] = empty;
    const out = await runFetch(this.session, feeds, ['logits', ...this.present]);
    this.self = [];
    this.cross = [];
    for (let l = 0; l < this.layers; l++) {
      this.self.push(out[this.present[l * 4]], out[this.present[l * 4 + 1]]);
      this.cross.push(out[this.present[l * 4 + 2]], out[this.present[l * 4 + 3]]);
    }
    return out.logits;
  }

  /** Feeds one more token; returns its logits (1 x 1 x vocab). */
  async step(token) {
    const feeds = this.common([token], true);
    const fetch = ['logits'];
    for (let l = 0; l < this.layers; l++) {
      fetch.push(this.present[l * 4], this.present[l * 4 + 1]);
      feeds[this.past[l * 4]] = this.self[l * 2];
      feeds[this.past[l * 4 + 1]] = this.self[l * 2 + 1];
      feeds[this.past[l * 4 + 2]] = this.cross[l * 2];
      feeds[this.past[l * 4 + 3]] = this.cross[l * 2 + 1];
    }
    // Only logits and the self-attention cache: the cross-attention cache
    // is unchanged and large (≈ 0.5 GB per step for large-v3).
    const out = await runFetch(this.session, feeds, fetch);
    this.self = [];
    for (let l = 0; l < this.layers; l++) this.self.push(out[this.present[l * 4]], out[this.present[l * 4 + 1]]);
    return out.logits;
  }

  reset() {
    this.self = [];
    this.cross = [];
  }
}

function logSoftmax(x, out) {
  let mx = -Infinity;
  for (let i = 0; i < x.length; i++) if (x[i] > mx) mx = x[i];
  let sum = 0;
  for (let i = 0; i < x.length; i++) sum += Math.exp(x[i] - mx);
  const lse = mx + Math.log(sum);
  for (let i = 0; i < x.length; i++) out[i] = x[i] - lse;
  return out;
}

/** True when the tail of seq is a unit of <= 4 tokens repeated >= 8 times. */
function repetitionLoop(seq) {
  for (let unit = 1; unit <= 4; unit++) {
    const need = unit * 8;
    if (seq.length < need) continue;
    let same = true;
    for (let i = seq.length - need; i + unit < seq.length && same; i++) same = seq[i] === seq[i + unit];
    if (same) return true;
  }
  return false;
}

/** True when the text tokens of seq are all a contiguous part of prompt (the model echoed its prompt). */
function echoes(seq, prompt, eot) {
  const text = seq.filter((t) => t < eot);
  if (text.length < 2 || prompt.length < text.length) return false;
  outer: for (let i = 0; i + text.length <= prompt.length; i++) {
    for (let k = 0; k < text.length; k++) if (prompt[i + k] !== text[k]) continue outer;
    return true;
  }
  return false;
}

async function decodeWindow(dec, tk, enc, prefix, sotIndex, maxTokens, heads, headDim) {
  const r = { tokens: [], sumLogprob: 0, noSpeech: 0, looped: false };
  const lg = await dec.start(enc, prefix, heads, headDim);
  const vocab = lg.dims[2];
  const all = lg.data;
  let logprobs = new Float32Array(vocab);
  logSoftmax(all.subarray(sotIndex * vocab, (sotIndex + 1) * vocab), logprobs);
  r.noSpeech = Math.exp(logprobs[tk.noSpeech]);
  let cur = Float32Array.from(all.subarray(all.length - vocab));
  const suppressed = new Uint8Array(vocab);
  for (const t of tk.suppress) if (t >= 0 && t < vocab) suppressed[t] = 1;
  for (let t = tk.eot + 1; t < tk.tsBegin && t < vocab; t++) suppressed[t] = 1; // special tokens
  const seq = r.tokens;
  const isTs = (t) => t >= tk.tsBegin;
  for (let step = 0; step < maxTokens; step++) {
    for (let i = 0; i < vocab; i++) if (suppressed[i]) cur[i] = -Infinity;
    if (step === 0) for (const t of tk.beginSuppress) if (t >= 0 && t < vocab) cur[t] = -Infinity;
    const lastTs = seq.length > 0 && isTs(seq[seq.length - 1]);
    const penultTs = seq.length < 2 || isTs(seq[seq.length - 2]);
    if (lastTs) {
      if (penultTs) for (let i = tk.tsBegin; i < vocab; i++) cur[i] = -Infinity; // text next
      else for (let i = 0; i < tk.eot; i++) cur[i] = -Infinity; // timestamp or end next
    }
    let lastStamp = -1;
    for (let i = seq.length - 1; i >= 0; i--) {
      if (isTs(seq[i])) {
        lastStamp = seq[i];
        break;
      }
    }
    if (lastStamp >= 0) {
      // Timestamps never go back; a closed segment's end may be reused as the next start only right after it.
      const floor = lastTs && !penultTs ? lastStamp : lastStamp + 1;
      for (let i = tk.tsBegin; i < floor && i < vocab; i++) cur[i] = -Infinity;
    }
    if (step === 0) {
      for (let i = 0; i < tk.tsBegin; i++) cur[i] = -Infinity; // start with a timestamp
      for (let i = tk.tsBegin + tk.maxInitialTs + 1; i < vocab; i++) cur[i] = -Infinity;
    }
    logSoftmax(cur, logprobs);
    {
      // Timestamp when its total probability beats any single text token.
      let tsMax = -Infinity;
      for (let i = tk.tsBegin; i < vocab; i++) if (logprobs[i] > tsMax) tsMax = logprobs[i];
      if (tsMax > -Infinity) {
        let tsSum = 0;
        for (let i = tk.tsBegin; i < vocab; i++) tsSum += Math.exp(logprobs[i] - tsMax);
        const tsLse = tsMax + Math.log(tsSum);
        let textMax = -Infinity;
        for (let i = 0; i < tk.tsBegin; i++) if (logprobs[i] > textMax) textMax = logprobs[i];
        if (tsLse > textMax) for (let i = 0; i < tk.tsBegin; i++) logprobs[i] = -Infinity;
      }
    }
    let best = 0;
    for (let i = 1; i < vocab; i++) if (logprobs[i] > logprobs[best]) best = i;
    if (logprobs[best] === -Infinity) break;
    r.sumLogprob += logprobs[best];
    if (best === tk.eot) break;
    seq.push(best);
    if (repetitionLoop(seq)) {
      r.looped = true;
      break;
    }
    const next = await dec.step(best);
    cur = Float32Array.from(next.data);
  }
  dec.reset();
  return r;
}

// ---------------------------------------------------------------------------
// Long-form recognition
// ---------------------------------------------------------------------------

/**
 * Loaded Whisper model: sessions + tokenizer + generation config.
 * nMels from preprocessor_config.json (feature_size), 128 for large-v3 / turbo.
 */
export class WhisperModel {
  constructor(ort, encoder, decoder, tokenizer, genConfig, nMels) {
    this.ort = ort;
    this.encoder = encoder;
    this.decoder = decoder;
    this.tok = tokenizer;
    this.gen = genConfig;
    this.nMels = nMels;
    this.filters = melFilters(nMels);
  }

  languageToken(lang) {
    const id = this.gen.lang_to_id || {};
    return id[`<|${lang}|>`] ?? this.tok.special(`<|${lang}|>`) ?? id['<|zh|>'] ?? this.tok.special('<|zh|>');
  }

  /**
   * Recognises 16 kHz mono audio. language null: detected from the first
   * sung window, then promptByLanguage[detected code] is the style prompt.
   * Returns {segments: [{start, end, text, tokens}], windows, seconds, language}.
   */
  async recognize(audio, { language = 'zh', prompt = '', promptByLanguage = {}, condition = true, noSpeechThreshold = 0.6, logprobThreshold = -1.0, onProgress = () => {}, onWindow = null } = {}) {
    const t0 = Date.now();
    const tk = tokensFrom(this.gen);
    let langTok = language ? this.languageToken(language) : 0;
    let detected = language;
    const task = this.gen.task_to_id?.transcribe ?? this.tok.special('<|transcribe|>') ?? 50360;
    let stylePrompt = prompt ? this.tok.encode(prompt) : [];
    const total = Math.floor(audio.length / HOP);
    const voiced = voicedFrames(audio);
    const voicedAt = (f) => f >= 0 && f < voiced.length && voiced[f] === 1;
    let vFirst = -1;
    for (let f = 0; f < voiced.length && vFirst < 0; f++) if (voiced[f]) vFirst = f;
    const segments = [];
    let windows = 0;
    if (vFirst >= 0) {
      const dec = new Decoder(this.ort, this.decoder);
      let previous = [];
      let seek = Math.max(0, vFirst - 50);
      let heads = 0, headDim = 0;
      while (seek < total) {
        // Skip a window without singing straight to the next voiced frame.
        let probe = seek;
        while (probe < total && probe < seek + WINDOW_FRAMES && !voicedAt(probe)) probe++;
        if (probe >= seek + WINDOW_FRAMES || probe >= total) {
          let next = probe;
          while (next < total && !voicedAt(next)) next++;
          if (next >= total) break;
          seek = Math.max(seek, next - 50);
          continue;
        }
        await onProgress(seek / total);
        const segFrames = Math.min(WINDOW_FRAMES, total - seek);
        const from = seek * HOP;
        const n = Math.min(segFrames * HOP, audio.length - from);
        const mel = logMel(audio, from, n, this.filters, this.nMels);
        const encOut = await this.encoder.run({ input_features: new this.ort.Tensor('float32', mel, [1, this.nMels, WINDOW_FRAMES]) });
        const enc = encOut.last_hidden_state ?? Object.values(encOut)[0];
        if (!heads) {
          const d = enc.dims[2];
          // heads from the decoder's cache input metadata is not exposed in ort-web; Whisper uses 64-dim heads.
          headDim = 64;
          heads = d / headDim;
        }
        // Language: given, or detected once from the first sung window
        // (the most likely language token after <|startoftranscript|>).
        if (langTok <= 0) {
          const lg = (await dec.start(enc, [tk.sot], heads, headDim)).data;
          dec.reset();
          const ids = Object.entries(this.gen.lang_to_id || {});
          let best = -Infinity;
          langTok = 50260;
          for (const [name, id] of ids) {
            if (id < lg.length && lg[id] > best) {
              best = lg[id];
              langTok = id;
              detected = name.slice(2, -2);
            }
          }
          if (promptByLanguage[detected]) stylePrompt = this.tok.encode(promptByLanguage[detected]);
        }
        // Previous text: the style prompt, then what was recognised so far
        // with its timestamps, so the model keeps writing timestamps.
        const makePrefix = (withPrompt) => {
          let p = [];
          if (withPrompt) {
            p = [...stylePrompt];
            if (condition) p = p.concat(previous.slice(-Math.min(previous.length, 180)));
            if (p.length > 223) p = p.slice(p.length - 223);
          }
          const prefix = [];
          if (p.length) prefix.push(tk.sotPrev, ...p);
          const sotIndex = prefix.length;
          prefix.push(tk.sot, langTok, task);
          return [prefix, sotIndex];
        };
        let [prefix, sotIndex] = makePrefix(true);
        let wr = await decodeWindow(dec, tk, enc, prefix, sotIndex, 224, heads, headDim);
        if (echoes(wr.tokens, stylePrompt, tk.eot)) {
          // The model repeated the prompt instead of listening: once more without it.
          [prefix, sotIndex] = makePrefix(false);
          wr = await decodeWindow(dec, tk, enc, prefix, sotIndex, 224, heads, headDim);
        }
        windows++;
        const offset = seek / 100.0;
        const toks = wr.tokens;
        const avgLp = wr.sumLogprob / (toks.length + 1);
        onWindow?.({ seek, noSpeech: wr.noSpeech, avgLogprob: avgLp, looped: wr.looped, tokens: toks });
        if (wr.noSpeech > noSpeechThreshold && avgLp < logprobThreshold) {
          seek += segFrames; // silence or noise
          continue;
        }
        const isTs = (t) => t >= tk.tsBegin;
        const tsSec = (t) => (t - tk.tsBegin) * 0.02;
        const addSegment = (start, end, seg) => {
          const text = seg.filter((t) => t < tk.eot);
          if (text.length === 0 || end <= start) return;
          // Text over (mostly) no singing is made up: skip it.
          const f0 = Math.trunc((offset + start) * 100.0), f1 = Math.trunc((offset + end) * 100.0);
          let on = 0;
          for (let f = f0; f < f1; f++) on += voicedAt(f) ? 1 : 0;
          if (f1 > f0 && on / (f1 - f0) < 0.3) return;
          segments.push({ start: offset + start, end: offset + end, avgLogprob: avgLp, tokens: text, text: this.tok.decode(text).trim() });
        };
        const singleEnd = toks.length >= 2 && isTs(toks[toks.length - 1]) && !isTs(toks[toks.length - 2]);
        const cuts = [];
        for (let i = 1; i < toks.length; i++) if (isTs(toks[i]) && isTs(toks[i - 1])) cuts.push(i);
        let advance = segFrames;
        if (cuts.length && !wr.looped) {
          if (singleEnd) cuts.push(toks.length);
          let last = 0;
          for (const c of cuts) {
            if (c > last) {
              const seg = toks.slice(last, c);
              if (seg.length >= 2 && isTs(seg[0]) && isTs(seg[seg.length - 1])) addSegment(tsSec(seg[0]), tsSec(seg[seg.length - 1]), seg);
            }
            last = c;
          }
          if (!singleEnd) {
            const pos = Math.round(tsSec(toks[last - 1]) * 100.0);
            if (pos > 0) advance = Math.min(pos, segFrames);
          }
        } else {
          // One segment, from the first to the last timestamp.
          let start = 0, end = segFrames / 100.0;
          const stamps = toks.filter(isTs).map(tsSec);
          if (stamps.length) start = stamps[0];
          if (stamps.length >= 2 && stamps[stamps.length - 1] > start) end = stamps[stamps.length - 1];
          let text = [...toks];
          if (wr.looped) while (text.length > 8 && repetitionLoop(text)) text.pop(); // one copy of the looping tail
          addSegment(start, end, text);
        }
        if (!wr.looped) previous = previous.concat(toks);
        seek += Math.max(advance, 1);
      }
    }
    await onProgress(1);
    return { segments, windows, seconds: (Date.now() - t0) / 1000, language: detected };
  }
}
