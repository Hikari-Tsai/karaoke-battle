import { LANGS, STRINGS, pickLang } from './i18n.js';
import { GAME, MDX, WHISPER, WHISPER_DEFAULT, clearCache } from './models.js';
import { fmtTime, shifted, timeLyrics, toLrc, toSrt } from './lib/pipeline.js';
import { TimedText, splitLyricLines } from './lib/lyric_align.js';

const $ = (id) => document.getElementById(id);
let lang = pickLang();
let state = { lines: null, segments: null, offset: 0, fileName: 'lyrics' };
let lastProgress = null;
let study = null;

const t = (key, vars = {}) => (STRINGS[lang][key] ?? STRINGS.en[key] ?? key).replace(/\{(\w+)\}/g, (_, k) => vars[k] ?? '');

// ---------------------------------------------------------------------------
// Language
// ---------------------------------------------------------------------------

function applyLang() {
  document.documentElement.lang = lang;
  document.title = lang === 'en' ? 'Lyrics Aligner' : `${t('title')} · Lyrics Aligner`;
  for (const el of document.querySelectorAll('[data-i18n]')) el.textContent = t(el.dataset.i18n);
  for (const el of document.querySelectorAll('[data-i18n-html]')) el.innerHTML = t(el.dataset.i18nHtml);
  for (const el of document.querySelectorAll('[data-i18n-ph]')) el.placeholder = t(el.dataset.i18nPh);
  for (const b of $('langs').children) b.setAttribute('aria-pressed', String(b.dataset.lang === lang));
  fillWhisper();
  updateFirstRun();
  if (lastProgress) showProgress(lastProgress);
  if (state.lines) renderResult();
  renderStudy();
}

function buildLangButtons() {
  for (const [code, name] of Object.entries(LANGS)) {
    const b = document.createElement('button');
    b.type = 'button';
    b.textContent = name;
    b.dataset.lang = code;
    b.onclick = () => {
      lang = code;
      try {
        localStorage.setItem('ui-lang', code);
      } catch {
        // storage blocked
      }
      applyLang();
    };
    $('langs').appendChild(b);
  }
}

function fillWhisper() {
  const sel = $('whisper');
  const cur = sel.value || WHISPER_DEFAULT;
  sel.innerHTML = '';
  for (const [id, m] of Object.entries(WHISPER)) {
    const o = document.createElement('option');
    o.value = id;
    let label = `${id} · ${m.mb} MB`;
    if (id === WHISPER_DEFAULT) label += ` · ${t('rec')}`;
    if (m.mb > 1500) label += ` · ${t('heavy')}`;
    o.textContent = label;
    sel.appendChild(o);
  }
  sel.value = cur;
}

function method() {
  return document.querySelector('input[name="method"]:checked').value;
}

function updateFirstRun() {
  let mb = GAME[$('gameSize').value].mb + ($('skipSep').checked ? 0 : MDX.mb);
  if (method() === 'whisper') mb += WHISPER[$('whisper').value]?.mb ?? 0;
  $('firstRun').textContent = t('firstRun', { mb });
  $('whisperField').hidden = method() !== 'whisper';
  $('whisperLangField').hidden = method() !== 'whisper';
}

// ---------------------------------------------------------------------------
// Audio
// ---------------------------------------------------------------------------

async function decode(file) {
  const buf = await file.arrayBuffer();
  const ctx = new OfflineAudioContext(2, 44100, 44100);
  const audio = await ctx.decodeAudioData(buf);
  const planes = [];
  for (let c = 0; c < Math.min(2, audio.numberOfChannels); c++) planes.push(new Float32Array(audio.getChannelData(c)));
  if (planes.length === 1) planes.push(new Float32Array(planes[0]));
  return planes;
}

// ---------------------------------------------------------------------------
// Run
// ---------------------------------------------------------------------------

function showProgress(p) {
  lastProgress = p;
  $('progress').hidden = false;
  let text = t(`st_${p.stage}`);
  if (p.download && p.mb) text += ` (${Math.round(p.fraction * p.mb)} / ${p.mb} MB)`;
  else if (p.fraction != null) text += ` ${Math.round(p.fraction * 100)}%`;
  $('stage').textContent = text;
  $('bar').style.width = `${Math.round((p.fraction ?? 0) * 100)}%`;
}

function setBusy(busy) {
  $('run').disabled = busy;
  $('run').textContent = busy ? t('running') : t('run');
  $('cancel').hidden = !busy;
  if (!busy) {
    $('progress').hidden = true;
    lastProgress = null;
  }
}

