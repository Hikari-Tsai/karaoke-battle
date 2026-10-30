<p align="center">
  <img src="docs/icon.png" width="160" alt="Karaoke Battle">
</p>

<h1 align="center">Karaoke Battle</h1>

<p align="center">
  <a href="#下載"><img src="https://img.shields.io/badge/%E4%B8%8B%E8%BC%89-macOS%20%7C%20Windows-2EA44F?style=for-the-badge" height="36" alt="下載"></a>
  <br>
  <a href="https://github.com/Hikari-Tsai/karaoke-battle/releases/latest"><img src="https://img.shields.io/github/v/release/Hikari-Tsai/karaoke-battle?label=latest%20release" alt="最新版本"></a>
  <a href="https://github.com/Hikari-Tsai/karaoke-battle/actions/workflows/build.yml"><img src="https://github.com/Hikari-Tsai/karaoke-battle/actions/workflows/build.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License"></a>
</p>

<p align="center"><b>中文</b> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a></p>

給直播主的卡拉 OK 評分系統。貼上 YouTube 連結或拖入影音檔，App 會在本機完成
人聲分離、旋律轉譜與參考音高抽取；演唱時以捲簾式鋼琴卷軸顯示參考旋律與即時
F0 曲線，結束後依音準、節奏、安定度、顫音、抑揚與長音給出量化分數。

* macOS（Universal, Apple Silicon + Intel）與 Windows x64，Flutter 桌面 App + C++ 原生引擎。
* 所有模型在首次執行時從 Hugging Face `aaatmy/*` 下載並以 SHA-256 驗證，安裝包不含模型。
* Windows 以 CUDA 為主要加速路徑（自動偵測、缺漏時提示安裝驅動並下載 CUDA 執行環境），
  備援為 DirectML 與 CPU；macOS 使用 CPU（部分模型嘗試 CoreML）。備援不影響評分準確度，只影響備歌速度。

## 下載

<p align="center">
  <a href="https://github.com/Hikari-Tsai/karaoke-battle/releases/latest/download/KaraokeBattle-macos-universal.dmg"><picture><source media="(prefers-color-scheme: dark)" srcset="https://img.shields.io/badge/macOS-Apple%20Silicon%20%2B%20Intel-F2F2F2?style=for-the-badge&logo=apple&logoColor=black&labelColor=D9D9D9"><img src="https://img.shields.io/badge/macOS-Apple%20Silicon%20%2B%20Intel-000000?style=for-the-badge&logo=apple&logoColor=white&labelColor=1F1F1F" height="44" alt="下載 macOS 版（Apple Silicon + Intel）"></picture></a>
  &nbsp;
  <a href="https://github.com/Hikari-Tsai/karaoke-battle/releases/latest/download/KaraokeBattle-windows-x64.zip"><img src="https://img.shields.io/badge/Windows-10%20%2F%2011%20x64-0078D4?style=for-the-badge&labelColor=005A9E&logo=data:image/svg%2bxml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0id2hpdGUiPjxwYXRoIGQ9Ik0wIDBoMTEuMnYxMS4ySDB6TTEyLjggMEgyNHYxMS4ySDEyLjh6TTAgMTIuOGgxMS4yVjI0SDB6TTEyLjggMTIuOEgyNFYyNEgxMi44eiIvPjwvc3ZnPg==" height="44" alt="下載 Windows 版（10／11 x64）"></a>
</p>

<p align="center">免費、開源（MIT）· <a href="docs/INSTALL.md">安裝說明</a> · <a href="https://github.com/Hikari-Tsai/karaoke-battle/releases">所有版本與更新紀錄</a></p>

<p align="center"><sub>macOS：打開 DMG 拖到「應用程式」，第一次請在 App 上按右鍵 →「打開」。<br>Windows：解壓縮後執行 <code>karaoke_battle.exe</code>。首次啟動會自動下載模型（約 500 MB）。</sub></p>

## 給直播主的功能

以下畫面都是實際操作 App 錄下來的（示範歌曲為 Josh Woodward 的〈Swansong〉，CC BY 授權）。GIF 沒有聲音。

### 任何歌都能變成卡拉 OK

貼上 YouTube 連結或拖入影音檔，App 在背景自動分離人聲、做出伴奏、轉出旋律音符與參考音高，好了就能唱；可以一次排好幾首。

<p align="center"><img src="docs/media/add-song.gif" width="720" alt="貼上 YouTube 連結後在背景備歌"></p>

### 即時看到自己哪裡走音

鋼琴卷軸捲動顯示原唱的每個音符，你唱的音高即時畫成曲線：綠色是準、黃色差一點、紅色偏掉了，觀眾一看就懂。

