# 程式碼簽章政策（Code signing policy）

[中文](CODE_SIGNING.md) · [English](CODE_SIGNING.en.md) · [日本語](CODE_SIGNING.ja.md)

Free code signing provided by [SignPath.io](https://about.signpath.io/), certificate by [SignPath Foundation](https://signpath.org/)

Windows 版由 SignPath.io 免費提供程式碼簽章，憑證由 SignPath Foundation 核發。

> 目前狀態：已向 SignPath Foundation 申請，審核通過前的 Windows 版仍未簽章，
> 開啟時 SmartScreen 會出現「Windows 已保護您的電腦」。

## 簽什麼

* 只簽這個儲存庫的原始碼由 GitHub Actions（[`.github/workflows/build.yml`](../.github/workflows/build.yml)）
  建置出來的檔案：`karaoke_battle.exe` 與 `karaoke_engine.dll`。
* 一起放在 zip 裡的上游檔案（Flutter、ONNX Runtime、DirectML、media_kit 等 DLL）不用本專案的憑證簽章，
  保留上游原本的簽章（若有）。
* 每個版本都要由下面的核准者在 SignPath 手動核准後才會簽章。
* macOS 版不在此政策內（macOS 用 Apple 的簽章與公證）。

## 團隊角色

| 角色 | 成員 |
| --- | --- |
| 提交者與審查者（Committers and reviewers） | [Hikari-Tsai](https://github.com/Hikari-Tsai) |
| 核准者（Approvers） | [Hikari-Tsai](https://github.com/Hikari-Tsai)（儲存庫擁有者） |

外部貢獻者的 Pull Request 都要經過審查才會合併，建置腳本與 CI 設定的變更也一樣。
所有成員的 GitHub 與 SignPath 帳號都啟用雙重驗證。

## 隱私權政策

Karaoke Battle 沒有帳號、沒有遙測、沒有使用分析，也不會把錄音、歌曲或演唱紀錄上傳到任何地方；
這些檔案都留在你的電腦上（位置見 [安裝與使用說明 → 資料位置](INSTALL.md#資料位置)）。

App 只會為了下列用途連上網路。這些都是一般的 HTTPS 請求，對方伺服器會看到你的 IP 位址與 App 名稱：

| 連線對象 | 什麼時候 | 傳出的內容 |
| --- | --- | --- |
| GitHub（`api.github.com`、`raw.githubusercontent.com`、`github.com`） | 每次啟動檢查是否有新版本、讀取外部工具清單；下載 yt-dlp、Deno、ffmpeg 時 | 只有下載請求 |
| ffmpeg 下載站（`ffmpeg.martin-riedl.de`、`evermeet.cx`） | 系統沒有 ffmpeg、App 自動下載時 | 只有下載請求 |
| Hugging Face（`huggingface.co`） | 你按下下載模型時 | 只有下載請求 |
| PyPI（`files.pythonhosted.org`） | 你在 Windows 選擇下載 CUDA 執行環境時 | 只有下載請求 |
| YouTube 等影音網站（透過 yt-dlp） | 你貼上連結新增歌曲時 | 你貼的連結 |
| KTV 與串流排行榜網站（好樂迪、錢櫃、JOYSOUND、DAM、KKBOX） | 「熱門歌單」頁載入排行榜時 | 只有讀取排行榜的請求 |
| Anthropic 或 OpenAI | 只有在你填入自己的 API Key 並要求 AI 演唱建議時 | 這次演唱的分析摘要（文字，不含錄音；歌名可選擇隱藏）與你的 API Key |

「回報問題」只會在瀏覽器打開 GitHub 的問題表單，內容由你確認後自己送出。

上述服務各有自己的隱私權政策：
[GitHub](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement)、
[Hugging Face](https://huggingface.co/privacy)、
[Anthropic](https://www.anthropic.com/legal/privacy)、
[OpenAI](https://openai.com/policies/privacy-policy)、
[YouTube／Google](https://policies.google.com/privacy)。

## 解除安裝

見 [安裝與使用說明 → 解除安裝](INSTALL.md#解除安裝)。
