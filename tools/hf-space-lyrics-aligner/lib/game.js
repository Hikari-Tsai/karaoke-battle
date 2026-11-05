// GAME (openvpi, v1.0.3) singing transcription with the official ONNX
// export: port of the app's engine/src/models/game.cpp and slicer.cpp,
// which follow openvpi/GAME inference/me_infer.py, inference/slicer2.py and
// SaveCombinedFileCallback.
//
// mono 44.1 kHz -> silence slicer (slicer2) -> slices over 40 s split at
// their quietest frame -> per slice: encoder -> D3PM segmenter loop
// (nsteps 8) -> bd2dur -> estimator -> notes -> merged (monotonic).

export const GAME_DEFAULTS = {
  seg_threshold: 0.2,
  seg_radius_seconds: 0.02,
  t0: 0.0,
  nsteps: 8,
  est_threshold: 0.2,
  slicer: { threshold_db: -40, min_length_ms: 1000, min_interval_ms: 200, hop_ms: 20, max_sil_kept_ms: 100 },
  max_chunk_seconds: 40.0,
};

/** Python round(): half to even. */
function pyRound(x) {
  const r = Math.round(x);
  return Math.abs(x % 1) === 0.5 && r % 2 !== 0 ? r - 1 : r;
}

function slicerFrames(sr, p) {
  const minInterval = (sr * p.min_interval_ms) / 1000.0;
  const hop = Math.max(1, pyRound((sr * p.hop_ms) / 1000.0));
  return {
    threshold: Math.pow(10.0, p.threshold_db / 20.0),
    hop,
    win: Math.max(1, Math.min(pyRound(minInterval), 4 * hop)),
    minLength: pyRound((sr * p.min_length_ms) / 1000.0 / hop),
    minInterval: pyRound(minInterval / hop),
    maxSilKept: pyRound((sr * p.max_sil_kept_ms) / 1000.0 / hop),
  };
}

/** librosa-style RMS (centre padding with zeros). */
function getRms(y, frameLength, hop) {
  const L = y.length;
  const pad = Math.floor(frameLength / 2);
  const usable = L + 2 * pad - frameLength + 1;
  if (usable <= 0) return new Float32Array(0);
  const nFrames = Math.ceil(usable / hop);
  const out = new Float32Array(nFrames);
  for (let i = 0; i < nFrames; i++) {
    const start = i * hop - pad;
    const j0 = Math.max(0, start), j1 = Math.min(L, start + frameLength);
    let acc = 0;
    for (let j = j0; j < j1; j++) acc += y[j] * y[j];
    out[i] = Math.sqrt(acc / frameLength);
  }
  return out;
}

function argmin(rms, lo, hi) {
  lo = Math.max(0, lo);
  hi = Math.min(rms.length, hi);
  let best = lo;
  for (let i = lo + 1; i < hi; i++) if (rms[i] < rms[best]) best = i;
  return best;
}