<p align="center"><img src="docs/media/sing.gif" width="720" alt="演唱畫面：捲動的鋼琴卷軸與即時音高曲線"></p>

### 升降 Key 與人聲返送

升降 Key 讓伴奏與參考音符一起移調；右上角的人聲返送把你的聲音和音樂一起送到耳機，OBS 擷取 App 音訊時直播也會有人聲，還能加上 Hall 殘響。

<p align="center"><img src="docs/media/key-voice.gif" width="720" alt="升降 Key 與人聲返送、Hall 殘響設定"></p>

### 分數與分享圖卡

唱完立刻給出和 DAM 精密採点相近的 0 到 100 分、D 到 SSS 等級與六項子分數，一鍵做成分享圖卡（可貼到 X、Instagram、Threads）。每次演唱都留在曲庫，最高分一目了然。

<p align="center"><img src="docs/media/results.gif" width="720" alt="結果頁：總分、等級、子分數與分享圖卡"></p>

### 音遊風格的回放判定

回放時像音遊一樣在播放線上跳出 PERFECT／GREAT／GOOD／MISS 判定，同時看時間和音準，並標出 FAST／LATE 與 HIGH／LOW，一眼看出是快慢還是高低出了問題。重播檔可以匯出成 zip（評分資料加上演唱錄音）傳給朋友，對方匯入後就能看你的演唱。

<p align="center"><img src="docs/media/replay.gif" width="720" alt="回放時在播放線上跳出 PERFECT、GREAT、GOOD、MISS 判定"></p>

### 手動修正音符

按「編輯音符」，把音符上下拖曳就能修正，拖曳時會播放正弦波讓你試聽音高（GIF 沒有聲音）；改錯了隨時可以還原成自動轉譜的結果。

<p align="center"><img src="docs/media/edit-notes.gif" width="720" alt="拖曳音符修正音高"></p>

## 架構

詳見 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)、[docs/BACKENDS.md](docs/BACKENDS.md)、[docs/BUILD.md](docs/BUILD.md)。

| 層 | 內容 |
| --- | --- |
| `app/` | Flutter UI：曲庫、備歌管線、演唱畫面（捲簾 MIDI + 即時 F0）、結果、設定；Dart 評分模組 |
| `engine/` | C++17 引擎（dart:ffi）：ONNX Runtime 動態載入、MDX-Net 分離、GAME 轉譜、SwiftF0 音高、miniaudio 即時音訊與播放時鐘、signalsmith-stretch 升降 key |
| `scripts/` | ORT、sidecar（yt-dlp / ffmpeg / deno）與 CUDA pack 的版本清單與下載腳本 |
| `.github/workflows/` | macOS universal 與 Windows 的 CI 打包 |

## 模型

