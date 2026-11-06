<p align="center">
  <img src="docs/icon.png" width="160" alt="Karaoke Battle">
</p>

<h1 align="center">Karaoke Battle</h1>

<p align="center">
  <a href="#download"><picture><source media="(prefers-color-scheme: dark)" srcset="https://img.shields.io/badge/Download-macOS%20%7C%20Windows-2EA44F?style=for-the-badge"><img src="https://img.shields.io/badge/Download-macOS%20%7C%20Windows-2EA44F?style=for-the-badge" height="36" alt="Download"></picture></a>
  <br>
  <a href="https://github.com/Hikari-Tsai/karaoke-battle/releases/latest"><img src="https://img.shields.io/github/v/release/Hikari-Tsai/karaoke-battle?label=latest%20release" alt="Latest release"></a>
  <a href="https://github.com/Hikari-Tsai/karaoke-battle/actions/workflows/build.yml"><img src="https://github.com/Hikari-Tsai/karaoke-battle/actions/workflows/build.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License"></a>
</p>

<p align="center"><a href="README.md">中文</a> · <b>English</b> · <a href="README.ja.md">日本語</a></p>

A karaoke scoring system for streamers. Paste a YouTube link or drop in an audio or video file, and the app
performs vocal separation, melody transcription and reference pitch extraction locally on your machine. While you
sing, a scrolling piano roll shows the reference melody alongside your live F0 curve; when you finish, you get
quantitative scores for pitch, rhythm, stability, vibrato, expression and long tone.

* macOS (Universal, Apple Silicon + Intel) and Windows x64; a Flutter desktop app with a native C++ engine.
* All models are downloaded from Hugging Face `aaatmy/*` on first run and verified with SHA-256; the installer does not bundle any models. Every launch checks that the models are complete; anything missing or damaged has to be downloaded again before the library opens.
* On Windows, CUDA is the primary acceleration path (detected automatically; if anything is missing, the app prompts you to install the driver and downloads the CUDA runtime),
  with DirectML and CPU as fallbacks. macOS uses the CPU (some models try CoreML). Fallbacks do not affect scoring accuracy, only song preparation speed.

## Download

<p align="center">
  <a href="https://github.com/Hikari-Tsai/karaoke-battle/releases/latest/download/KaraokeBattle-macos-universal.dmg"><picture><source media="(prefers-color-scheme: dark)" srcset="https://img.shields.io/badge/macOS-Apple%20Silicon%20%2B%20Intel-F2F2F2?style=for-the-badge&logo=apple&logoColor=black&labelColor=D9D9D9"><img src="https://img.shields.io/badge/macOS-Apple%20Silicon%20%2B%20Intel-000000?style=for-the-badge&logo=apple&logoColor=white&labelColor=1F1F1F" height="44" alt="Download for macOS (Apple Silicon + Intel)"></picture></a>
  &nbsp;
  <a href="https://github.com/Hikari-Tsai/karaoke-battle/releases/latest/download/KaraokeBattle-windows-x64.zip"><picture><source media="(prefers-color-scheme: dark)" srcset="https://img.shields.io/badge/Windows-10%20%2F%2011%20x64-0078D4?style=for-the-badge&labelColor=005A9E&logo=data:image/svg%2bxml;base64%2CPHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0id2hpdGUiPjxwYXRoIGQ9Ik0wIDBoMTEuMnYxMS4ySDB6TTEyLjggMEgyNHYxMS4ySDEyLjh6TTAgMTIuOGgxMS4yVjI0SDB6TTEyLjggMTIuOEgyNFYyNEgxMi44eiIvPjwvc3ZnPg=="><img src="https://img.shields.io/badge/Windows-10%20%2F%2011%20x64-0078D4?style=for-the-badge&labelColor=005A9E&logo=data:image/svg%2bxml;base64%2CPHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0id2hpdGUiPjxwYXRoIGQ9Ik0wIDBoMTEuMnYxMS4ySDB6TTEyLjggMEgyNHYxMS4ySDEyLjh6TTAgMTIuOGgxMS4yVjI0SDB6TTEyLjggMTIuOEgyNFYyNEgxMi44eiIvPjwvc3ZnPg==" height="44" alt="Download for Windows (10 / 11 x64)"></picture></a>
</p>

<p align="center">Free and open source (MIT) · <a href="docs/INSTALL.md">Installation guide</a> · <a href="https://github.com/Hikari-Tsai/karaoke-battle/releases">All versions and release notes</a></p>

<p align="center"><sub>macOS: open the DMG and drag the app to Applications; the first time, right-click the app and choose Open.<br>Windows: unzip and run <code>karaoke_battle.exe</code>. The models (about 500 MB) download on first launch.</sub></p>

## Features for streamers

