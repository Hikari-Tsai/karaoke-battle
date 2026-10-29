# 引用與致謝

本文列出 Karaoke Battle 使用的模型、演算法與移植的程式碼，以及各自上游**官方要求或建議**的引用方式。
每一節先說明上游要求什麼，再給出符合該要求的致謝文字與 BibTeX（有論文者）。
授權條款的完整清單見 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。

## 1. 模型

### 1.1 GAME（旋律轉譜）

* 上游：<https://github.com/openvpi/GAME>（程式碼 MIT，Copyright (c) 2026 Team OpenVPI）。
* 模型權重：[GAME 1.0 Small / Large](https://github.com/openvpi/GAME/releases/tag/v1.0.0)，
  ONNX 匯出版附在 [v1.0.3](https://github.com/openvpi/GAME/releases/tag/v1.0.3)。
  上游在 release 頁面聲明「The model files apply CC BY-NC-SA 4.0 license」。
* 上游沒有論文，也沒有要求的 BibTeX；**唯一的硬性要求是 CC BY-NC-SA 4.0 的姓名標示條款**
  （標示作者、作品名稱、來源連結、授權名稱與連結，並註明是否修改）。

依 CC BY-NC-SA 4.0 第 3(a) 條的姓名標示（Title / Author / Source / License 四要素）：

> **GAME 1.0 Small 與 GAME 1.0 Large**（旋律轉譜模型），作者 **Team OpenVPI**（openvpi/GAME 專案，
> 模型由 yqzhishen 發布；資料標註由 挚彬Club、YQ之神、小狼、幽寂 提供）。
> 來源：<https://github.com/openvpi/GAME/releases/tag/v1.0.3>。
> 授權：[CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/)。
> 本 App 使用官方發布的 ONNX 檔案，**未做任何修改**；僅於 Hugging Face
> [aaatmy/game-large-onnx](https://huggingface.co/aaatmy/game-large-onnx) 與
> [aaatmy/game-small-onnx](https://huggingface.co/aaatmy/game-small-onnx) 建立附加 manifest 與校驗碼的鏡像。
> 本 App 不為 openvpi 所背書。

引擎中的 `engine/src/models/game.*` 與 `slicer.*` 是 GAME 的推論程式（`inference/me_infer.py`、`slicer2.py`）
的 C++ 移植，該部分程式碼為 MIT（Team OpenVPI）。

因為權重是非商業授權，整個 App 的使用受此條款約束；相同方式分享條款只在重新散布
或衍生這些權重時生效，鏡像已依此原樣附上授權全文。

### 1.2 MDX-Net 分離模型（Kim_Vocal_2、UVR-MDX-NET-Inst_HQ_4、Voc_FT）

這三個模型的血統有三層，引用時要分開看：**架構**來自 kuielab，**權重**由兩組不同的人訓練，
**散布**經由 UVR。查證結果（2026-10-29）：

| 模型 | 訓練者 | 最上游 | 權重授權 |
| --- | --- | --- | --- |
| UVR-MDX-NET-Inst_HQ_4、Voc_FT | UVR 核心開發者 **Anjok07 與 aufr33** 自行訓練 | UVR 本身（README：「UVR's core developers trained all of the models provided in this package (except for the Demucs v3 and v4 4-stem models)」） | MIT，依 UVR README 的聲明與署名要求 |
| Kim_Vocal_2 | **KimberleyJensen**（獨立訓練，用 kuielab 的 mdx-net 訓練程式）；UVR 只是收錄散布 | <https://github.com/KimberleyJensen/kmdx-net_music-source-separation> | 上游無授權檔。作者於 2026-10-02 在該 repo [issue #3](https://github.com/KimberleyJensen/kmdx-net_music-source-separation/issues/3) 公開聲明：「You are free to use the MDX-Net model Kim_Vocal_2 (Kim_Vocal_2.onnx) in any way you like, including for commercial use.」這是作者的使用許可聲明而非正式授權條款，本專案依此使用並原文引用 |

架構的最上游是 kuielab（Woosung Choi、Minseok Kim 等）：單 stem 的 TFC-TDF-U-Net（ISMIR 2020）與
KUIELab-MDX-Net（MDX Workshop @ ISMIR 2021），程式碼 <https://github.com/kuielab/mdx-net>（MIT）。
kuielab 沒有指定引用格式，但有兩篇論文，引用如下。

上游要求：UVR README「License」節：「For all third-party application developers who wish to use our models,
please honor the MIT license by providing credit to UVR and its developers.」KimberleyJensen 與 kuielab 沒有提出署名或引用要求。

致謝文字：

> 人聲分離使用 MDX-Net 模型 **Kim_Vocal_2**（由 **KimberleyJensen** 訓練，經作者公開許可使用）與
> **UVR-MDX-NET-Inst_HQ_4**（由 **Ultimate Vocal Remover** 核心開發者 **Anjok07 與 aufr33** 訓練，MIT）。
> MDX-Net（TFC-TDF-U-Net / KUIELab-MDX-Net）架構與訓練程式來自 **kuielab**（Woosung Choi、Minseok Kim 等）。
> 模型檔未經修改，自 UVR 的公開模型庫取得，鏡像於
> [aaatmy/uvr-mdx-net-onnx](https://huggingface.co/aaatmy/uvr-mdx-net-onnx)。

```bibtex
@inproceedings{choi2020investigating,
  title     = {Investigating U-Nets with Various Intermediate Blocks for Spectrogram-based Singing Voice Separation},
  author    = {Choi, Woosung and Kim, Minseok and Chung, Jaehwa and Lee, Daewon and Jung, Soonyoung},
  booktitle = {Proceedings of the 21st International Society for Music Information Retrieval Conference (ISMIR)},
  year      = {2020},
  eprint    = {1912.02591},
  archivePrefix = {arXiv},
  url       = {https://arxiv.org/abs/1912.02591}
}

@inproceedings{kim2021kuielab,
  title     = {KUIELab-MDX-Net: A Two-Stream Neural Network for Music Demixing},
  author    = {Kim, Minseok and Choi, Woosung and Chung, Jaehwa and Lee, Daewon and Jung, Soonyoung},
  booktitle = {Music Demixing Workshop (MDX) at the 22nd International Society for Music Information Retrieval Conference (ISMIR)},
  year      = {2021},
  eprint    = {2111.12203},
  archivePrefix = {arXiv},
  url       = {https://arxiv.org/abs/2111.12203}
}
```

引擎的 `engine/src/models/mdx.*` 是
[python-audio-separator](https://github.com/nomadkaraoke/python-audio-separator)（MIT，Copyright (c) 2023 karaokenerds）
`MDXSeparator.demix()` 的逐行移植，該函式本身又移植自 UVR 的 `separate.py`（MIT）。

### 1.3 SwiftF0（即時與離線 F0）

* 上游：<https://github.com/lars76/swift-f0>（Lars Nieradzik，MIT）。
* 上游 README「Citation」節：「If you use SwiftF0 in your research, please cite」，並附下列 BibTeX。
  README 同時註明論文描述的是 0.1.x 版，0.2.0 起換成更小的網路；本 App 使用 0.3.0 的 `model.onnx`，未修改，
  鏡像於 [aaatmy/swift-f0-onnx](https://huggingface.co/aaatmy/swift-f0-onnx)。

```bibtex
@misc{nieradzik2025swiftf0,
      title={SwiftF0: Fast and Accurate Monophonic Pitch Detection},
      author={Lars Nieradzik},
      year={2025},
      eprint={2508.18440},
      archivePrefix={arXiv},
      primaryClass={cs.SD},
      url={https://arxiv.org/abs/2508.18440},
}
```

### 1.4 Beat This!（節拍、重拍與 BPM）

* 上游：<https://github.com/CPJKU/beat_this>（程式碼與模型權重皆為 MIT，Copyright (c) 2024 Institute of Computational Perception, JKU Linz）。
* 上游 README 提供下列引用格式。本 App 使用 final0 檢查點的 ONNX 轉換版
  [aaatmy/beat-this-onnx](https://huggingface.co/aaatmy/beat-this-onnx)，未修改權重。

```bibtex
@inproceedings{foscarin2024beatthis,
    author = {Francesco Foscarin and Jan Schl{\"u}ter and Gerhard Widmer},
    title = {Beat this! Accurate beat tracking without {DBN} postprocessing},
    year = 2024,
    month = nov,
    booktitle = {Proceedings of the 25th International Society for Music Information Retrieval Conference (ISMIR)},
    address = {San Francisco, CA, United States},
}
```

## 2. 評分演算法

評分模組（[docs/SCORING.md](SCORING.md)）是自行實作的純 Dart 程式，沒有引入任何評分套件，
但指標定義與對齊方法取自下列文獻。這些文獻沒有「必須引用」的授權義務，
列出是為了標明出處；其中 mir_eval 的作者明確請求使用者引用其論文。

| 用途 | 出處 | 上游要求 |
| --- | --- | --- |
| Frame 層級指標（Raw Pitch Accuracy、Raw Chroma Accuracy、Overall Accuracy、Voicing Recall / False Alarm）與音符層級 onset/offset 匹配的定義 | mir_eval（`melody`、`transcription` 模組） | README：「If you use mir_eval in a research project, please cite the following paper」 |
| 旋律抽取指標的原始定義（RPA / RCA 的 50 cent 容差、八度等價） | Poliner et al. 2007；Salamon et al. 2014 | 無 |
| 即時音高追蹤（MPM，正規化平方差函數 + 峰值挑選） | McLeod & Wyvill 2005 | 無 |
| 帶狀限制的動態時間扭曲（Sakoe-Chiba band） | Sakoe & Chiba 1978 | 無 |

```bibtex
@inproceedings{raffel2014mir_eval,
  title     = {mir\_eval: A Transparent Implementation of Common {MIR} Metrics},
  author    = {Raffel, Colin and McFee, Brian and Humphrey, Eric J. and Salamon, Justin and Nieto, Oriol and Liang, Dawen and Ellis, Daniel P. W.},
  booktitle = {Proceedings of the 15th International Society for Music Information Retrieval Conference (ISMIR)},
  year      = {2014}
}

@article{poliner2007melody,
  title   = {Melody Transcription From Music Audio: Approaches and Evaluation},
  author  = {Poliner, Graham E. and Ellis, Daniel P. W. and Ehmann, Andreas F. and G{\'o}mez, Emilia and Streich, Sebastian and Ong, Beesuan},
  journal = {IEEE Transactions on Audio, Speech, and Language Processing},
  volume  = {15},
  number  = {4},
  pages   = {1247--1256},
  year    = {2007}
}

@article{salamon2014melody,
  title   = {Melody Extraction from Polyphonic Music Signals: Approaches, Applications, and Challenges},
  author  = {Salamon, Justin and G{\'o}mez, Emilia and Ellis, Daniel P. W. and Richard, Ga{\"e}l},
  journal = {IEEE Signal Processing Magazine},
  volume  = {31},
  number  = {2},
  pages   = {118--134},
  year    = {2014}
}

@inproceedings{mcleod2005smarter,
  title     = {A Smarter Way to Find Pitch},
  author    = {McLeod, Philip and Wyvill, Geoff},
  booktitle = {Proceedings of the International Computer Music Conference (ICMC)},
  year      = {2005}
}

@article{sakoe1978dynamic,
  title   = {Dynamic Programming Algorithm Optimization for Spoken Word Recognition},
  author  = {Sakoe, Hiroaki and Chiba, Seibi},
  journal = {IEEE Transactions on Acoustics, Speech, and Signal Processing},
  volume  = {26},
  number  = {1},
  pages   = {43--49},
  year    = {1978}
}
```

## 3. 引擎中移植或改寫的程式碼

| 引擎檔案 | 來源 | 授權 |
| --- | --- | --- |
| `engine/src/models/game.*`、`slicer.*` | openvpi/GAME `inference/me_infer.py`、`data.py`、`slicer2.py` | MIT（Team OpenVPI） |
| `engine/src/models/mdx.*` | python-audio-separator `mdx_separator.py`，源自 UVR `separate.py` | MIT |
| `engine/src/dsp/mpm.*` | McLeod & Wyvill 2005 的演算法，自行實作 | — |
| `engine/src/audio/*`（升降 key） | Signalsmith Stretch 函式庫 | MIT |

其餘第三方函式庫（ONNX Runtime、miniaudio、pocketfft、dr_wav、nlohmann/json、yt-dlp、FFmpeg、Deno、Flutter 套件）
只要求保留授權聲明，見 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。

## 4. 如何引用本專案

本專案本身沒有論文；需要引用時請用：

```bibtex
@software{tsai2026karaokebattle,
  author  = {Tsai, Hikari},
  title   = {Karaoke Battle: local karaoke scoring for streamers},
  year    = {2026},
  url     = {https://github.com/Hikari-Tsai/karaoke-battle}
}
```
