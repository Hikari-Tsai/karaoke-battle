# Karaoke Battle

給直播主的卡拉 OK 評分系統。貼上 YouTube 連結或拖入影音檔，App 會在本機完成
人聲分離、旋律轉譜與參考音高抽取；演唱時以捲簾式鋼琴卷軸顯示參考旋律與即時
F0 曲線，結束後依音準、節奏、安定度、顫音、抑揚與長音給出量化分數。

* macOS（Universal, Apple Silicon + Intel）與 Windows x64，Flutter 桌面 App + C++ 原生引擎。
* 所有模型在首次執行時從 Hugging Face `aaatmy/*` 下載並以 SHA-256 驗證，安裝包不含模型。
* Windows 以 CUDA 為主要加速路徑（自動偵測、缺漏時提示安裝驅動並下載 CUDA 執行環境），
  備援為 DirectML 與 CPU；macOS 使用 CPU（部分模型嘗試 CoreML）。備援不影響評分準確度，只影響備歌速度。

## 架構

詳見 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)、[docs/BACKENDS.md](docs/BACKENDS.md)、[docs/BUILD.md](docs/BUILD.md)。

| 層 | 內容 |
| --- | --- |
| `app/` | Flutter UI：曲庫、備歌管線、演唱畫面（捲簾 MIDI + 即時 F0）、結果、設定；Dart 評分模組 |
| `engine/` | C++17 引擎（dart:ffi）：ONNX Runtime 動態載入、MDX-Net 分離、GAME 轉譜、SwiftF0 音高、miniaudio 即時音訊與播放時鐘、signalsmith-stretch 升降 key |
| `scripts/` | ORT、sidecar（yt-dlp / ffmpeg / deno）與 CUDA pack 的版本清單與下載腳本 |
| `.github/workflows/` | macOS universal 與 Windows 的 CI 打包 |

## 模型

| 模型 | 用途 | 授權 |
| --- | --- | --- |
| [aaatmy/uvr-mdx-net-onnx](https://huggingface.co/aaatmy/uvr-mdx-net-onnx) | 人聲 / 伴奏分離（Kim_Vocal_2、Inst_HQ_4） | MIT（依 UVR 聲明） |
| [aaatmy/game-large-onnx](https://huggingface.co/aaatmy/game-large-onnx) / [game-small-onnx](https://huggingface.co/aaatmy/game-small-onnx) | 人聲轉 MIDI（openvpi/GAME v1.0.3） | CC BY-NC-SA 4.0（非商業） |
| [aaatmy/swift-f0-onnx](https://huggingface.co/aaatmy/swift-f0-onnx) | 即時與離線 F0 | MIT |

GAME 權重為非商業授權，整個 App 的使用因此受該條款約束。

## 評分

演唱結束後把錄下的 F0 曲線與原唱（GAME 音符加 SwiftF0 參考曲線）對齊比較，給出六項子分數：
**音準**（Raw Chroma Accuracy）、**節奏**（onset / offset 命中率與時間誤差）、**安定度**、
**顫音**、**抑揚**（能量曲線相關性）、**長音**，加權成 0 到 100 的總分與 D 到 SSS 的等級。

兩個設計重點：**八度音視為同一個音**（唱高八度或低八度都算正確），以及**允許整體移調**
（全曲只用一個半音位移量，自動估計）。完整的對齊方法、指標定義、公式與校準結果見
[docs/SCORING.md](docs/SCORING.md)。

## 建置

```bash
# 引擎（macOS，universal）
scripts/fetch_ort.sh
cmake -S engine -B engine/build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build engine/build -j

# App
cd app && flutter pub get && flutter run -d macos
```

開發模式下 App 會自動在 `engine/build/` 找引擎與 `engine/third_party/onnxruntime/` 找 ORT。

## 法律聲明

本 App 內建呼叫 yt-dlp 下載影音僅供使用者在本機個人使用；下載 YouTube 內容可能違反
YouTube 服務條款，使用者須自行承擔。App 不會上傳或散布任何歌曲資料。

## 授權

程式碼採 MIT 授權，見 [LICENSE](LICENSE)。第三方元件見 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
