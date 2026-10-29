<p align="center">
  <img src="docs/icon.png" width="160" alt="Karaoke Battle">
</p>

<h1 align="center">Karaoke Battle</h1>

<p align="center">
  <a href="https://github.com/Hikari-Tsai/karaoke-battle/releases/latest/download/KaraokeBattle-macos-universal.dmg"><img src="https://img.shields.io/badge/macOS_Universal-000000?style=for-the-badge&logo=apple&logoColor=white" alt="macOS 版（ユニバーサル）をダウンロード"></a>
  <a href="https://github.com/Hikari-Tsai/karaoke-battle/releases/latest/download/KaraokeBattle-windows-x64.zip"><img src="https://img.shields.io/badge/Windows_x64-0078D4?style=for-the-badge&logo=data:image/svg%2bxml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0id2hpdGUiPjxwYXRoIGQ9Ik0wIDBoMTEuMnYxMS4ySDB6TTEyLjggMEgyNHYxMS4ySDEyLjh6TTAgMTIuOGgxMS4yVjI0SDB6TTEyLjggMTIuOEgyNFYyNEgxMi44eiIvPjwvc3ZnPg==" alt="Windows x64 版をダウンロード"></a>
  <br>
  <a href="https://github.com/Hikari-Tsai/karaoke-battle/releases/latest"><img src="https://img.shields.io/github/v/release/Hikari-Tsai/karaoke-battle?label=latest%20release" alt="最新リリース"></a>
  <a href="https://github.com/Hikari-Tsai/karaoke-battle/actions/workflows/build.yml"><img src="https://github.com/Hikari-Tsai/karaoke-battle/actions/workflows/build.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT ライセンス"></a>
</p>
<p align="center"><a href="README.md">中文</a> · <a href="README.en.md">English</a> · <b>日本語</b></p>

配信者向けのカラオケ採点システムです。YouTube のリンクを貼り付けるか動画・音声ファイルをドラッグ＆ドロップすると、アプリがローカルで
ボーカル分離、メロディの採譜、参照ピッチの抽出を行います。歌唱中はスクロール式のピアノロールに参照メロディとリアルタイムの
F0 曲線を表示し、歌い終わると音程、リズム、安定感、ビブラート、抑揚、ロングトーンに基づいて定量的なスコアを出します。

* macOS（Universal、Apple Silicon + Intel）と Windows x64 に対応した、Flutter デスクトップアプリ + C++ ネイティブエンジンです。
* すべてのモデルは初回実行時に Hugging Face の `aaatmy/*` からダウンロードされ、SHA-256 で検証されます。インストーラーにモデルは含まれません。
* Windows では CUDA を主な高速化経路としています（自動検出し、不足している場合はドライバーのインストールを案内して CUDA ランタイムをダウンロードします）。
  フォールバックは DirectML と CPU です。macOS は CPU を使用します（一部のモデルでは CoreML を試行します）。フォールバックは採点の精度には影響せず、曲の準備の速度にのみ影響します。

## アーキテクチャ

詳細は [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)（英語）、[docs/BACKENDS.md](docs/BACKENDS.md)（英語）、[docs/BUILD.md](docs/BUILD.md)（英語）をご覧ください。

| レイヤー | 内容 |
| --- | --- |
| `app/` | Flutter UI：曲ライブラリ、曲の準備パイプライン、歌唱画面（スクロール MIDI + リアルタイム F0）、結果、設定；Dart 採点モジュール |
| `engine/` | C++17 エンジン（dart:ffi）：ONNX Runtime の動的ロード、MDX-Net 分離、GAME 採譜、SwiftF0 ピッチ、miniaudio によるリアルタイム音声と再生クロック、signalsmith-stretch によるキー変更 |
| `scripts/` | ORT、sidecar（yt-dlp / ffmpeg / deno）、CUDA pack のバージョン一覧とダウンロードスクリプト |
| `.github/workflows/` | macOS universal と Windows の CI パッケージング |

## モデル