| 模型 | 用途 | 作者 | 授權 |
| --- | --- | --- | --- |
| [aaatmy/game-large-onnx](https://huggingface.co/aaatmy/game-large-onnx) / [game-small-onnx](https://huggingface.co/aaatmy/game-small-onnx) | 人聲轉 MIDI（GAME 1.0 Large / Small） | Team OpenVPI | 權重 CC BY-NC-SA 4.0（非商業），程式碼 MIT |
| [aaatmy/uvr-mdx-net-onnx](https://huggingface.co/aaatmy/uvr-mdx-net-onnx) | 人聲分離 Kim_Vocal_2 | KimberleyJensen（經 UVR 散布） | 無授權檔；作者公開許可聲明 |
| 同上 | 伴奏分離 UVR-MDX-NET-Inst_HQ_4 | UVR 核心開發者 Anjok07、aufr33 | MIT（依 UVR 聲明） |
| [aaatmy/swift-f0-onnx](https://huggingface.co/aaatmy/swift-f0-onnx) | 即時與離線 F0 | Lars Nieradzik | MIT |
| [aaatmy/beat-this-onnx](https://huggingface.co/aaatmy/beat-this-onnx) | 節拍、重拍與 BPM（拍線、節拍器） | CPJKU（Foscarin、Schlüter、Widmer） | MIT |
| [aaatmy/kuromoji-ipadic-pack](https://huggingface.co/aaatmy/kuromoji-ipadic-pack) | 日文歌詞的羅馬拼音（遇到日文歌詞才下載） | kuromoji.js（Takuya Asano）、mecab-ipadic（NAIST） | Apache-2.0、IPADIC 條款 |

三個鏡像都是上游官方檔案的原樣複製（未重新訓練、量化或匯出），只加上 manifest 與 SHA-256。
GAME 權重為非商業授權，整個 App 的使用因此受該條款約束。

## 評分

演唱結束後把錄下的 F0 曲線與原唱（GAME 音符加 SwiftF0 參考曲線）對齊比較，給出六項子分數：
**音準**（Raw Chroma Accuracy）、**節奏**（像音遊一樣逐音判定 PERFECT／GREAT／GOOD／MISS，時間窗依 BPM 縮放）、**安定度**、
**顫音**、**抑揚**（能量曲線相關性）、**長音**，加權後換算成和 DAM 精密採点相近的 0 到 100 分（80 分左右是一般水準、90 分以上算唱得好），並給出 D 到 SSS 的等級。

三個設計重點：**八度音視為同一個音**（唱高八度或低八度都算正確）、**允許整體移調**
（全曲只用一個半音位移量，自動估計），以及**容許原唱的滑音與 GAME 的轉譜誤差**：每個 frame
的目標同時有原唱的 F0 曲線與 GAME 音符音高，演唱符合任一個就算對，跟著原唱滑或把音唱直都可以。
完整的對齊方法、指標定義、公式與校準結果見 [docs/SCORING.md](docs/SCORING.md)
（[English](docs/SCORING.en.md)、[日本語](docs/SCORING.ja.md)）。

## 安裝與使用

從上方「[下載](#下載)」區下載 DMG 或 zip 安裝。macOS 第一次請在 App 上按右鍵「打開」（未公證）；Windows 在 SmartScreen 選「仍要執行」。
首次啟動會下載模型（約 500 MB）與外部工具，Windows 另可選擇下載 CUDA 執行環境。
新增歌曲（YouTube 連結或拖入檔案）後等待備歌完成，按「預覽」進入演唱頁，可先聽原曲或伴奏並看鋼琴卷軸，戴上耳機按「開始錄製」才開始評分。演唱頁右上角的麥克風按鈕可開啟人聲返送（Vocal Return），把自己的聲音和音樂一起送到輸出，同一個面板也能開關 Hall 殘響並調整混合比例，回放時也會套用。錄音、計分與匯出的重播檔一律使用乾聲。
完整步驟、資料位置與常見問題見 [docs/INSTALL.md](docs/INSTALL.md)。

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

## 致謝

完整的引用格式（含 BibTeX）與各上游的要求見 [docs/CITATIONS.md](docs/CITATIONS.md)。

* **GAME 1.0 Small / Large**（旋律轉譜模型）by **Team OpenVPI**，
  來源 [openvpi/GAME v1.0.3](https://github.com/openvpi/GAME/releases/tag/v1.0.3)，
  授權 [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/)。
  模型由 yqzhishen 發布，資料標註由 挚彬Club、YQ之神、小狼、幽寂 提供。本 App 使用官方 ONNX 檔案，未做修改；不為 openvpi 所背書。
* **Kim_Vocal_2**（人聲分離）by **KimberleyJensen**，獨立訓練、經 UVR 散布；上游無授權檔，依作者
  [公開許可聲明](https://github.com/KimberleyJensen/kmdx-net_music-source-separation/issues/3)（2026-10-02）使用。
* **UVR-MDX-NET-Inst_HQ_4**（伴奏分離）by **Ultimate Vocal Remover** 核心開發者 **Anjok07 與 aufr33**（MIT，依 UVR 的署名要求）。
* MDX-Net 架構與訓練程式來自 **kuielab**（Choi et al., *TFC-TDF-U-Net*, ISMIR 2020；Kim et al., *KUIELab-MDX-Net*, MDX Workshop @ ISMIR 2021）。
  引擎的分離程式移植自 [python-audio-separator](https://github.com/nomadkaraoke/python-audio-separator)（MIT）。
* **SwiftF0** by Lars Nieradzik（*SwiftF0: Fast and Accurate Monophonic Pitch Detection*, arXiv:2508.18440, 2025）。
* 評分指標的定義取自 **mir_eval**（Raffel et al., ISMIR 2014）與旋律抽取評估文獻（Poliner et al. 2007；Salamon et al. 2014）；
  即時音高追蹤用 **MPM**（McLeod & Wyvill, ICMC 2005）；對齊用 Sakoe-Chiba 帶狀 DTW（1978）。
* 升降 key 使用 [Signalsmith Stretch](https://github.com/Signalsmith-Audio/signalsmith-stretch)，音訊 I/O 使用 miniaudio，推論使用 ONNX Runtime。
* 人聲殘響使用 Ghost Note Audio 的 [Cloud Seed](https://github.com/GhostNoteAudio/CloudSeedCore) 演算法（MIT）。本專案與 Ghost Note Audio 無關。

## 法律聲明

本 App 內建呼叫 yt-dlp 下載影音僅供使用者在本機個人使用；下載 YouTube 內容可能違反
YouTube 服務條款，使用者須自行承擔。App 不會上傳或散布任何歌曲資料。

## 授權

程式碼採 MIT 授權，見 [LICENSE](LICENSE)。第三方元件見 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
