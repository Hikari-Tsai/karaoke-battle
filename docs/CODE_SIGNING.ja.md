# コード署名ポリシー（Code signing policy）

[中文](CODE_SIGNING.md) · [English](CODE_SIGNING.en.md) · [日本語](CODE_SIGNING.ja.md)

Free code signing provided by [SignPath.io](https://about.signpath.io/), certificate by [SignPath Foundation](https://signpath.org/)

Windows 版のコード署名は SignPath.io が無償で提供し、証明書は SignPath Foundation が発行しています。

> 現在の状況：SignPath Foundation に申請中です。承認されるまでの Windows 版は未署名のため、
> 起動時に SmartScreen の「Windows によって PC が保護されました」が表示されます。

## 署名の対象

* このリポジトリのソースコードから GitHub Actions（[`.github/workflows/build.yml`](../.github/workflows/build.yml)）で
  ビルドしたファイルのみ：`karaoke_battle.exe` と `karaoke_engine.dll`。
* 同じ zip に入っている上流のファイル（Flutter、ONNX Runtime、DirectML、media_kit などの DLL）は
  本プロジェクトの証明書では署名せず、上流の署名（あれば）をそのまま残します。
* 各リリースは、下記の承認者が SignPath で署名リクエストを承認してから署名されます。
* macOS 版はこのポリシーの対象外です（macOS は Apple の署名と公証を使います）。

## チームの役割

| 役割 | メンバー |
| --- | --- |
| コミッターとレビュアー（Committers and reviewers） | [Hikari-Tsai](https://github.com/Hikari-Tsai) |
| 承認者（Approvers） | [Hikari-Tsai](https://github.com/Hikari-Tsai)（リポジトリ所有者） |

外部コントリビューターのプルリクエストは、ビルドスクリプトや CI 設定の変更も含めて、レビューしてからマージします。
メンバー全員が GitHub と SignPath で多要素認証を使っています。

## プライバシーポリシー

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
| カラオケ・ストリーミングのランキングサイト（好樂迪、錢櫃、JOYSOUND、DAM、KKBOX） | 「人気曲」ページがランキングを読み込むとき | ランキング取得のリクエストのみ |
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
