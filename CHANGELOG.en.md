# Changelog

[繁體中文](CHANGELOG.md) · [日本語](CHANGELOG.ja.md)

Each version lists what was added, improved and fixed. The app's new-version notice shows these notes too.

<!-- Keep the `## X.Y.Z — YYYY-MM-DD` headings: the app finds versions by them. -->

## Unreleased

### Added
- A master volume bar in replays: the speaker mutes, the slider goes up to +6 dB, and the level is remembered.
- "MIDI guide": besides the accompaniment and the original guide vocal, you can now pick the accompaniment with the melody played on a synth. It follows the notes on the roll, including your note edits and key changes, and its level is matched to the accompaniment.
- Latency can be set by hand: if calibration fails or seems off, use the slider in Settings (0–600 ms), or the −/+ buttons next to the latency on the sing screen to fine-tune while you sing (5 ms per press). Raise it when your pitch line shows up later than the notes, lower it when earlier; it applies at once and is saved.

### Improved
- Hot songs now reads the daily-updated KTV Charts site instead of every computer contacting the operators' websites: daily and monthly charts, more categories and a "VTuber covers" tab (each VTuber's cover video a click away); genre, BPM, release year and record label, and the chorus range drawn as a small bar, coloured by whether it suits your own measured range; a "Listen" menu, for songs a service carries, that opens them on Apple Music, Spotify or KKBOX in your browser. Machine numbers are no longer shown. The charts are kept on your computer, so the last copy shows when you are offline.
- A song whose preparation was cut off by closing the app (for example during vocal separation) now shows Retry and carries on where it stopped; before, it stayed stuck and could not be previewed.
- Japanese lyrics get romaji whatever their source: not only YouTube's Japanese subtitles but also Whisper recognition, imported subtitle files, pasted lyrics and lyrics edited by hand, whenever the text is Japanese, even on a song set to Chinese.
- Switching between the accompaniment and the guide vocal is instant: both are loaded when the song opens, so a switch is a 20 ms crossfade instead of a gap of about 2 s, and it works while recording too. Songs also open faster: resampling the audio is about 20 times quicker and runs in the background, so the screen no longer freezes while it loads.

### Fixed
- The Windows CUDA pack downloads again. Its download link broke when Microsoft took ONNX Runtime off GitHub (#7); it now comes from NuGet and PyPI and moves to CUDA 13: about 1.2 GB instead of 1.9 GB, but it needs a GTX 16 / RTX 20 series or newer GPU and driver 580.88 or newer. An already installed CUDA pack keeps working; downloading it again replaces it with the new one and deletes the old files.
- Updating yt-dlp no longer fails on GitHub's request limit (#4). It used to ask the GitHub API for the newest version, which allows 60 requests an hour per IP without a login, easily used up on shared connections such as mobile networks, dorms or offices. It now reads the newest version from the GitHub release page and still checks the official checksums. A yt-dlp that was just downloaded is no longer reported as "could not update" when only the check for a newer one fails.
- Latency calibration succeeds more often and measures more reliably (#5). It used to play five 2 ms clicks within the first second after the device started, which USB speakers, S/PDIF and amplifiers with auto-standby often swallowed, so it failed or even measured wrong. It now plays a soft tone first to wake the speakers, then six short chirps, each judged on its own: three heard are enough, and a distant microphone or a low volume still works. It takes about 3 s instead of 2. When it fails, the advice now also mentions the output device (S/PDIF and HDMI often have no speakers attached) and a muted microphone.
- A download whose security certificate cannot be verified (usually an antivirus HTTPS scan or a company or school network, #6) now asks first whether to skip the check. Only files with a fixed checksum (the CUDA pack, models, yt-dlp and so on) can skip it, and they are still checked after downloading: changed content is not installed. Once you agree, it does not ask again until the app is closed.
- The CUDA pack has a fallback source: when NuGet or PyPI fails, the same files come from this project's Hugging Face mirror (byte-identical, checked against the same checksums).

## 1.1.6 — 2026-11-17

### Added
- "AI singing tips" on the results screen: download or copy an analysis of the take and paste it into an AI assistant such as Claude Code or ChatGPT for singing advice. Or enter a Claude or OpenAI API key in Settings and press "Ask AI" to see the advice right in the app; without a key the app takes you to enter one first, then carries on. The analysis is sent to the AI service you chose only when you press "Ask AI".
- The new-version notice lists what changed.
- The sing screen now shows clearly whether you are practising or recording: a "Practice · not scored" or red "REC Recording · scored" badge next to the title, and a red frame around the window while recording. Start recording counts down 3, 2, 1 first (Esc or Cancel stops it).

## 1.1.5 — 2026-11-16

### Improved
- Better ghost-note removal: when the video has the uploader's own subtitles, notes outside every subtitle line are removed, and so are notes where the vocal stem is more than 15 dB below the median level (accompaniment leaking into the vocal). Either rule is skipped when it would remove too much.

## 1.1.4 — 2026-11-16

### Fixed
- "Report bug" failed with HTTP 500 when signed out of GitHub: the form URL now stays under 5000 characters, and a long error message is shortened first.

## 1.1.3 — 2026-11-16

### Added
- Error dialogs, error messages and failure screens have a "Report bug" button that fills in the version, OS, backend, graphics card, the error and the recent log.
- The app writes a log to `logs/app.log` in the data folder (home folders written as `~`). When the log does not fit in the form, it is saved as a file and selected in Finder / Explorer for dragging into the issue.

## 1.1.2 — 2026-11-16

### Improved
- "AI key" is now called "One-click key".

## 1.1.1 — 2026-11-15

### Improved
- The "Original" toggle is now called "Guide vocal".

## 1.1.0 — 2026-11-15

### Added
- Your own range: an orange bar on the range keyboard, and the key button can move a song into it.
- Settings shows your range, with detect again and reset; every song shares it.
- On first use, a range check follows the latency check (skippable).

## 1.0.1 — 2026-11-15

### Fixed
- Switching between accompaniment and original while recording made everything sung afterwards count as late: the toggle is now locked during a take, with a tooltip saying why.

## 1.0.0 — 2026-11-15

First public release.

### Added
- Paste a YouTube link or drop in a media file: vocal separation, transcription and reference pitch are done for you.
- Live pitch line and judgements while singing; afterwards a total score, a rank and six sub-scores (pitch, rhythm, stability, vibrato, dynamics, long notes).
- Lyrics from YouTube subtitles, pasted lyrics timed automatically, or generated with Whisper; romaji under Japanese lyrics.
- Key change, range keyboard and AI key; guide vocal / backing toggle, vocal return and reverb.
- Replays, video export, and replay import / export.
- KTV request charts and the KKBOX weekly charts.
- Latency calibration, noise gate, metronome, and settings saved per song.
- Chinese, English and Japanese UI; macOS (Universal) and Windows (CUDA, DirectML, CPU).