function showError(msg) {
  $('error').hidden = !msg;
  $('error').textContent = msg ? t('error') + msg : '';
}

// Two workers: preparation (separation + notes, WebGPU when available) and
// Whisper (CPU-only ONNX Runtime build). Results of the last song are kept,
// so changing only the lyrics or the method does not redo them.
let busy = null; // the worker of the running step
let memo = { key: null };

function runWorker(script, msg, transfer) {
  return new Promise((resolve, reject) => {
    const w = new Worker(new URL(script, import.meta.url), { type: 'module' });
    busy = { w, reject };
    w.onmessage = (e) => {
      const m = e.data;
      if (m.type === 'progress') showProgress(m);
      else {
        w.terminate();
        busy = null;
        if (m.type === 'error') reject(new Error(m.message));
        else resolve(m);
      }
    };
    w.onerror = (e) => {
      w.terminate();
      busy = null;
      reject(new Error(e.message || 'worker failed'));
    };
    w.postMessage(msg, transfer);
  });
}

async function run() {
  showError('');
  const file = $('file').files[0];
  if (!file) return showError(t('noAudio'));
  const lyrics = $('lyrics').value;
  if (splitLyricLines(lyrics).length === 0 && method() !== 'whisper') return showError(t('noLyrics'));
  setBusy(true);
  state.fileName = file.name.replace(/\.[^.]+$/, '') || 'lyrics';
  const language = $('language').value;
  const key = `${file.name}|${file.size}|${file.lastModified}|${language}|${$('skipSep').checked}|${$('gameSize').value}`;
  const times = {};
  try {
    if (memo.key !== key) {
      memo = { key: null };
      showProgress({ stage: 'decode', fraction: 0 });
      const planes = await decode(file);
      const r = await runWorker(
        './worker.js',
        { type: 'prep', planes, language, gameSize: $('gameSize').value, ep: $('device').value, skipSeparation: $('skipSep').checked },
        planes.map((p) => p.buffer),
      );
      memo = { key, notes: r.notes, vocals16k: r.vocals16k, segments: {}, detected: {} };
      Object.assign(times, r.times);
    }
    let segments = null;
    let detected = null;
    if (method() === 'whisper') {
      const id = $('whisper').value;
      const wl = $('whisperLang').value;
      const sid = `${id}|${wl}`;
      if (!memo.segments[sid]) {
        // A copy: the stem is kept for other Whisper sizes.
        const v = memo.vocals16k.slice();
        const r = await runWorker('./whisper_worker.js', { type: 'whisper', vocals16k: v, language: wl === 'detect' ? null : wl, whisper: id }, [v.buffer]);
        memo.segments[sid] = r.segments;
        memo.detected[sid] = r.language;
        times.whisper = r.seconds;
        console.info('whisper', r.stats);
      }
      segments = memo.segments[sid].map((s) => new TimedText(s.start, s.end, s.text));
      detected = memo.detected[sid];
    }
    showProgress({ stage: 'align', fraction: 0.5 });
    await new Promise((r) => setTimeout(r, 0));
    const lines = timeLyrics(lyrics, memo.notes, segments);
    setBusy(false);
    if (lines.length === 0) return showError(t('nothingHeard'));
    state = { ...state, lines: lines.map((l) => ({ start: l.start, end: l.end, text: l.text })), segments, detected, notes: memo.notes.length, times, offset: 0 };
    $('offset').value = '0';
    renderResult();
    $('result').scrollIntoView({ behavior: 'smooth', block: 'start' });
  } catch (e) {
    setBusy(false);
    if (e.message !== 'cancelled') showError(String(e.message || e));
  }
}

function cancel() {
  if (busy) {
    busy.w.terminate();
    busy.reject(new Error('cancelled'));
    busy = null;
  }
  setBusy(false);
}

// ---------------------------------------------------------------------------
// Result
// ---------------------------------------------------------------------------

function current() {
  return shifted(state.lines, state.offset);
}

