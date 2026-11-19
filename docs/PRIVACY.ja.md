# プライバシーポリシー（Privacy policy）

[中文](PRIVACY.md) · [English](PRIVACY.en.md) · [日本語](PRIVACY.ja.md)

Karaoke Battle にはアカウントもテレメトリも利用状況の分析もなく、録音・曲・歌唱記録をどこにもアップロードしません。
これらはすべてお使いのコンピューターに残ります（[インストールガイドのデータの場所](INSTALL.md#資料位置)を参照）。

アプリがネットワークに接続するのは次の目的だけです。いずれも通常の HTTPS リクエストで、
接続先のサーバーにはあなたの IP アドレスとアプリ名が見えます。

| 接続先 | タイミング | 送信される内容 |
| --- | --- | --- |
| GitHub（`api.github.com`、`raw.githubusercontent.com`、`github.com`） | 起動のたびに新しいバージョンの確認と外部ツール一覧の読み込み。yt-dlp・Deno・ffmpeg のダウンロード時 | ダウンロードのリクエストのみ |
| ffmpeg の配布サイト（`ffmpeg.martin-riedl.de`、`evermeet.cx`） | システムに ffmpeg がなく、アプリが自動でダウンロードするとき | ダウンロードのリクエストのみ |
| Hugging Face（`huggingface.co`） | モデルをダウンロードするとき | ダウンロードのリクエストのみ |
| PyPI（`files.pythonhosted.org`） | Windows で CUDA 実行環境のダウンロードを選んだとき | ダウンロードのリクエストのみ |
| YouTube などの動画サイト（yt-dlp 経由） | リンクを貼って曲を追加するとき | 貼り付けたリンク |
| KTV Charts サイト（`hikari-tsai.github.io`、GitHub Pages） | 「人気曲」ページがランキングを読み込むとき（好樂迪・錢櫃・JOYSOUND・DAM・KKBOX のランキングを同サイトがまとめています） | ランキングの取得リクエストのみ |
| Anthropic または OpenAI | ご自身の API キーを入力し、AI の歌唱アドバイスを求めたときのみ | その歌唱の分析結果の要約（テキスト。録音は含まず、曲名は非表示にできます）と API キー |

「問題を報告」はブラウザーで GitHub の Issue フォームを開くだけで、内容を確認してから送信するのはあなた自身です。

各サービスのプライバシーポリシー：
[GitHub](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement)、
[Hugging Face](https://huggingface.co/privacy)、
[Anthropic](https://www.anthropic.com/legal/privacy)、
[OpenAI](https://openai.com/policies/privacy-policy)、
[YouTube／Google](https://policies.google.com/privacy)。

## アンインストール

インストールガイドの[アンインストール](INSTALL.md#解除安裝)を参照してください。
