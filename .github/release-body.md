## 下載

| 平台 | 檔案 |
| --- | --- |
| macOS（Apple Silicon + Intel，Universal） | [KaraokeBattle-macos-universal.dmg](https://github.com/Hikari-Tsai/karaoke-battle/releases/download/{{TAG}}/KaraokeBattle-macos-universal.dmg) |
| Windows 10/11 x64 | [KaraokeBattle-windows-x64.zip](https://github.com/Hikari-Tsai/karaoke-battle/releases/download/{{TAG}}/KaraokeBattle-windows-x64.zip) |

[SHA256SUMS.txt](https://github.com/Hikari-Tsai/karaoke-battle/releases/download/{{TAG}}/SHA256SUMS.txt) 可用來核對下載的檔案。

## 安裝

完整步驟見 [安裝與使用說明](https://github.com/Hikari-Tsai/karaoke-battle/blob/{{TAG}}/docs/INSTALL.md)。

**[macOS](https://github.com/Hikari-Tsai/karaoke-battle/blob/{{TAG}}/docs/INSTALL.md#macos)**：打開 DMG，把 Karaoke Battle 拖到「應用程式」。此版本未經 Apple 公證，第一次請在 App 上**按右鍵 → 打開**。
若出現「已損毀」提示，執行 `xattr -dr com.apple.quarantine "/Applications/Karaoke Battle.app"`。

**[Windows](https://github.com/Hikari-Tsai/karaoke-battle/blob/{{TAG}}/docs/INSTALL.md#windows)**：解壓縮到任意資料夾，執行 `karaoke_battle.exe`。SmartScreen 出現時按「其他資訊 → 仍要執行」。
缺少 `VCRUNTIME140.dll` 時請安裝 [Visual C++ 2015-2022 x64 可轉散發套件](https://aka.ms/vs/17/release/vc_redist.x64.exe)。

## [首次啟動](https://github.com/Hikari-Tsai/karaoke-battle/blob/{{TAG}}/docs/INSTALL.md#首次啟動)

1. Windows 會先偵測顯示卡：NVIDIA 且驅動 ≥ 527.41 建議下載 CUDA 執行環境（約 1.9 GB）；其他顯示卡用 DirectML；沒有獨顯用 CPU。備援只影響備歌速度，不影響評分。
2. 下載模型（約 500 MB，來自 Hugging Face `aaatmy/*`，自動驗證 SHA-256）。
3. yt-dlp、Deno、ffmpeg 由 App 自動下載。

## [使用](https://github.com/Hikari-Tsai/karaoke-battle/blob/{{TAG}}/docs/INSTALL.md#使用流程)

1. **曲庫 → 新增歌曲**：貼 YouTube 連結，或拖入影音檔，選歌詞語言。App 在背景完成轉檔、人聲分離、轉 MIDI 與參考音高。
2. **預覽與演唱**：按「預覽」進入演唱頁，可先播放熟悉旋律；要計分時戴上耳機，按「開始錄製」再播放。捲簾鋼琴卷軸上藍色是原唱音符，你的音高曲線綠色 = 準、黃色 = 接近、紅色 = 偏離。可切原曲 / 伴奏、升降 Key（±6 半音）。
3. **停止**後自動評分：總分、等級（D 到 SSS）與音準、節奏、安定度、顫音、抑揚、長音六項。八度音視為同一個音，整體移調也不扣分。

完整說明：[docs/INSTALL.md](https://github.com/Hikari-Tsai/karaoke-battle/blob/{{TAG}}/docs/INSTALL.md) ·
評分方式：[docs/SCORING.md](https://github.com/Hikari-Tsai/karaoke-battle/blob/{{TAG}}/docs/SCORING.md)

> 轉譜模型 GAME 1.0（Team OpenVPI）採 CC BY-NC-SA 4.0（非商業）授權，引用與致謝見 [docs/CITATIONS.md](https://github.com/Hikari-Tsai/karaoke-battle/blob/{{TAG}}/docs/CITATIONS.md)；以 yt-dlp 下載 YouTube 內容僅供個人本機使用。

---
