# 技術特點

Karaoke Battle 的技術重點整理。細節見 [ARCHITECTURE.md](ARCHITECTURE.md)、[SCORING.md](SCORING.md)、[BACKENDS.md](BACKENDS.md)。

## 架構

* Flutter 桌面 UI，透過 dart:ffi 呼叫 C++17 原生引擎，**不需要 Python**。
* 引擎在執行時動態載入 ONNX Runtime（不連結），macOS 出 universal 版（Apple Silicon + Intel）。
* Windows 依序嘗試 CUDA → DirectML → CPU；CUDA 執行環境（約 1.9 GB）只在需要時下載。備援只影響備歌速度，不影響評分。
* 安裝包 55–65 MB。模型約 500 MB，首次執行時從 Hugging Face `aaatmy/*` 下載並以 SHA-256 驗證，每次啟動都會檢查完整性。

## 備歌流程（全部在本機）

* yt-dlp 下載 YouTube 影音，或直接拖入本機檔案。
* MDX-Net 人聲分離：人聲用 Kim_Vocal_2，伴奏用 UVR-MDX-NET-Inst_HQ_4。
* GAME 把人聲轉成音符：**不需要歌詞**，同音高的連續音節也能切開；音符可手動拖曳修正。
* SwiftF0 抽出原唱的參考音高曲線。
* Beat This 偵測節拍、重拍與 BPM（拍線與節拍器）。

## 即時演唱

* miniaudio 雙工裝置，播放時鐘就是引擎實際送出的 frame 數；回呼內不配置記憶體、不加鎖。
* 即時音高雙軌：MPM（延遲約 0.07 秒）驅動判定字卡，SwiftF0（延遲約 0.3 秒）畫曲線並用於最後評分。
* 捲動鋼琴卷軸，綠／黃／紅即時上色；音遊式 PERFECT／GREAT／GOOD／MISS 判定，標出 FAST／LATE 與 HIGH／LOW。
* signalsmith-stretch 升降 Key（伴奏與參考音符一起移調）。
* 人聲返送加 Cloud Seed Hall 殘響，回放時也會套用。
* 延遲校準：播放 click、錄回後互相關取中位數。

## 評分

* 時間對齊：先用有聲／無聲互相關抓整體延遲，再用 Sakoe-Chiba 帶狀 DTW 細對齊；節奏判定只補整體延遲，保留逐音快慢。
* **八度等價**（唱高或低八度都算對），整首只允許**一個**自動估計的移調量。
* **雙目標**：原唱曲線或 GAME 音符，唱中任一個就算對，同時容許原唱的滑音與轉譜誤差。
* 六項子分數：音準（Raw Chroma Accuracy）、節奏（判定時間窗依 BPM 縮放）、安定度、顫音、抑揚（能量曲線相關性）、長音。
* 總分以分段線性曲線換算成 0–100 分與 D–SSS 等級。
* **不辨識歌詞**，唱錯字或忘詞用哼的都不扣分。
* 評分規則改版時，舊紀錄用保存的音高自動重算，新舊分數可以直接比較。

## 歌詞

* 來源：YouTube 字幕，或匯入 SRT／VTT／LRC。
* 貼上整首歌詞時自動對時：預設依 GAME 音符（幾秒完成），或用 Whisper large-v3 先聽出唱的字再對時。
* 沒有歌詞時，用 Whisper large-v3 產生字幕（自動偵測語言；Mac 用 int8 版在 CPU 上執行）。
* 逐行編輯器：邊聽邊按 Enter 打點、整體位移、拆行合併，匯出 SRT 或 LRC。
* jf open 粉圓字型；日文歌詞顯示羅馬拼音。

## 其他

* 重播檔可匯出成 zip（評分資料加演唱錄音），對方匯入後即可觀看；一鍵產生分享圖卡。
* 熱門歌單：好樂迪、錢櫃、JOYSOUND、DAM 每週點歌排行與 KKBOX 單曲週榜。
* 介面：繁體中文、English、日本語。
* 不上傳任何資料，沒有使用統計。
* 授權：程式碼 MIT；GAME 權重為 CC BY-NC-SA 4.0，因此整個 App 實際上只能非商用。各模型的來源與授權見 [README](../README.md#模型) 與 [CITATIONS.md](CITATIONS.md)。