Every clip below was recorded from the running app (demo song: "Swansong" by Josh Woodward, CC BY). The GIFs have no sound.

### Turn any song into karaoke

Paste a YouTube link or drop in a media file. In the background the app separates the vocals, builds the accompaniment, and transcribes the melody notes and reference pitch; when it is done you can sing. You can queue several songs at once.

<p align="center"><img src="docs/media/add-song.gif" width="720" alt="Pasting a YouTube link prepares the song in the background"></p>

### See exactly which notes went off

A scrolling piano roll shows every note of the original singer, and your pitch is drawn live on top of it: green is on pitch, yellow is close, red is off. Viewers get it at a glance. Each note also pops a rhythm-game PERFECT / GREAT / GOOD / MISS judgement as you sing it (the star button at the top right turns them off).

<p align="center"><img src="docs/media/sing.gif" width="720" alt="Singing screen: scrolling piano roll, live pitch line, judgements and lyrics"></p>

### Key shift and vocal return

Key moves the accompaniment and the reference notes together. The vocal return at the top right sends your voice to the headphones along with the music (and to the stream when OBS captures the app's audio), with an optional hall reverb.

<p align="center"><img src="docs/media/key-voice.gif" width="720" alt="Key shift, vocal return and hall reverb"></p>

### Scores and share cards

Right after you sing you get a 0–100 score, a rank from D to SSS and six sub-scores: staying in tune and on the beat gets you around 80, an S (91+) takes steady pitch and rhythm throughout, and wrong words cost nothing. and one click turns it into a share card for X, Instagram or Threads. Every take stays in the library, with your best score on top.

<p align="center"><img src="docs/media/results.gif" width="720" alt="Results: total score, rank, sub-scores and the share card"></p>

### Rhythm-game style judgements

While you sing and in the replay, PERFECT / GREAT / GOOD / MISS judgements pop up at the playhead, rhythm-game style. Each one weighs timing and pitch together and is tagged FAST / LATE and HIGH / LOW, so you can see at a glance whether a note was early, late, sharp or flat. Export a replay as a zip (the score data plus your vocal recording) and send it to a friend; they import it and watch your take.

<p align="center"><img src="docs/media/replay.gif" width="720" alt="Replay with PERFECT, GREAT, GOOD and MISS judgements popping up"></p>

### Fix notes by hand

Press "Edit notes" and drag a note up or down to fix it. While you drag, a sine tone plays the new pitch (not audible in the GIF). You can restore the original transcription at any time.

<p align="center"><img src="docs/media/edit-notes.gif" width="720" alt="Dragging a note to fix its pitch"></p>

### Import and edit lyrics

When the YouTube video has subtitles they become the lyrics, shown in a rounded typeface (jf open huninn) that reads well in Chinese, Japanese kana and English. When it has none, or the song is a local file, the app asks what to do:

* **Import a subtitle file**: SRT, VTT or LRC.
* **Paste the lyrics**: paste the whole song and it is timed automatically, by default from the notes found when the song was prepared (done in seconds), or with "AI listening", which hears the words first.
* **Generate lyrics with AI**: OpenAI Whisper speech recognition, which detects the sung language or takes the one you pick. The model is only downloaded when first used, after asking (about 6.2 GB on Windows, where it runs on the GPU; the 1.8 GB int8 build on Mac, where it runs on the CPU).
* **Type them in**.

<p align="center"><img src="docs/media/lyrics.gif" width="720" alt="Pasting lyrics in Preview, timed from the notes, with the rounded lyrics highlighted word by word, then nudging the timing"></p>

The lyrics button in Preview offers the same choices and moves the lyrics earlier or later with ◀ ▶ (double arrows: 0.5 s). "Edit lyrics…" in a song's menu edits the text and times line by line: press Enter as each line starts while the song plays, shift everything at once, split or merge lines, and export to SRT or LRC. The original YouTube subtitles are kept, so you can switch back at any time.

<p align="center"><img src="docs/media/lyrics-editor.gif" width="720" alt="The lyrics editor: pressing Enter on each line while the song plays, then exporting to SRT or LRC"></p>

### Hot songs

The "Hot songs" tab reads the weekly request charts straight from the Holiday KTV, Cashbox Party, JOYSOUND and DAM websites, plus the KKBOX weekly single charts. Switch between languages or genres (Mandarin, Taiwanese, Cantonese, anime, VOCALOID…) and see the rank, song, artist, the number to enter on the karaoke machine and the counting period; the two Taiwanese operators and KKBOX also show the movement since last week (KKBOX is a streaming chart, so it has no machine numbers). Handy when you can't decide what to sing. Results are kept for 6 hours and can be refreshed by hand. Each source has a tab at the top; each tab ends with a link to the chart on the source's website, and every song has a "Search on YouTube" button.

## Architecture

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/BACKENDS.md](docs/BACKENDS.md) and [docs/BUILD.md](docs/BUILD.md) for details.

