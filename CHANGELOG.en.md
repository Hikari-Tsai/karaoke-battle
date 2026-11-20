# Changelog

[繁體中文](CHANGELOG.md) · [日本語](CHANGELOG.ja.md)

Each version lists what was added, improved and fixed. The app's new-version notice shows these notes too.

<!-- Keep the `## X.Y.Z — YYYY-MM-DD` headings: the app finds versions by them. -->

## Unreleased

### Added
- The Scoring rules page has "SSS demo songs": the result cards of the two SSS takes of 奇幻島 (Fantasy Island) on the website (夏語遙 99.2, 家家 98.7), laid out as there (total, the six sub-score bars, the onset judgements, AI feedback), with a count-up, bars filling in turn and a shining SSS badge when scrolled into view. "Download replay" downloads it and saves it to Import replays, with no file to find and import.
- Exported replays now carry the subtitles you added yourself (an imported subtitle file, pasted or typed lyrics, AI-generated subtitles; not the video's own YouTube subtitles). The first time the other person watches the replay they are added to their copy of the song, and become its main lyrics unless they have their own.
- In the lyrics editor, the line Enter stamps now follows the text caret: click into a line and Enter stamps that line; after stamping, the caret moves on to the next line, so you can type and stamp as you listen.
- Exporting a replay of a song imported from a local file now asks whether to pack the song in. "Include the song" comes with a copyright reminder, and the receiver can prepare the song straight from the included copy, perfectly in time; "Don't include the song" explains that they will need the same file themselves, or the voice will not line up if their version or its start differs.
- Songs from local files can have a cover image: "Set cover image…" in the song's ⋯ menu shows it as the library thumbnail and on the result and share cards; it can be changed or removed. When a replay is exported with "Include the song", the cover goes with it and the receiver's copy shows the same picture. A backing track you imported for the song goes with it too, and is applied to the receiver's copy once it is prepared (they can still go back to the separated one).
- A more dramatic score reveal after singing: the total spins up from 0 on slot-machine reels, slowing down until it clicks into place, the rank stamps down and the sub-score bars fill in one by one. Your previous best for the song is shown under the total and turns into "Record broken!" the moment the reels pass it. Beating your best now sets off a full-screen party (fireworks, confetti and a "NEW RECORD!" banner) with a cheering, clapping crowd, before the share card. Click or press any key to skip the spin, and click to skip the party; turn off "Results sound effects" in Settings for a silent reveal.
- A new "History" tab in the sidebar lists everything you have sung and been scored on, one entry per take, grouped by day with the newest first: the time, song, total, rank and sub-scores, and a click opens that take's full results. "Clear history" empties the list while keeping your recordings, the takes in the library and your best scores; tick "Also delete these recordings" to remove them from the library as well (this cannot be undone).
- Setlists for streams in History: "Today's setlist", or "Setlist text" next to any day, lists that day's songs in order, with clock times or as a stream timeline (set when the stream started to get timestamps you can paste into a YouTube comment), with or without scores, ready to copy or save as a text file. The app also keeps a setlist of each day under setlist/ in the data folder; today.txt is updated after every song, so an OBS Text source reading that file shows the songs you sang today on stream. Songs sung before 5 a.m. count as the day before, so a stream past midnight stays one day.
- The About page links to the early testers and contributors in the README, which (with the website) now also thanks 莓子熊 (Mecokuma) for suggesting the setlist, OBS integration and hiding songs, with updated notes for 皮卡, 羽之扉扉 and あはあは.
- "Export subtitles…" in a song's ⋯ menu saves one of its subtitle tracks (the main one by default) as SRT or LRC, with any offset set on the sing screen applied.
- The left panel of a result: a sub-score that does not count for the song (such as vibrato when the original has little) shows as a striped bar with a lock; the timing judgements are one bar split by count, with the number of note starts beside the title, and it fills in after the sub-score bars when the score is revealed. If you asked for "AI singing tips" on the take with an API key, their overall feedback and the number of tips sit at the bottom of the panel; click for all of them. Tips you ask for on the result page show up there straight away.
- Exporting a video asks for the player name, shown next to the song title in the video; it is the same name as in exported replays.
- The top of the sing history shows totals: takes, songs, time sung, days (with the date range), the average and the best score; click the best to open that result.
- "Replays" in the sidebar is now "Import replays".
- When a song's takes are expanded in the library, each one has a trash button that deletes that take's recording, pitch and score for good; deleting the best take warns first, and the next best counts instead.
- Each take in the sing history has a remove button, so one take can go without clearing everything. By default it only leaves the history and the setlists (including today.txt for streams), keeping the recording and its score, and the message offers Undo; tick "Also delete this recording" to delete its recording, pitch and score from the library for good.
- "Hide this song" in a song's ⋯ menu takes it off the library list. "Hidden (N)" appears at the top right, where songs can be shown again one by one or all at once. Hiding deletes nothing; the song's takes and best score stay.

### Improved
- Every dialog has an X in its top-left corner to close it; a click anywhere outside it or Esc closes it too, the same as Cancel (lyrics recognition or a video export in progress is stopped first). Only while Cancel itself is unavailable (scoring, moving the data folder) is the X greyed out and a click outside ignored.

### Fixed
- In the lyrics editor, typing with a Chinese (Zhuyin, Pinyin) or Japanese input method, Enter to pick a candidate or Space to convert triggered the "stamp" or "play / pause" shortcuts. The editor now checks whether the input method is composing: while it is, Enter, Space and Esc go to the input method (pick, convert, cancel); once the text is committed the shortcuts work as usual, without leaving the field. Ctrl / Cmd / Alt with Space or Enter no longer trigger shortcuts either (such as Ctrl+Space to switch input methods); Shift+Space types a space. In a text field the left / right arrows now move the caret; they skip back / forward only outside the fields.
- After importing a backing track, takes that had been replayed before still played the old separated accompaniment. A replay now remembers which backing file it was mixed from and is mixed again when the backing changes (or goes back to the separated one).
- When Play and Start recording on the sing screen "do nothing", the screen now says why (#8). Playback and recording share one audio device that the microphone drives; when the microphone delivers no sound (taken by another program, a stuck USB device), the whole device stops. After 2 s without any activity a red notice at the top explains what to do, and the log records it. The calibration timeout advice now points at the microphone first.
- An error message at the bottom of the window (with its "Report bug" button) was meant to go away after 8 s but stayed until closed by hand. It now goes away on its own.

## 1.1.9 — 2026-11-20

### Added
- Import backing track: "Import backing track…" in a song's ⋯ menu swaps the separated accompaniment for an official instrumental or a karaoke track. It is aligned automatically, with the result and a confidence; a speed difference, a possibly different version, a key change or bass out of step with the other instruments is pointed out. Nudge it by dragging the two waveforms or with ±1/10/100 ms buttons, and check by ear with "vocals + backing" and "song − backing". Once applied it plays when singing, under the MIDI guide and in replays, and you can go back to the separated accompaniment at any time.
- A "Widen the key range to ±12" switch in Settings: the key still moves ±6 by default; with it on, up to ±12 (a full octave), and the one-tap key change searches that far too.
- Download melody MIDI: "Download melody MIDI" in a song's ⋯ menu saves the melody the MIDI guide plays (with your note edits) as a Standard MIDI File. Its tempo map follows the detected or manually set beats, bars start on the downbeats and the lyrics are included, so it lines up with the song in a DAW.

### Improved
- Hot songs layout: the artist, release year and label now sit under the title, and the old artist column shows coloured tags (genre, BPM, mood, instruments, vocals, each in its own colour).
- Replays always play the accompaniment, even if you switched to the guide vocal or MIDI guide while singing. When you switched between accompaniment, guide vocal and MIDI guide during a take is now saved with it (and travels in shared replays), so a replay can reproduce it one day.

### Fixed
- macOS: in 1.1.8 file dialogs did not open (importing subtitles, adding a local file or importing a replay failed). The build re-signed the app without its entitlements; it now keeps them.

## 1.1.8 — 2026-11-18

### Fixed
- "Move data" to another folder failed on Windows ("Deletion failed … being used by another process"), and could leave the old folder partly deleted while the app still pointed at it. The app itself still had its log open or the CUDA pack loaded, which Windows does not allow to be deleted. The log is now closed before moving; once the copy is complete the app points at the new folder before the old one is removed, and files that cannot be deleted yet are removed at the next start instead of causing an error.

## 1.1.7 — 2026-11-18

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
