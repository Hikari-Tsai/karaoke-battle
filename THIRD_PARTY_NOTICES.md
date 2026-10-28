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
| GAME 1.0 Small / Large (openvpi) | CC BY-NC-SA 4.0 | model weights, non-commercial |
| UVR MDX-Net models (Kim_Vocal_2, Inst_HQ_4, Voc_FT) | MIT (per UVR README statement) | credit: UVR core developers Anjok07 & aufr33, KimberleyJensen, kuielab |
| SwiftF0 0.3.0 | MIT | Lars Nieradzik |

## Flutter packages

See `app/pubspec.yaml`; all are BSD-3/MIT licensed (media_kit is MIT and bundles libmpv, LGPL).