function renderResult() {
  if (!state.lines) return;
  $('result').hidden = false;
  const times = Object.entries(state.times || {})
    .filter(([, s]) => s != null)
    .map(([k, s]) => t(`t_${k}`, { s: s.toFixed(0) }))
    .join(t('sep'));
  $('summary').textContent =
    t('summary', { lines: state.lines.length, notes: state.notes }) +
    (state.detected ? ' ' + t('detected', { lang: state.detected }) : '') +
    (state.segments && state.segments.length === 0 ? ' ' + t('nothingHeard') : '') +
    (times ? ' ' + t('took', { t: times }) : '');
  const body = $('table').tBodies[0];
  body.innerHTML = '';
  current().forEach((l, i) => {
    const tr = document.createElement('tr');
    tr.dataset.i = i;
    for (const [v, cls] of [[fmtTime(l.start), 't'], [fmtTime(l.end), 't'], [l.text, '']]) {
      const td = document.createElement('td');
      td.textContent = v;
      if (cls) td.className = cls;
      tr.appendChild(td);
    }
    tr.onclick = () => {
      const p = $('player');
      if (!p.hidden) {
        p.currentTime = Math.max(0, l.start - 0.3);
        p.play();
      }
    };
    body.appendChild(tr);
  });
  const rec = $('recognized');
  rec.innerHTML = '';
  $('recWrap').hidden = !state.segments;
  for (const s of state.segments || []) {
    const li = document.createElement('li');
    li.textContent = `${fmtTime(s.start)}–${fmtTime(s.end)}  ${s.text}`;
    rec.appendChild(li);
  }
}

function tick() {
  if (state.lines && !$('player').hidden) {
    const now = $('player').currentTime;
    const lines = current();
    let on = -1;
    for (let i = 0; i < lines.length; i++) if (lines[i].start <= now && now < Math.max(lines[i].end, (lines[i + 1]?.start ?? lines[i].end) - 0.05)) on = i;
    const rows = $('table').tBodies[0].rows;
    for (let i = 0; i < rows.length; i++) rows[i].classList.toggle('on', i === on);
    $('now').textContent = on >= 0 ? lines[on].text : '';
  }
  // The browser may restore the form after this script ran.
window.addEventListener('pageshow', updateFirstRun);
window.addEventListener('load', updateFirstRun);
requestAnimationFrame(tick);
}

function download(name, text, type) {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([text], { type }));
  a.download = name;
  document.body.appendChild(a);
  a.click();
  setTimeout(() => {
    URL.revokeObjectURL(a.href);
    a.remove();
  }, 1000);
}

function setOffset(v) {
  state.offset = Math.round(v * 10) / 10;
  $('offset').value = String(state.offset);
  renderResult();
}

// ---------------------------------------------------------------------------
// Study table (numbers only, from study.json)
// ---------------------------------------------------------------------------

async function loadStudy() {
  try {
    study = await (await fetch('study.json')).json();
  } catch {
    study = null;
  }
  renderStudy();
}

function renderStudy() {
  const box = $('study');
  if (!study || !box) return;
  const L = study.labels[lang] ?? study.labels.en;
  let html = `<p class="hint">${L.note}</p><table class="study"><thead><tr>`;
  html += L.columns.map((c) => `<th>${c}</th>`).join('') + '</tr></thead><tbody>';
  for (const r of study.rows) html += '<tr>' + r.map((c) => `<td>${c}</td>`).join('') + '</tr>';
  html += '</tbody></table>';
  box.innerHTML = html;
}

// ---------------------------------------------------------------------------

buildLangButtons();
applyLang();
loadStudy();
for (const el of document.querySelectorAll('input[name="method"]')) el.onchange = updateFirstRun;
$('whisper').onchange = updateFirstRun;
$('gameSize').onchange = updateFirstRun;
$('skipSep').onchange = updateFirstRun;
$('run').onclick = run;
$('cancel').onclick = cancel;
$('earlier').onclick = () => setOffset(state.offset - 0.1);
$('later').onclick = () => setOffset(state.offset + 0.1);
$('offset').onchange = () => setOffset(parseFloat($('offset').value) || 0);
$('dlSrt').onclick = () => download(`${state.fileName}.srt`, toSrt(current()), 'application/x-subrip');
$('dlLrc').onclick = () => download(`${state.fileName}.lrc`, toLrc(current()), 'text/plain');
$('dlJson').onclick = () => download(`${state.fileName}.json`, JSON.stringify({ lines: current() }, null, 1), 'application/json');
$('clearCache').onclick = async () => {
  await clearCache();
  $('cacheMsg').textContent = t('cacheCleared');
};
$('file').onchange = () => {
  const f = $('file').files[0];
  const p = $('player');
  if (p.src) URL.revokeObjectURL(p.src);
  if (f) {
    p.src = URL.createObjectURL(f);
    p.hidden = false;
  } else p.hidden = true;
};
if (!self.crossOriginIsolated) {
  $('threadWarn').hidden = false;
  $('fullLink').href = location.href;
  if (window.top === window.self) $('fullLink').hidden = true;
}
// The browser may restore the form after this script ran.
window.addEventListener('pageshow', updateFirstRun);
window.addEventListener('load', updateFirstRun);
requestAnimationFrame(tick);