/** Slicer.slice() of slicer2.py: [begin, end) sample ranges. */
export function sliceWaveform(mono, sr, p) {
  const L = mono.length;
  if (L === 0) return [];
  const f = slicerFrames(sr, p);
  const hop = f.hop;
  if (Math.ceil(L / hop) <= f.minLength) return [[0, L]];
  const rms = getRms(mono, f.win, hop);
  const totalFrames = rms.length;
  const tags = [];
  let silenceStart = -1;
  let clipStart = 0;
  for (let i = 0; i < totalFrames; i++) {
    if (rms[i] < f.threshold) {
      if (silenceStart < 0) silenceStart = i;
      continue;
    }
    if (silenceStart < 0) continue;
    const isLeading = silenceStart === 0 && i > f.maxSilKept;
    const needMiddle = i - silenceStart >= f.minInterval && i - clipStart >= f.minLength;
    if (!isLeading && !needMiddle) {
      silenceStart = -1;
      continue;
    }
    if (i - silenceStart <= f.maxSilKept) {
      const pos = argmin(rms, silenceStart, i + 1);
      tags.push(silenceStart === 0 ? [0, pos] : [pos, pos]);
      clipStart = pos;
    } else if (i - silenceStart <= 2 * f.maxSilKept) {
      const pos = argmin(rms, i - f.maxSilKept, silenceStart + f.maxSilKept + 1);
      const posL = argmin(rms, silenceStart, silenceStart + f.maxSilKept + 1);
      const posR = argmin(rms, i - f.maxSilKept, i + 1);
      if (silenceStart === 0) {
        tags.push([0, posR]);
        clipStart = posR;
      } else {
        tags.push([Math.min(posL, pos), Math.max(posR, pos)]);
        clipStart = Math.max(posR, pos);
      }
    } else {
      const posL = argmin(rms, silenceStart, silenceStart + f.maxSilKept + 1);
      const posR = argmin(rms, i - f.maxSilKept, i + 1);
      tags.push(silenceStart === 0 ? [0, posR] : [posL, posR]);
      clipStart = posR;
    }
    silenceStart = -1;
  }
  if (silenceStart >= 0 && totalFrames - silenceStart >= f.minInterval) {
    const silenceEnd = Math.min(totalFrames, silenceStart + f.maxSilKept);
    const pos = argmin(rms, silenceStart, silenceEnd + 1);
    tags.push([pos, totalFrames + 1]);
  }
  if (tags.length === 0) return [[0, L]];
  const out = [];
  const push = (b, e) => {
    const s = Math.max(0, b * hop);
    const t = Math.max(s, Math.min(L, e * hop));
    if (t > s) out.push([s, t]);
  };
  if (tags[0][0] > 0) push(0, tags[0][0]);
  for (let i = 0; i + 1 < tags.length; i++) push(tags[i][1], tags[i + 1][0]);
  if (tags[tags.length - 1][1] < totalFrames) push(tags[tags.length - 1][1], totalFrames);
  return out;
}

/** Splits slices longer than maxSamples at their quietest frame (central half). */
export function splitLongSlices(mono, slices, sr, p, maxSamples) {
  const f = slicerFrames(sr, p);
  const hop = f.hop;
  let rms = null;
  const out = [];
  for (const root of slices) {
    const stack = [root];
    while (stack.length) {
      const [b, e] = stack.pop();
      const len = e - b;
      if (len <= maxSamples) {
        if (len > 0) out.push([b, e]);
        continue;
      }
      if (!rms) rms = getRms(mono, f.win, hop);
      const lo = b + Math.floor(len / 4), hi = e - Math.floor(len / 4);
      const f0 = Math.ceil(lo / hop);
      const f1 = Math.min(Math.floor(hi / hop), rms.length - 1);
      let split = f1 >= f0 && f0 >= 0 ? argmin(rms, f0, f1 + 1) * hop : b + Math.floor(len / 2);
      if (split <= b || split >= e) split = b + Math.floor(len / 2);
      stack.push([split, e]);
      stack.push([b, split]);
    }
  }
  return out;
}

/** Holds the four sessions and config.json of a GAME model directory. */
export class GameModel {
  constructor(ort, sessions, config) {
    this.ort = ort;
    this.s = sessions; // {encoder, segmenter, estimator, bd2dur}
    this.samplerate = config.samplerate ?? 44100;
    this.timestep = config.timestep ?? 0.01;
    this.languages = config.languages ?? {};
    this.loop = config.loop ?? true;
  }

  languageId(name) {
    return (name && this.languages[name]) || 0;
  }

