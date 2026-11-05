// Loads a Whisper ONNX model directory for onnxruntime-node.
import fs from 'node:fs';
import path from 'node:path';
import ort from 'onnxruntime-node';
import { WhisperModel, WhisperTokenizer } from '../lib/whisper.js';

export async function loadWhisper(dir, opts) {
  const j = (f) => JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'));
  const has = (f) => fs.existsSync(path.join(dir, f));
  const merges = has('merges.txt') ? WhisperTokenizer.parseMerges(fs.readFileSync(path.join(dir, 'merges.txt'), 'utf8')) : WhisperTokenizer.parseMerges(j('tokenizer.json'));
  const tok = new WhisperTokenizer(j('vocab.json'), j('added_tokens.json'), merges);
  const nMels = has('preprocessor_config.json') ? j('preprocessor_config.json').feature_size : 128;
  const pick = (base) => (has(`onnx/${base}_quantized.onnx`) ? `onnx/${base}_quantized.onnx` : `onnx/${base}.onnx`);
  const enc = await ort.InferenceSession.create(path.join(dir, pick('encoder_model')), opts);
  const dec = await ort.InferenceSession.create(path.join(dir, pick('decoder_model_merged')), opts);
  return new WhisperModel(ort, enc, dec, tok, j('generation_config.json'), nMels);
}

