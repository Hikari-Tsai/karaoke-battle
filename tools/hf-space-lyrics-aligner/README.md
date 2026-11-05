---
title: Lyrics Aligner
emoji: 🎤
colorFrom: yellow
colorTo: red
sdk: static
app_file: index.html
pinned: false
license: cc-by-nc-sa-4.0
short_description: Song + plain lyrics → timed SRT / LRC, in your browser
models:
  - aaatmy/uvr-mdx-net-onnx
  - aaatmy/game-large-onnx
  - aaatmy/game-small-onnx
  - aaatmy/whisper-large-v3-onnx
  - onnx-community/whisper-large-v3-turbo
  - onnx-community/whisper-medium-ONNX
  - onnx-community/whisper-small
  - onnx-community/whisper-base
custom_headers:
  cross-origin-embedder-policy: require-corp
  cross-origin-opener-policy: same-origin
  cross-origin-resource-policy: cross-origin
---

# Lyrics Aligner · 歌詞對時 · 歌詞タイミング

Upload a song, paste its lyrics as plain text (one line per row) and get
timed subtitles as **SRT** and **LRC**, with a preview that plays the song and
highlights the current line. Everything runs **in your browser** with
[ONNX Runtime Web](https://onnxruntime.ai/) (WebGPU when available, else
WASM); the song is never uploaded. The UI is in 繁體中文, English and 日本語.

上傳歌曲、貼上純文字歌詞（一行一句），產生 SRT／LRC 字幕並可邊聽邊預覽。全部在瀏覽器內執行，歌曲不會上傳。
曲をアップロードして歌詞を貼り付けると、SRT／LRC 字幕を作ります。処理はすべてブラウザ内で行われます。

## Method