  async runChunk(wav, offsetSeconds, opt, languageId, notes) {
    const { ort, s } = this;
    const T = ort.Tensor;
    const length = Math.fround(wav.length / this.samplerate);
    const enc = await s.encoder.run({
      waveform: new T('float32', wav, [1, wav.length]),
      duration: new T('float32', new Float32Array([length]), [1]),
    });
    const xSeg = enc.x_seg, xEst = enc.x_est, maskT = enc.maskT;
    const nT = maskT.dims[1];
    const C = xSeg.dims[2];
    const maskTData = toBool(maskT.data);
    // A single known duration has no inner boundaries: all false (see game.cpp).
    const known = new Uint8Array(nT);
    let boundaries = new Uint8Array(nT);
    const radius = BigInt(pyRound(opt.seg_radius_seconds / this.timestep));
    const ts = [];
    if (this.loop) for (let i = 0; i < opt.nsteps; i++) ts.push(opt.t0 + (i * (1 - opt.t0)) / opt.nsteps);
    else ts.push(0);
    for (const t of ts) {
      const all = {
        x_seg: new T('float32', xSeg.data, [1, nT, C]),
        language: new T('int64', BigInt64Array.from([BigInt(languageId)]), [1]),
        known_boundaries: new T('bool', known, [1, nT]),
        prev_boundaries: new T('bool', boundaries, [1, nT]),
        t: new T('float32', new Float32Array([t]), [1]),
        maskT: new T('bool', maskTData, [1, nT]),
        threshold: new T('float32', new Float32Array([opt.seg_threshold]), []),
        radius: new T('int64', BigInt64Array.from([radius]), []),
      };
      const feeds = {};
      for (const name of s.segmenter.inputNames) feeds[name] = all[name];
      const r = await s.segmenter.run(feeds);
      boundaries = toBool(r.boundaries.data);
    }
    const bd = await s.bd2dur.run({
      boundaries: new T('bool', boundaries, [1, nT]),
      maskT: new T('bool', maskTData, [1, nT]),
    });
    const durations = bd.durations.data;
    const maskN = toBool(bd.maskN.data);
    const N = durations.length;
    const est = await s.estimator.run({
      x_est: new T('float32', xEst.data, [1, nT, C]),
      boundaries: new T('bool', boundaries, [1, nT]),
      maskT: new T('bool', maskTData, [1, nT]),
      maskN: new T('bool', maskN, [1, N]),
      threshold: new T('float32', new Float32Array([opt.est_threshold]), []),
    });
    const presence = toBool(est.presence.data);
    const scores = est.scores.data;
    // float32 arithmetic, as the reference (cumsum / clamp / add on float32 tensors).
    const off = Math.fround(offsetSeconds);
    let cum = 0;
    for (let k = 0; k < N; k++) {
      const onRaw = Math.min(cum, length);
      cum = Math.fround(cum + durations[k]);
      const offRaw = Math.min(cum, length);
      const onset = Math.fround(onRaw + off);
      const noteOff = Math.fround(offRaw + off);
      if (noteOff - onset <= 0) continue;
      if (!presence[k]) continue;
      notes.push({ onset, offset: noteOff, pitch: scores[k] });
    }
  }

  /** Notes of a mono waveform at the model rate. */
  async transcribe(mono, { language = '', options = {}, onProgress = () => {} } = {}) {
    const opt = { ...GAME_DEFAULTS, ...options, slicer: { ...GAME_DEFAULTS.slicer, ...(options.slicer || {}) } };
    let slices = sliceWaveform(mono, this.samplerate, opt.slicer);
    slices = splitLongSlices(mono, slices, this.samplerate, opt.slicer, Math.max(1, Math.round(opt.max_chunk_seconds * this.samplerate)));
    const lang = this.languageId(language);
    const notes = [];
    for (let i = 0; i < slices.length; i++) {
      const [b, e] = slices[i];
      await this.runChunk(mono.subarray(b, e), b / this.samplerate, opt, lang, notes);
      await onProgress((i + 1) / slices.length);
    }
    return mergeNotes(notes);
  }
}

function toBool(data) {
  return data instanceof Uint8Array ? data : Uint8Array.from(data, (x) => (x ? 1 : 0));
}

/** Sorted, monotonic, non-overlapping notes (SaveCombinedFileCallback.save_file). */
export function mergeNotes(notes) {
  notes.sort((a, b) => a.onset - b.onset || a.offset - b.offset || a.pitch - b.pitch);
  const kept = [];
  let last = 0;
  for (const n0 of notes) {
    const n = { ...n0 };
    n.onset = Math.max(n.onset, last);
    n.offset = Math.max(n.offset, n.onset);
    if (n.offset <= n.onset) continue;
    last = n.offset;
    kept.push(n);
  }
  return kept;
}
