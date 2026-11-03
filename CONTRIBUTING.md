# 參與 Karaoke Battle

**中文** · [English](CONTRIBUTING.en.md) · [日本語](CONTRIBUTING.ja.md)

謝謝你願意幫忙！Karaoke Battle 是做給直播主用的歌唱評分 App，所以最主要的測試方式就是：**直接在直播中使用，遇到問題就回報到 [Issues](https://github.com/Hikari-Tsai/karaoke-battle/issues)**。

## 在直播中測試

1. 到 [Releases](https://github.com/Hikari-Tsai/karaoke-battle/releases/latest) 下載最新版，安裝方式見 [安裝與使用說明](docs/INSTALL.md)。
2. 照平常直播的方式使用：加歌、預覽、錄製、看結果和回放、匯出重播檔、截分享圖、搭配 OBS 擷取視窗都可以。
3. 不用特別寫測試腳本。直播時覺得「怪怪的」都值得回報，例如：
   * 備歌失敗或卡住、App 閃退或沒有回應；
   * 分數、判定字卡或音高線和你聽到的明顯對不上；
   * 字卡、歌詞或伴奏和畫面不同步；
   * 畫面在直播畫質下看不清楚，或觀眾看不懂；
   * 操作卡手、在直播中不方便用的地方。
4. 直播有錄影（VOD）的話，記下出問題的時間點，回報時附上連結最有幫助。

## 回報問題

App 裡有兩個入口，按下去會開啟 GitHub 的回報表單，並自動帶入版本、作業系統與運算後端：

* 左側導覽列最下方的 **「回報問題」**；
* **「關於」** 頁的 **「回報問題」** 按鈕。

也可以直接到 [新增 Issue](https://github.com/Hikari-Tsai/karaoke-battle/issues/new/choose)。回報需要 GitHub 帳號。

請盡量附上：

| 項目 | 說明 |
| --- | --- |
| 版本與環境 | 從 App 開啟表單會自動帶入；手動回報請寫「關於」頁的版本、作業系統、CPU／CUDA／DirectML |
| 發生什麼事 | 你做了什麼、預期看到什麼、實際看到什麼 |
| 重現步驟 | 能重現的話寫下步驟；只發生一次也請回報 |
| 歌曲 | YouTube 連結，或是哪種本機檔案（mp3、mp4…） |
| 畫面 | 截圖、錄影片段，或直播 VOD 的連結與時間點 |
| 重播檔（選填） | 評分有疑問時，可附上該次演唱匯出的重播檔 zip |

注意事項：

* Issue 是**公開**的。重播檔 zip 含有你的演唱錄音，請自行決定是否附上；不要貼帳號、密碼或其他個人資料。
* 先搜尋一下有沒有人回報過同樣的問題，有的話在原本的 Issue 補充你的狀況即可。
* 一個 Issue 只寫一個問題，比較好追蹤。

## 功能建議

想要的功能也歡迎開 Issue，請說明你在直播中想做到什麼，以及現在卡在哪裡。

## 貢獻程式碼

* 建置方式見 [docs/BUILD.md](docs/BUILD.md)，架構見 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)，評分演算法見 [docs/SCORING.md](docs/SCORING.md)。
* 送 Pull Request 前，請在 `app/` 跑過 `flutter analyze` 與 `flutter test`；改到引擎的話請確認 macOS 與 Windows 都能建置。
* 改到評分方式時，請一併更新 `docs/SCORING*.md` 三種語言；改到 UI 文字時，請在 `app/lib/state/i18n.dart` 補齊中、英、日三種語言。
* 不要把模型檔或第三方執行檔加進 repo。新增模型前請先確認授權，見 [docs/CITATIONS.md](docs/CITATIONS.md) 與 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
* 送出的程式碼會以本專案的 [MIT 授權](LICENSE) 釋出。