| Layer | Contents |
| --- | --- |
| `app/` | Flutter UI: song library, song preparation pipeline, singing screen (scrolling MIDI + live F0), results, settings; Dart scoring module |
| `engine/` | C++17 engine (dart:ffi): dynamic loading of ONNX Runtime, MDX-Net separation, GAME transcription, SwiftF0 pitch, miniaudio real-time audio and playback clock, signalsmith-stretch key shifting |
| `scripts/` | Version manifests and download scripts for ORT, sidecars (yt-dlp / ffmpeg / deno) and the CUDA pack |
| `.github/workflows/` | CI packaging for macOS universal and Windows |

## Models

| Model | Purpose | Author | License |
| --- | --- | --- | --- |
| [aaatmy/game-large-onnx](https://huggingface.co/aaatmy/game-large-onnx) / [game-small-onnx](https://huggingface.co/aaatmy/game-small-onnx) | Vocals to MIDI (GAME 1.0 Large / Small) | Team OpenVPI | Weights CC BY-NC-SA 4.0 (non-commercial), code MIT |
| [aaatmy/uvr-mdx-net-onnx](https://huggingface.co/aaatmy/uvr-mdx-net-onnx) | Vocal separation, Kim_Vocal_2 | KimberleyJensen (distributed via UVR) | No license file; author's public permission statement |
| Same as above | Accompaniment separation, UVR-MDX-NET-Inst_HQ_4 | UVR core developers Anjok07, aufr33 | MIT (per UVR's statement) |
| [aaatmy/swift-f0-onnx](https://huggingface.co/aaatmy/swift-f0-onnx) | Real-time and offline F0 | Lars Nieradzik | MIT |
| [aaatmy/beat-this-onnx](https://huggingface.co/aaatmy/beat-this-onnx) | Beats, downbeats and BPM (beat grid, metronome) | CPJKU (Foscarin, Schlüter, Widmer) | MIT |
| [aaatmy/kuromoji-ipadic-pack](https://huggingface.co/aaatmy/kuromoji-ipadic-pack) | Romanization of Japanese lyrics (downloaded only when a song has Japanese lyrics) | kuromoji.js (Takuya Asano), mecab-ipadic (NAIST) | Apache-2.0, IPADIC terms |
| [aaatmy/whisper-large-v3-onnx](https://huggingface.co/aaatmy/whisper-large-v3-onnx) | Lyrics recognition for songs without subtitles and timing of pasted lyrics (Whisper large-v3, optional, downloaded on first use) | OpenAI | Apache-2.0 |

The GAME, MDX-Net and SwiftF0 mirrors are verbatim copies of the official upstream files (not retrained, quantized or re-exported), with only a manifest and SHA-256 hashes added; the Whisper mirror is a verbatim copy of onnx-community's ONNX export of openai/whisper-large-v3 (including its int8 quantized build).
The GAME weights are licensed for non-commercial use only, so use of the app as a whole is subject to those terms.

## Scoring

When you finish singing, the recorded F0 curve is aligned and compared with the original vocals (GAME notes plus a SwiftF0 reference curve), producing six sub-scores:
**pitch** (Raw Chroma Accuracy), **rhythm** (rhythm-game style PERFECT / GREAT / GOOD / MISS per note, with windows scaled by BPM), **stability**,
**vibrato**, **expression** (correlation of energy curves) and **long tone**. Their weighted total is mapped to a 0–100 score with a rank from D to SSS: staying in tune and on the beat gets you around 80, good singing 85 or more, and an S (91+) takes steady pitch and rhythm throughout. The words are not recognised, so wrong lyrics or humming through a forgotten line cost nothing. When the scoring rules change, older takes are re-scored from their saved pitch so old and new scores compare directly.

The judgement pop-ups shown while singing and in the replay weigh timing and pitch together and carry FAST / LATE and HIGH / LOW tags; they are display only, and the score comes from the whole recording after the take.

Three key design points: **notes an octave apart count as the same note** (singing an octave higher or lower is still correct), **global transposition is allowed**
(a single semitone offset for the whole song, estimated automatically), and **slides in the original vocals and GAME transcription errors are tolerated**: each frame's
target includes both the original singer's F0 curve and the GAME note pitch, and matching either one counts as correct, so you can follow the original's slides or sing the notes straight.
For the full alignment method, metric definitions, formulas and calibration results, see [docs/SCORING.en.md](docs/SCORING.en.md).

## Installation and usage

Download the DMG or zip from the [Download](#download) section above and install it. On macOS, the first time you launch it, right-click the app and choose "Open" (it is not notarized); on Windows, choose "Run anyway" in SmartScreen.
The first launch downloads the models (about 500 MB) and external tools; on Windows you can also choose to download the CUDA runtime.
After adding a song (a YouTube link or a dropped file), wait for song preparation to finish, then press "Preview" to open the singing screen. You can listen to the original track or the accompaniment and view the piano roll first; put on headphones and press "Start recording" to begin scoring. The microphone button at the top right of the singing screen opens a panel that turns on the vocal return, which sends your voice to the output together with the music; the same panel switches a hall reverb on or off and sets its mix, and replays use it too. The star button next to it turns the live judgement pop-ups on or off (on by default). When a new version is out, a bubble appears on "About" at the bottom of the left rail. Recording, scoring and exported replay files always use the dry voice. If scoring did not finish, expand the song in the library and press "Score" next to the take to score it again.
For the full steps, data locations and FAQ, see [docs/INSTALL.md](docs/INSTALL.md) (Chinese).

## Building

```bash
# Engine (macOS, universal)
scripts/fetch_ort.sh
cmake -S engine -B engine/build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build engine/build -j

# App
cd app && flutter pub get && flutter run -d macos
```

In development mode, the app automatically looks for the engine in `engine/build/` and for ORT in `engine/third_party/onnxruntime/`.

## Reporting problems and contributing

The main way to test is to use the app live on stream. If something goes wrong, press "Report a problem" at the bottom of the app's navigation bar or open an [issue](https://github.com/Hikari-Tsai/karaoke-battle/issues). See [CONTRIBUTING.en.md](CONTRIBUTING.en.md) for what to include and how to contribute code.

## Acknowledgments

For full citation formats (including BibTeX) and each upstream project's requirements, see [docs/CITATIONS.md](docs/CITATIONS.md) (Chinese).

* **GAME 1.0 Small / Large** (melody transcription models) by **Team OpenVPI**,
  from [openvpi/GAME v1.0.3](https://github.com/openvpi/GAME/releases/tag/v1.0.3),
  licensed under [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/).
  Models released by yqzhishen; data labeling provided by 挚彬Club, YQ之神, 小狼 and 幽寂. This app uses the official ONNX files without modification; it is not endorsed by openvpi.
* **Kim_Vocal_2** (vocal separation) by **KimberleyJensen**, trained independently and distributed via UVR. The upstream has no license file; it is used under the author's
  [public permission statement](https://github.com/KimberleyJensen/kmdx-net_music-source-separation/issues/3) (2026-10-02).
* **UVR-MDX-NET-Inst_HQ_4** (accompaniment separation) by **Ultimate Vocal Remover** core developers **Anjok07 and aufr33** (MIT, credited per UVR's attribution requirements).
* The MDX-Net architecture and training code come from **kuielab** (Choi et al., *TFC-TDF-U-Net*, ISMIR 2020; Kim et al., *KUIELab-MDX-Net*, MDX Workshop @ ISMIR 2021).
  The engine's separation code is ported from [python-audio-separator](https://github.com/nomadkaraoke/python-audio-separator) (MIT).
* **SwiftF0** by Lars Nieradzik (*SwiftF0: Fast and Accurate Monophonic Pitch Detection*, arXiv:2508.18440, 2025).
* Scoring metric definitions are taken from **mir_eval** (Raffel et al., ISMIR 2014) and the melody extraction evaluation literature (Poliner et al. 2007; Salamon et al. 2014);
  real-time pitch tracking uses **MPM** (McLeod & Wyvill, ICMC 2005); alignment uses Sakoe-Chiba band DTW (1978).
* Key shifting uses [Signalsmith Stretch](https://github.com/Signalsmith-Audio/signalsmith-stretch), audio I/O uses miniaudio, and inference uses ONNX Runtime.
* Lyrics recognition uses **OpenAI Whisper** large-v3 (Radford et al., *Robust Speech Recognition via Large-Scale Weak Supervision*, ICML 2023), exported to ONNX by onnx-community.
* The lyrics typeface is [jf open huninn](https://github.com/justfont/open-huninn-font) by justfont (SIL OFL 1.1).
* The vocal reverb uses the [Cloud Seed](https://github.com/GhostNoteAudio/CloudSeedCore) algorithm by Ghost Note Audio (MIT). This project is not affiliated with Ghost Note Audio.

## Legal notice

The app's built-in use of yt-dlp to download audio and video is solely for the user's personal, local use. Downloading YouTube content may violate
YouTube's Terms of Service, and users do so at their own risk. The app does not upload or distribute any song data.

The data in the Hot songs tab comes from each operator's website (Holiday KTV, Cashbox Party, JOYSOUND, DAM) and the KKBOX charts; the data and trademarks belong to those companies, and this project is not affiliated with any of them. The data is read through the websites' own non-public endpoints and may stop working whenever they change.

## License

The code is licensed under MIT; see [LICENSE](LICENSE). For third-party components, see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
