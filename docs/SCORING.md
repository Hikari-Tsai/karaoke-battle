# 評分演算法

本文說明 Karaoke Battle 如何把一次演唱（take）與參考資料比對並給分。實作在
[`app/lib/scoring/`](../app/lib/scoring/)（純 Dart，無 Flutter 依賴），入口是
`Scorer.score(ScoringInput) -> ScoreResult`。所有數值常數都可由 `ScoringOptions` 與
`ScoringWeights` 覆寫，下文列的是預設值。

## 1. 輸入

| 資料 | 來源 | 內容 |
| --- | --- | --- |
| 參考音符 `notes.json` | GAME 轉譜分離後的人聲 | 每個音符的 onset、offset（秒）與 MIDI 音高（浮點，可含小數） |
| 參考 F0 曲線 `ref_f0.json` | SwiftF0 對分離後人聲 | 每 16 ms 一個 F0（Hz，0 = 無聲）與信心值 |
| 演唱 F0 曲線 `take_f0.json` | SwiftF0 對錄下的麥克風音訊 | 同上 |
| 能量曲線（選用） | take.wav 與 vocals.wav 的 RMS | 每 16 ms 一個 dB 值，用於抑揚 |

F0 先轉成半音（MIDI 浮點）：`midi = 69 + 12·log2(f0 / 440)`。信心值低於 0.4 的 frame 視為無聲。
兩條曲線都重取樣到同一個 16 ms 的格點上。有參考 F0 曲線時，逐 frame 的目標音高是
**原唱的曲線**（原唱的顫音、滑音都算在目標內），沒有時才用音符音高在格點上取樣。

## 2. 八度音視為同一個音，且允許整體移調

這是專案的設計決定：演唱者可以用自己舒服的調與八度唱。

* **chroma 距離**：兩個音高差 `d` 半音時，距離取 `min(|d| mod 12, 12 − |d| mod 12)`。
  因此唱高八度、低八度與原音完全相同，距離為 0。
* **全曲單一移調量 k**：在 `k = 0..11` 之中，挑讓 Raw Chroma Accuracy 最高的那一個，
  整首歌只用一個 k。不允許逐句變化，否則任何亂唱都能找到局部匹配。
* 另外計算一個「八度精確」的移調量（−24..24 半音）與對應的 Raw Pitch Accuracy，
  **只顯示不計分**，讓使用者知道自己是不是整首低八度在唱。
* 演唱畫面的即時上色與結束後的評分用同一套 chroma 規則（`LiveComparator`）。

## 3. 時間對齊

1. **粗對齊**：以有聲/無聲指標做互相關，找出整體延遲（±2 秒內）。
2. **DTW 細對齊**：Sakoe-Chiba 帶寬 ±1 秒，中心放在粗對齊的對角線上。
   局部成本：兩邊都無聲 0；一有聲一無聲 1；兩邊有聲時 `chroma距離 / 6`。
   非對角線的步伐額外加 0.5 的間隙罰分，避免亂唱的 take 靠扭曲時間「挑」到零星對上的 frame。
3. 對齊後重新估一次 k 當最終值。
4. 可切換成 `AlignmentMode.fixedOffset`（只用整體延遲、不 DTW），節奏分會比較嚴格。

## 4. 指標

### 4.1 Frame 層級（mir_eval `melody` 定義，容差 50 cents）

| 指標 | 定義 |
| --- | --- |
| Raw Pitch Accuracy (RPA) | 參考有聲 frame 中，演唱有聲且 `|take + shift − ref| ≤ 0.5` 半音的比例（僅顯示） |
| Raw Chroma Accuracy (RCA) | 同上但用 chroma 距離，**主要音準指標** |
| Voicing Recall | 參考有聲且演唱也有聲的比例 |
| Voicing False Alarm | 參考無聲而演唱有聲的比例 |
| Overall Accuracy | 兩邊同為無聲、或兩邊有聲且 chroma 正確的 frame 比例 |

### 4.2 音符層級（預設：參考音符引導）

GAME 會依音節切音符，連續音節常常是同一個音高，單靠 F0 分段會把它們合併，所以預設不從演唱 F0
切音符，而是**對每個參考音符在它自己的時間範圍內評估**：

* **符合 frame**：演唱有聲，且與目標（參考曲線有聲處用曲線，否則用音符音高）的 chroma 距離 ≤ 50 cents。
* **音高命中**：符合 frame 覆蓋音符範圍 ≥ 50%。
* **演唱的 onset / offset**：在 `[onset − 100 ms, offset + 100 ms]` 內找與音符重疊最多的符合區段
  （允許最多 3 個 frame 的中斷），區段邊界就是演唱的起訖；若相鄰音符音高在容差內
  （音高看不出轉換），搜尋窗在該邊界截斷。
* **預期的 onset / offset**：有參考曲線時用同樣方法在原唱曲線上量，所以原唱自己唱會得滿分。
* **onset 命中**：`|onset 誤差| ≤ 50 ms`；**offset 命中**：onset 與音高都命中且
  `|offset 誤差| ≤ max(50 ms, 20% × 音符長度)`。
* 參考曲線在該音符內完全無聲的音符標為不可評估並排除。
* Precision 的分母包含「唱錯或唱對的音符」加上「落在所有音符之外的演唱有聲區段」（誤報）。