The same method as the [Karaoke Battle](https://github.com/Hikari-Tsai/karaoke-battle) desktop app:

1. **Vocals**: UVR MDX-Net *Kim_Vocal_2* (n_fft 7680, hop 1024, dim_f 3072, dim_t 2⁸, overlap 0.25),
   a port of audio-separator's `MDXSeparator.demix()`.
2. **Notes**: openvpi **GAME** v1.0.3 (Large by default, Small as an option): silence slicer, encoder,
   D3PM segmenter (8 steps), bd2dur, estimator, as `inference/me_infer.py`.
3. **Alignment** (`lib/lyric_align.js`): a dynamic programme matches each lyric line to a contiguous run of
   notes by syllable count (one per CJK character / kana, vowel groups for Latin words), prefers line breaks
   at rests and may leave notes out (skip 0.2 per note, mismatch 2.0 per relative syllable difference,
   rest reward 0.5).
4. **AI listening (optional)**: Whisper transcribes the vocal stem (greedy decoding with the reference
   timestamp rules, a style prompt for Mandarin / Cantonese so the text is in Traditional characters,
   segments over unsung stretches and known hallucinations dropped). Its text is matched to the lyrics
   (longest common subsequence) only to pull each line towards the right phrase
   (0.1 per second away from Whisper's line start + 0.3 s, capped at 2 s); the exact times still come from the notes.
   With no lyrics pasted, the recognised text itself becomes the subtitles.

`lib/lyric_align.js` mirrors `app/lib/state/lyric_align.dart` of the app, which stays the source of truth;
`lib/whisper.js`, `lib/mdx.js`, `lib/game.js` and `lib/resample.js` mirror the app's C++ engine
(`engine/src/models/whisper.cpp`, `mdx.cpp`, `game.cpp`, `slicer.cpp`, `core/resample.cpp`). The source of
this Space lives in the app's repository under `tools/hf-space-lyrics-aligner/`, together with the evaluation scripts.

## Which Whisper?

Measured on two prepared test songs of the app (a Mandarin song, 254 s, 47 lines; a Japanese
cover, 158 s, 27 lines) against their published subtitles. Metric as in the app's evaluation: per line
|start − subtitle start|, share of lines within 0.5 s / 1 s. The notes are fixed to the app's GAME output,
so only Whisper changes. All sizes use the int8 ONNX exports and the same decoder (a port of the app's,
checked token for token against it). CER: character error rate of the recognised text against the
subtitle text. The Japanese test song's subtitles start about 5 s late on the first line. Time: native ONNX Runtime 1.23.2 on CPU (Apple M1 Pro, 4 threads), excluding loading.
The songs themselves are not part of this Space.

| Whisper | download | zh ≤0.5 s / ≤1 s | ja ≤0.5 s / ≤1 s | CER zh / ja | Whisper text only, zh · ja | CPU time zh / ja |
| --- | ---: | :---: | :---: | :---: | :---: | ---: |
| none (GAME only) | — | 85% / 96% | 59% / 74% | — | — | — |
| large-v3 (the app) | 1822 MB | 85% / 96% | 56% / 70% | 0.33 / 0.36 | 45/77% · 33/67% | 84 s / 39 s |
| large-v3-turbo | 1085 MB | 85% / 96% | 59% / 74% | 0.74 / 0.85 | 11/19% · 41/67% | 77 s / 32 s |
| medium | 986 MB | 85% / 96% | 59% / 78% | 0.45 / 0.28 | 30/53% · 74/93% | 31 s / 21 s |
| **small** (default) | 249 MB | 85% / 96% | 63% / 78% | 0.27 / 0.36 | 60/89% · 59/81% | 15 s / 9 s |
| base | 77 MB | 85% / 96% | 56% / 70% | 0.82 / 0.69 | 51/70% · 37/52% | 9 s / 4 s |

* For "GAME + Whisper" every size gives the same result as large-v3 (±1 line of 27 on the Japanese
  song): the notes set the times and Whisper only nudges lines, so its size barely matters.
* **small** is the smallest model that keeps that and also recognises well (lowest CER on the Mandarin
  song, as good as large-v3 on the Japanese one), at 1/7 of the download and ~5× the speed. It is the default;
  any size can be picked in the page.
* large-v3-turbo fell into repetition loops on both songs (high CER, 18 windows instead of 9); base
  misses too much text. large-v3 hallucinated credits over the Mandarin intro.
* **Language**: Whisper runs with language detection by default (as the app since v0.7.2: the most likely
  language token after `<|startoftranscript|>` on the first sung window; the Traditional-Chinese / Cantonese
  style prompt only for zh / yue, and a window that only echoes the prompt is decoded again without it).
  Every size, base included, detected the right language on both test songs (the Mandarin song → zh, the
  Japanese cover, sung in Japanese → ja) and on a 49 s Japanese clip whose metadata says zh. With detection
  the table above is unchanged. Forcing the wrong language breaks recognition: the Japanese song as zh gave
  CER 2.36 (small) / 1.14 (large-v3) and Whisper-only timing fell to 0% / 7% within 0.5 s; GAME + Whisper
  then falls back to the notes alone (59% / 74%). The page offers "Detect" as the default.
* "Whisper text only" times the lines from Whisper's text alone (snapped to note onsets); it is not
  what the page does, but shows how well each size finds the phrases.

In the browser (Chrome on the same M1 Pro, WebGPU for MDX-Net and GAME, 8 WASM threads for Whisper),
the whole 254 s Mandarin song took about 3 minutes: separation 67 s, GAME Large 53 s, Whisper small 49 s
(87% / 96% of lines within 0.5 s / 1 s). The first run also downloads the models (≈ 0.5 GB with small).

GAME itself samples (its D3PM segmenter draws random numbers), so notes differ slightly from run to run.
Over 5 runs, GAME Large gave 83–87% / 94–96% (zh) and 48–70% / 67–85% (ja); GAME Small 83–85% / 91–96%
(zh) but only 30–41% / 37–59% (ja), so Large stays the default.

## Evaluation scripts (repository only)

`eval/` (not uploaded to the Space) holds the scripts behind these numbers, run with Node and
`onnxruntime-node@1.23.2` on locally prepared songs: `eval_whisper.mjs` (Whisper sizes),
`eval_game.mjs` (GAME Large vs Small, several runs), `parity/check_parity.mjs` (checks that
`lib/lyric_align.js` gives exactly what `app/lib/state/lyric_align.dart` gives; needs `dart`) and
`serve.mjs` (local preview with the Space's cross-origin isolation headers).

## Licences and credits

**Non-commercial use only**, because the GAME weights are CC BY-NC-SA 4.0.

| Part | Licence | Credit |
| --- | --- | --- |
| GAME 1.0 Large / Small (`aaatmy/game-*-onnx`, unmodified official ONNX) | CC BY-NC-SA 4.0 | **Team OpenVPI** (openvpi/GAME; models published by yqzhishen; data labels by 挚彬Club, YQ之神, 小狼 and 幽寂), <https://github.com/openvpi/GAME/releases/tag/v1.0.3>. No endorsement implied. |
| Kim_Vocal_2 (`aaatmy/uvr-mdx-net-onnx`) | no licence file; the author's permission to use it freely, including commercially (KimberleyJensen/kmdx-net_music-source-separation issue #3) | trained by **KimberleyJensen**, distributed by **UVR** (Ultimate Vocal Remover); MDX-Net architecture by kuielab |
| Whisper large-v3, medium, small, base | Apache-2.0 | **OpenAI** Whisper; ONNX exports by onnx-community (large-v3 mirrored unchanged as `aaatmy/whisper-large-v3-onnx`) |
| Whisper large-v3-turbo | MIT | **OpenAI**; ONNX export by onnx-community |
| ONNX Runtime Web 1.23.2 (loaded from jsDelivr) | MIT | Microsoft |
| This page's code | MIT | Karaoke Battle, <https://github.com/Hikari-Tsai/karaoke-battle> |

Code ported from: openvpi/GAME `inference/` (MIT), python-audio-separator `mdx_separator.py` (MIT),
openai/whisper `decoding.py` / `transcribe.py` (MIT), transformers `WhisperFeatureExtractor` (Apache-2.0),
KISS FFT's mixed-radix butterflies (BSD-3-Clause).
