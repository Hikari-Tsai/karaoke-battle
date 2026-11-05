// Model files, pinned to a revision, and a downloader that keeps them in
// the browser's Cache Storage (so a model is downloaded once).

const HF = 'https://huggingface.co';

export const MDX = {
  id: 'kim-vocal-2',
  repo: 'aaatmy/uvr-mdx-net-onnx',
  rev: '1d1cf7c799e578a6ba1167c6ecbb010fe4c92649',
  files: ['Kim_Vocal_2.onnx'],
  mb: 67,
};

export const GAME = {
  large: { repo: 'aaatmy/game-large-onnx', rev: 'e586efdb3c20fc3dbb41c28ee9d0186116498334', mb: 394 },
  small: { repo: 'aaatmy/game-small-onnx', rev: 'da403f8b7740260d2833cad59a429439805fab53', mb: 51 },
};
export const GAME_FILES = ['config.json', 'encoder.onnx', 'segmenter.onnx', 'estimator.onnx', 'bd2dur.onnx'];

// int8 ("_quantized") encoder + KV-cache decoder of each size.
export const WHISPER = {
  base: { repo: 'onnx-community/whisper-base', rev: '27a07b4b52b3a4c5886134bb4320e93e1a4bbc7c', mb: 77, upstream: 'openai/whisper-base' },
  small: { repo: 'onnx-community/whisper-small', rev: '36050c46d777d46dc4b5f43f6d90574fc38f8732', mb: 249, upstream: 'openai/whisper-small' },
  medium: { repo: 'onnx-community/whisper-medium-ONNX', rev: 'd3978248a6b5de6df7ec29ddfbde3993845fa806', mb: 986, upstream: 'openai/whisper-medium' },
  'large-v3-turbo': { repo: 'onnx-community/whisper-large-v3-turbo', rev: '360ebcde2559d60bb474678be3c1de9ef347d01a', mb: 1085, upstream: 'openai/whisper-large-v3-turbo' },
  'large-v3': { repo: 'aaatmy/whisper-large-v3-onnx', rev: 'de039c89afa42612472ad99a16f9264c29ed82b2', mb: 1822, upstream: 'openai/whisper-large-v3' },
};
export const WHISPER_FILES = [
  'generation_config.json',
  'preprocessor_config.json',
  'vocab.json',
  'added_tokens.json',
  'merges.txt',
  'onnx/encoder_model_quantized.onnx',
  'onnx/decoder_model_merged_quantized.onnx',
];
export const WHISPER_DEFAULT = 'small';

const CACHE = 'lyrics-aligner-models-v1';

export function url(model, file) {
  return `${HF}/${model.repo}/resolve/${model.rev}/${file}`;
}

/**
 * Bytes of a model file, from the cache or downloaded (progress(doneBytes,
 * totalBytes) while downloading).
 */
export async function fetchFile(model, file, progress = () => {}) {
  const u = url(model, file);
  let cache = null;
  try {
    cache = await caches.open(CACHE);
    const hit = await cache.match(u);
    if (hit) return new Uint8Array(await hit.arrayBuffer());
  } catch {
    cache = null; // no Cache Storage (private window): download every time
  }
  const res = await fetch(u);
  if (!res.ok) throw new Error(`${file}: HTTP ${res.status}`);
  const total = +res.headers.get('content-length') || 0;
  const reader = res.body.getReader();
  const parts = [];
  let done = 0;
  for (;;) {
    const { done: end, value } = await reader.read();
    if (end) break;
    parts.push(value);
    done += value.length;
    progress(done, total);
  }
  const bytes = new Uint8Array(done);
  let o = 0;
  for (const p of parts) {
    bytes.set(p, o);
    o += p.length;
  }
  if (cache) {
    try {
      await cache.put(u, new Response(bytes, { headers: { 'content-type': 'application/octet-stream' } }));
    } catch {
      // quota: fine, just not cached
    }
  }
  return bytes;
}

export async function cachedFiles() {
  try {
    const cache = await caches.open(CACHE);
    return new Set((await cache.keys()).map((r) => r.url));
  } catch {
    return new Set();
  }
}

export async function clearCache() {
  try {
    await caches.delete(CACHE);
  } catch {
    // nothing to clear
  }
}