| モデル | 用途 | 作者 | ライセンス |
| --- | --- | --- | --- |
| [aaatmy/game-large-onnx](https://huggingface.co/aaatmy/game-large-onnx) / [game-small-onnx](https://huggingface.co/aaatmy/game-small-onnx) | ボーカルの MIDI 変換（GAME 1.0 Large / Small） | Team OpenVPI | 重み CC BY-NC-SA 4.0（非商用）、コード MIT |
| [aaatmy/uvr-mdx-net-onnx](https://huggingface.co/aaatmy/uvr-mdx-net-onnx) | ボーカル分離 Kim_Vocal_2 | KimberleyJensen（UVR 経由で配布） | ライセンスファイルなし；作者による公開の許諾表明 |
| 同上 | 伴奏分離 UVR-MDX-NET-Inst_HQ_4 | UVR コア開発者 Anjok07、aufr33 | MIT（UVR の表記に準拠） |
| [aaatmy/swift-f0-onnx](https://huggingface.co/aaatmy/swift-f0-onnx) | リアルタイム・オフライン F0 | Lars Nieradzik | MIT |
| [aaatmy/beat-this-onnx](https://huggingface.co/aaatmy/beat-this-onnx) | 拍・小節頭・BPM（拍線、メトロノーム） | CPJKU（Foscarin、Schlüter、Widmer） | MIT |
| [aaatmy/kuromoji-ipadic-pack](https://huggingface.co/aaatmy/kuromoji-ipadic-pack) | 日本語歌詞のローマ字表記（日本語歌詞がある場合のみダウンロード） | kuromoji.js（Takuya Asano）、mecab-ipadic（NAIST） | Apache-2.0、IPADIC 条項 |

三つのミラーはいずれも上流の公式ファイルをそのままコピーしたもので（再学習・量子化・再エクスポートは行っていません）、manifest と SHA-256 を追加しているだけです。
GAME の重みは非商用ライセンスのため、アプリ全体の利用もその条項の制約を受けます。

## 採点

歌唱終了後、録音した F0 曲線を原曲の歌声（GAME の音符と SwiftF0 の参照曲線）と整列させて比較し、6 項目のサブスコアを算出します：
**音程**（Raw Chroma Accuracy）、**リズム**（音ゲーのように音符ごとに PERFECT／GREAT／GOOD／MISS を判定、判定幅は BPM で拡縮）、**安定感**、
**ビブラート**、**抑揚**（エネルギー曲線の相関）、**ロングトーン**。これらを重み付けして 0〜100 の総合スコアと D〜SSS のランクを出します。

設計上のポイントは三つです：**オクターブ違いは同じ音とみなす**（1 オクターブ上や下で歌っても正解）、**全体の移調を許容する**
（全曲で一つの半音シフト量のみを使用し、自動推定）、そして**原曲歌唱のポルタメントと GAME の採譜誤差を許容する**ことです。各 frame
の目標には原曲の F0 曲線と GAME の音符ピッチの両方があり、どちらかに合っていれば正解とします。原曲に合わせて音を滑らせても、音をまっすぐ歌っても構いません。
整列手法、指標の定義、数式、キャリブレーション結果の詳細は [docs/SCORING.ja.md](docs/SCORING.ja.md) をご覧ください。

## インストールと使い方

上部のバッジから DMG または zip をダウンロードしてインストールしてください。macOS では初回、アプリを右クリックして「開く」を選んでください（未公証のため）。Windows では SmartScreen で「実行」を選んでください。
初回起動時にモデル（約 500 MB）と外部ツールをダウンロードします。Windows では CUDA ランタイムのダウンロードも選択できます。
曲を追加（YouTube リンクまたはファイルのドラッグ＆ドロップ）したら曲の準備が終わるまで待ち、「プレビュー」を押して歌唱画面に入ります。先に原曲や伴奏を聴きながらピアノロールを確認でき、ヘッドホンを着けて「録音開始」を押すと採点が始まります。
手順の詳細、データの保存場所、よくある質問は [docs/INSTALL.md](docs/INSTALL.md)（中国語）をご覧ください。

## ビルド

```bash
# エンジン（macOS、universal）
scripts/fetch_ort.sh
cmake -S engine -B engine/build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build engine/build -j

# App
cd app && flutter pub get && flutter run -d macos
```

開発モードでは、アプリが自動的に `engine/build/` からエンジンを、`engine/third_party/onnxruntime/` から ORT を探します。

## 謝辞

引用形式の全文（BibTeX を含む）と各上流の要件は [docs/CITATIONS.md](docs/CITATIONS.md)（中国語）をご覧ください。

* **GAME 1.0 Small / Large**（メロディ採譜モデル）by **Team OpenVPI**、
  出典 [openvpi/GAME v1.0.3](https://github.com/openvpi/GAME/releases/tag/v1.0.3)、
  ライセンス [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/)。
  モデルは yqzhishen が公開し、データのアノテーションは 挚彬Club、YQ之神、小狼、幽寂 が提供しました。本アプリは公式の ONNX ファイルを改変せずに使用しています。openvpi による承認を受けたものではありません。
* **Kim_Vocal_2**（ボーカル分離）by **KimberleyJensen**。独自に学習され、UVR 経由で配布されています。上流にライセンスファイルはなく、作者の
  [公開の許諾表明](https://github.com/KimberleyJensen/kmdx-net_music-source-separation/issues/3)（2026-10-02）に基づいて使用しています。
* **UVR-MDX-NET-Inst_HQ_4**（伴奏分離）by **Ultimate Vocal Remover** コア開発者 **Anjok07 と aufr33**（MIT、UVR のクレジット表記要件に従っています）。
* MDX-Net のアーキテクチャと学習コードは **kuielab** によるものです（Choi et al., *TFC-TDF-U-Net*, ISMIR 2020；Kim et al., *KUIELab-MDX-Net*, MDX Workshop @ ISMIR 2021）。
  エンジンの分離コードは [python-audio-separator](https://github.com/nomadkaraoke/python-audio-separator)（MIT）から移植しました。
* **SwiftF0** by Lars Nieradzik（*SwiftF0: Fast and Accurate Monophonic Pitch Detection*, arXiv:2508.18440, 2025）。
* 採点指標の定義は **mir_eval**（Raffel et al., ISMIR 2014）とメロディ抽出の評価に関する文献（Poliner et al. 2007；Salamon et al. 2014）に基づいています。
  リアルタイムのピッチ追跡には **MPM**（McLeod & Wyvill, ICMC 2005）を、整列には Sakoe-Chiba バンド付き DTW（1978）を使用しています。
* キー変更には [Signalsmith Stretch](https://github.com/Signalsmith-Audio/signalsmith-stretch)、音声 I/O には miniaudio、推論には ONNX Runtime を使用しています。

## 法的事項

本アプリに組み込まれた yt-dlp による動画・音声のダウンロードは、ユーザーがローカルで個人的に利用する目的に限ります。YouTube コンテンツのダウンロードは
YouTube の利用規約に違反する可能性があり、その責任はユーザー自身が負うものとします。アプリが楽曲データをアップロードまたは配布することはありません。

## ライセンス

コードは MIT ライセンスです。[LICENSE](LICENSE) をご覧ください。サードパーティのコンポーネントについては [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) をご覧ください。
