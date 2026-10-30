# 安裝與使用說明

## 系統需求

| | macOS | Windows |
| --- | --- | --- |
| 版本 | macOS 12 以上，Apple Silicon 或 Intel（Universal） | Windows 10 64 位元以上 |
| 加速 | CPU（Apple Silicon 建議 M1 以上） | NVIDIA 顯示卡 + 驅動 527.41 以上可用 CUDA；其他顯示卡用 DirectML；沒有獨顯用 CPU |
| 磁碟 | 模型約 500 MB；每首歌約 100 到 300 MB（含影片）；Windows CUDA pack 另需約 2.6 GB | |
| 其他 | 麥克風、耳機（避免伴奏被麥克風收進去） | |

## 安裝

### macOS

1. 下載 [`KaraokeBattle-macos-universal.dmg`](https://github.com/Hikari-Tsai/karaoke-battle/releases/latest/download/KaraokeBattle-macos-universal.dmg)，打開後把 **Karaoke Battle** 拖到「應用程式」。
2. 目前的版本沒有 Apple 公證。第一次開啟時，請在應用程式上**按右鍵 → 打開**，再按一次「打開」；
   之後就能正常雙擊。若出現「已損毀，無法打開」，在終端機執行：
   ```bash
   xattr -dr com.apple.quarantine "/Applications/Karaoke Battle.app"
   ```
3. 第一次錄製時 macOS 會詢問麥克風權限，請允許。

### Windows

1. 下載 [`KaraokeBattle-windows-x64.zip`](https://github.com/Hikari-Tsai/karaoke-battle/releases/latest/download/KaraokeBattle-windows-x64.zip)，解壓縮到任意資料夾（例如 `C:\KaraokeBattle`）。
2. 執行 `karaoke_battle.exe`。SmartScreen 若出現「Windows 已保護您的電腦」，按「其他資訊 → 仍要執行」。
3. 若啟動時提示缺少 `VCRUNTIME140.dll`，安裝
   [Visual C++ 2015-2022 x64 可轉散發套件](https://aka.ms/vs/17/release/vc_redist.x64.exe)。

## 首次啟動

1. **選擇運算後端**（只有 Windows 會問）：
   * 有 NVIDIA 顯示卡且驅動夠新 → 建議下載 **CUDA 執行環境**（約 1.9 GB），備歌速度最快。
   * 驅動太舊 → 先到 [NVIDIA 驅動下載](https://www.nvidia.com/Download/index.aspx) 更新，期間可先用 DirectML。
   * AMD / Intel 顯示卡 → DirectML；沒有獨顯 → CPU。備援只影響備歌速度，不影響評分。
2. **下載模型**（約 500 MB，從 Hugging Face `aaatmy/*`，自動驗證 SHA-256）：按「全部下載」。
3. **外部工具**：App 會自動下載 yt-dlp 與 Deno；ffmpeg 若系統沒有也會自動下載。
   之後要更新 yt-dlp 可到「設定 → 外部工具」。

## 使用流程

### 1. 新增歌曲

曲庫右上角「新增歌曲」：

* **貼上 YouTube 連結**：App 用 yt-dlp 下載影片與音訊。
* **選擇檔案或直接拖入視窗**：支援 mp4、mkv、webm、mp3、m4a、flac、wav 等 ffmpeg 能讀的格式。
* 選擇歌詞語言（中文、日文、粵語、英文），轉譜模型會用到。

接著 App 會自動在背景完成：轉檔 → 人聲分離 → 伴奏分離 → 人聲轉 MIDI → 參考音高曲線。
一首四分鐘的歌，CUDA 約一分鐘，Apple Silicon CPU 約三到五分鐘，可以同時排多首。
中途關閉 App 下次會接著做。

### 2. 演唱

歌曲狀態變成「完成」後按「預覽」進入演唱頁。進入後還不會錄音，可以先播放原曲或伴奏、調整升降 Key 熟悉旋律，按「開始錄製」才開始計分：

* 上方是影片（有的話），中間是**捲簾式鋼琴卷軸**：藍色長條是原唱的音符，播放時從右往左捲動，
  白色直線是現在的時間點。
* 戴上耳機，按「開始錄製」後開始播放，你唱的音高會即時畫成曲線：
  **綠色** = 與原唱在 50 cents 內、**黃色** = 100 cents 內、**紅色** = 更遠。
* **原曲 / 伴奏**：切換播放原曲或去掉人聲的伴奏，位置不會跳。
* **升降 Key**：±6 個半音，伴奏與參考音符一起移。
* **八度對齊顯示**：你唱高八度或低八度時曲線會畫到原唱附近，方便看；評分本來就不分八度。
* 按「停止」後 App 會分析錄音並評分，進入結果頁。

### 3. 結果

總分（0 到 100）、等級（D 到 SSS）與六個子分數：音準、節奏、安定度、顫音、抑揚、長音，
加上每個音符的命中與偏差，以及整首歌的音高曲線對照。每次演唱都會存在歌曲的「演唱紀錄」裡。
評分方式詳見 [SCORING.md](SCORING.md)。

### 4. 給直播用

* **人聲返送**：演唱頁右上的麥克風按鈕可開啟人聲返送與 Hall 殘響，耳機裡同時聽到自己和音樂；
  OBS 擷取 App 音訊時直播也會有人聲。用喇叭外放會產生回授，請戴耳機。
* **延遲校正**：設定 → 音訊 → 「校正延遲」，播放幾聲 click 量測麥克風回路延遲，讓曲線與伴奏對齊。
  需要麥克風能收到喇叭的聲音；用耳機時可略過，預設補償值通常夠用。

## 資料位置

| 平台 | 路徑 |
| --- | --- |
| macOS | `~/Library/Application Support/KaraokeBattle/` |
| Windows | `%APPDATA%\com.karaokebattle\karaoke_battle\KaraokeBattle\` |

底下有 `models/`（模型）、`sidecars/`（yt-dlp、ffmpeg、deno）、`songs/<id>/`（每首歌的所有檔案與演唱紀錄）、
`cuda_pack/`（Windows）。刪掉整個資料夾就是完全重置。

## 常見問題

* **曲線一直是紅色或沒有曲線**：確認設定裡選對了麥克風、輸入電平表有在動；戴耳機避免伴奏串音。
* **YouTube 下載失敗**：到「設定 → 外部工具」更新 yt-dlp；YouTube 更改頻繁，yt-dlp 需要常更新。
* **CUDA 自我測試失敗**：App 會自動退回 DirectML；可在設定重新下載 CUDA 執行環境，或更新顯示卡驅動。
* **備歌很慢**：Windows 請確認後端是 CUDA 而不是 CPU；macOS 可在設定把轉譜模型改成 GAME Small。

## 授權注意事項

* 轉譜模型 GAME 1.0（作者 Team OpenVPI）採 **CC BY-NC-SA 4.0（非商業）**，使用本 App 受此條款約束；完整引用見 [CITATIONS.md](CITATIONS.md)。
* 用 yt-dlp 下載 YouTube 內容可能違反 YouTube 服務條款，僅供個人在本機使用，風險自負。
