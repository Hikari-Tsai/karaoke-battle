# Third-party notices

## Vendored in `engine/third_party/`

| Component | Version | License | Source |
| --- | --- | --- | --- |
| miniaudio | 0.11.22 | MIT-0 / public domain | https://github.com/mackron/miniaudio |
| dr_wav (dr_libs) | master | MIT-0 / public domain | https://github.com/mackron/dr_libs |
| pocketfft (C++ header) | cpp branch | BSD-3-Clause | https://github.com/mreineck/pocketfft |
| signalsmith-stretch | main | MIT | https://github.com/Signalsmith-Audio/signalsmith-stretch |
| signalsmith-linear | main | MIT | https://github.com/Signalsmith-Audio/linear |
| nlohmann/json | 3.12.0 | MIT | https://github.com/nlohmann/json |

## Fetched at build time (not committed)

| Component | Version | License |
| --- | --- | --- |
| ONNX Runtime (macOS universal2) | 1.23.2 | MIT |
| ONNX Runtime DirectML (Windows) | 1.24.4 | MIT (+ DirectML.dll, Microsoft proprietary redistributable) |

## Downloaded by the application at run time

| Component | License | Notes |
| --- | --- | --- |
| ONNX Runtime CUDA build 1.31.1 + NVIDIA CUDA 12 runtime / cuDNN 9 DLLs | MIT / NVIDIA EULA (redistributable runtime) | Windows CUDA pack, optional |
| yt-dlp | Unlicense | sidecar |
| FFmpeg (LGPL build) | LGPL 2.1+ | sidecar; the app runs it as a separate process |
| Deno | MIT | sidecar, JS runtime for yt-dlp |
| GAME 1.0 Small / Large | CC BY-NC-SA 4.0 | model weights, non-commercial; see attribution below |
| UVR-MDX-NET-Inst_HQ_4, UVR-MDX-NET-Voc_FT | MIT (per UVR README statement) | trained by the UVR core developers Anjok07 & aufr33; MDX-Net architecture by kuielab (Woosung Choi, Minseok Kim et al.) |
| Kim_Vocal_2 | no license file; author permission statement (GitHub issue #3 of KimberleyJensen/kmdx-net_music-source-separation, 2026-10-02: free to use "in any way you like, including for commercial use") | trained by KimberleyJensen with the kuielab mdx-net code; distributed by UVR |
| SwiftF0 0.3.0 | MIT | Lars Nieradzik; paper arXiv:2508.18440 |
| kuromoji.js 0.1.2 (+ async, lodash, doublearray, zlibjs) | Apache-2.0 (+ MIT) | Japanese readings for romaji; downloaded on first Japanese lyrics from `aaatmy/kuromoji-ipadic-pack`, run with Deno |
| mecab-ipadic 2.7.0-20070801 | NAIST / ICOT terms (redistribution permitted with notice) | dictionary bundled with kuromoji; Copyright 2000-2003 Nara Institute of Science and Technology, notice reproduced in the pack |

### GAME model attribution (CC BY-NC-SA 4.0)

"GAME 1.0 Small" and "GAME 1.0 Large" (singing-voice MIDI extraction models) by **Team OpenVPI**
(openvpi/GAME; models published by yqzhishen; data labels by 挚彬Club, YQ之神, 小狼 and 幽寂).
Source: <https://github.com/openvpi/GAME/releases/tag/v1.0.3>.
License: Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International
(<https://creativecommons.org/licenses/by-nc-sa/4.0/>). The official ONNX files are used
**without modification**; the Hugging Face mirrors `aaatmy/game-large-onnx` and
`aaatmy/game-small-onnx` add only a manifest and checksums and include the full license text.
No endorsement by the licensor is implied.

## Ported code

| Engine files | Origin | License |
| --- | --- | --- |
| `engine/src/models/game.*`, `slicer.*` | openvpi/GAME `inference/me_infer.py`, `data.py`, `slicer2.py` | MIT, Copyright (c) 2026 Team OpenVPI |
| `engine/src/models/mdx.*` | python-audio-separator `mdx_separator.py` (port of UVR `separate.py`) | MIT |
| `app/lib/scoring/` | metric definitions follow mir_eval (`melody`, `transcription`); re-implemented in Dart, no code copied | MIT (mir_eval) |

Citations for the papers behind the models and the scoring metrics are in `docs/CITATIONS.md`.

## Flutter packages

See `app/pubspec.yaml`; all are BSD-3/MIT licensed (media_kit is MIT and bundles libmpv, LGPL).