輸出三組 precision / recall / F1：只看 onset、onset + 音高、onset + 音高 + offset，
以及每個音符的報告（命中與否、cents 偏差中位數、onset/offset 誤差、覆蓋率）。
`NoteSegmentation.fromTakeF0` 可切回從演唱 F0 切音符再做二分圖匹配的 mir_eval `transcription` 作法。

### 4.3 技巧指標

只在**長音**（參考音符 ≥ 400 ms）上分析，演唱側用未經時間扭曲的原始 frame。

* **顫音 (vibrato)**：對音高曲線去趨勢、加 Hann 窗，在 3 到 9 Hz 以 0.05 Hz 解析度做 DFT。
  一個約 0.5 秒的分析窗判定為有顫音的條件：速率 4 到 8 Hz、峰對峰幅度 30 到 150 cents、
  週期性（正弦能量 / 去趨勢變異）≥ 0.35。每個長音的「顫音量」= 通過的分析窗比例。
* **安定度 (stability)**：用一個顫音週期（偵測不到時以 6 Hz 計）的移動平均濾掉顫音後，
  音高相對中位數的標準差（cents）。原唱曲線也算同樣的值當基準。
* **長音 (long tone)**：長音範圍內演唱有聲且與目標在 50 cents 內的 frame 比例，
  只計參考有聲的 frame。
* **抑揚 (expression)**：演唱與參考能量曲線（dB）在參考有聲 frame 上、經對齊後的 Pearson 相關係數。

## 5. 子分數與總分

所有子分數在 `[0, 1]`，映射皆單調。`clamp` 表示夾到 `[0, 1]`。

| 子分數 | 公式 | 無法評估時 |
| --- | --- | --- |
| 音準 pitch | `clamp((RCA − 0.2) / 0.75)` | 永遠可評估 |
| 節奏 rhythm | `0.4·F1(onset) + 0.3·F1(onset+pitch+offset) + 0.3·timing`，`timing = 0.5·clamp(1 − max(0, medOn − 20) / 150) + 0.5·clamp(1 − max(0, medOff − 40) / 200)`，medOn / medOff 為 onset / offset 絕對誤差中位數（ms） | 沒有任何音符對上時 timing = 0 |
| 安定度 stability | `clamp(1 − max(0, std − refStd) / 50)`，std 為演唱長音的平均標準差，refStd 為原唱的同一值 | 參考無長音 → 排除；演唱無可分析長音 → 0 |
| 顫音 vibrato | `clamp(amount / target)`，amount 為演唱長音的平均顫音量，`target = min(原唱顫音量, 0.4)` | 參考無長音、或原唱幾乎不用顫音（量 < 0.25）→ 排除 |
| 抑揚 expression | `clamp(r / 0.8)` | 缺任一能量曲線 → 排除 |
| 長音 long tone | 長音的平均達成比例 | 參考無長音 → 排除 |

預設權重：音準 40、節奏 20、安定度 10、顫音 10、抑揚 10、長音 10。

```
total = 100 × Σ(wᵢ · sᵢ) / Σ(wᵢ)      只對「可評估」的子分數求和，權重自動重新正規化
```

| 總分 | 等級 |
| --- | --- |
| ≥ 97 | SSS |
| ≥ 92 | SS |
| ≥ 85 | S |
| ≥ 75 | A |
| ≥ 60 | B |
| ≥ 40 | C |
| 其他 | D |

## 6. 校準結果

用真實歌曲（30 秒 CC-BY 片段）經引擎產生的 notes.json 與 ref_f0.json 驗證，
固定樣本放在 [`app/test/scoring/fixtures/`](../app/test/scoring/fixtures/)：

| 演唱 | 總分 | 等級 |
| --- | --- | --- |
| 原唱自己的 F0 曲線 | 100.0 | SSS |
| 原唱降 9 個半音（等同升 3 度並低八度）且延遲 300 ms | 100.0 | SSS（k = 9） |
| 隨機音高 | 8.9 | D |

一首 5 分鐘的歌（約 19,000 frame、650 個音符）評分耗時約 150 ms。

## 7. 已知限制

* 沒有參考 F0 曲線時，預期 onset 來自 GAME 的音符邊界、目標是音符的固定音高，
  F0 追蹤的延遲與自然的音高起伏會稍微扣分。
* DTW 加間隙罰分會吸收 60 ms 以內的逐音符時間偏差，節奏分偏寬鬆；要嚴格評估節奏可用 `fixedOffset`。
* 顫音只在原唱本身大量使用顫音的歌曲才計分；其他歌曲靠另外五項。
* 歌詞不評分（中日文歌詞加伴奏串音的語音辨識誤差太大，給出的分數沒有意義）。

## 8. 參考文獻

指標定義依 mir_eval（Raffel et al., ISMIR 2014）的 `melody` 與 `transcription` 模組；
RPA / RCA 的 50 cent 容差與八度等價出自 Poliner et al. 2007 與 Salamon et al. 2014；
DTW 帶寬限制出自 Sakoe & Chiba 1978。完整引用與 BibTeX 見 [CITATIONS.md](CITATIONS.md)。

## 9. 開發工具

```bash
cd app
flutter test test/scoring                                     # 單元測試與真實資料固定樣本
dart run tool/score_files.dart notes.json take_f0.json ref_f0.json   # 對任意引擎輸出評分
```
