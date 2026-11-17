# Changelog

[繁體中文](CHANGELOG.md) · [日本語](CHANGELOG.ja.md)

Each version lists what was added, improved and fixed. The app's new-version notice shows these notes too.

<!-- Keep the `## X.Y.Z — YYYY-MM-DD` headings: the app finds versions by them. -->

## Unreleased

### Added
- "AI singing tips" on the results screen: download or copy an analysis of the take and paste it into an AI assistant such as Claude Code or ChatGPT for singing advice. Or enter a Claude or OpenAI API key in Settings and press "Ask AI" to see the advice right in the app; without a key the app takes you to enter one first, then carries on. The analysis is sent to the AI service you chose only when you press "Ask AI".
- The new-version notice lists what changed.

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
