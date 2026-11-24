# Changelog

[繁體中文](CHANGELOG.md) · [日本語](CHANGELOG.ja.md)

Each version lists what was added, improved and fixed. The app's new-version notice shows these notes too.

<!-- Keep the `## X.Y.Z — YYYY-MM-DD` headings: the app finds versions by them. -->

## Unreleased

### Added
- The Profile shows "Identity and devices": a user ID and every computer it has been used on (a hash of the machine ID, with that computer's OS version at its last start in brackets, read again at every start). The user ID is kept in the data folder and moves with it, so a new computer is added under the same ID; computers are told apart by the hash, the machine ID itself is never stored, and nothing leaves the computer.
- Achievements: at the bottom of the Profile, 63 in eight groups (getting started, totals, skill, ranks, progress, explore, live and secret). Getting started is 17 one-time tasks that walk through the basics (add a first song, preview, record, open a results card and a replay, calibrate the latency, measure your range, set your name, lyrics, make your own lyrics, import your own backing track, change the key, delete a note in edit mode, sing a whole song, open Hot songs, watch an SSS demo), with "Graduate" once all are done; Ranks counts the first D, C, B, A, S, SS and SSS each (the bad ones too: a D is "Everyone starts somewhere"), each medal showing its rank in its colour, with "Seen it all" once you have had all seven; the others are mostly in bronze, silver and gold, such as 10 / 100 / 500 takes, singing 3 / 7 / 30 days in a row, an SSS, SSS on 3 / 10 / 20 songs, a full score in each of the six sub-scores (pitch, rhythm, stability, vibrato, expression, long tones), a take without a MISS, new personal bests, songs in 2 / 3 / 5 languages (from the hot songs charts' language charts, then the language YouTube gives, then the one chosen when adding the song; Taiwanese counts as its own) and 3 / 5 / 7 genres, 1 / 10 / 30 hot songs, 5 / 20 / 50 artists (the hot songs charts' artist, else for a YouTube song the video's music info or the channel), 2 / 3 / 5 decades (by release year from the hot songs charts or YouTube, never the upload date), 1 / 10 / 30 imported replays, 5 / 20 / 50 shares in all, a first exported video or replay, a GitHub star (the app cannot check it, so opening the page from "Star on GitHub" in the sidebar counts; 50 points, as thanks), singing live (a scored take with OBS, Streamlabs or XSplit running counts, told from the process names on this computer only: a first stream, 10 / 100 / 500 songs on stream, and streams on 3 / 10 / 30 days), and beating 1 / 5 / 20 imported replays on their songs; secret ones show "???" until found (such as singing after midnight, an S with the day's first song, or a note 3 keys above or below your measured range) and are worth double for their difficulty. Where how a rule is judged needs saying, a circled i next to the name explains it on hover (a day starting at 5 a.m., Time machine counting only songs on the hot songs charts, how singing live is told). Tiers reached show as bronze, silver and gold badges (a check badge for single goals), and the dots under a tiered card can be clicked to see each tier's goal, its date or the progress to it, clicking again going back to the next one to reach. The cards come in one after another: the medals pop up, the bars and counts run up to where they stand, unlocked medals catch the light now and then, and a card lifts under the pointer. At the top, an "Achievement stats" card in the style of the Library overview shows the goals unlocked and how far along, the points (and the most there are), the gold, silver and bronze medals of the tiered goals, and the latest unlock with its date; the numbers count up from 0 as the bars fill. Only scored takes count, and an achievement once reached is kept for good (deleting recordings does not take it back); they are stored in the data folder and move with it. Each tier earns points by how hard it is, on five steps of 5, 10, 25, 50 and 100: beginner tasks 5 (110 for all of them with Graduate), a click 10, skill from 25 (S 25, SS 50, SSS 100; a first D 10, C and B 5, A 10), and the gold tiers that take months (500 takes, 50 hours, 30 days in a row and so on) 100, the secrets 25 to 100; points are kept for later. Each unlock plays a full-screen celebration: the screen dims, the medal spins in over turning rays, a shock ring and a burst of confetti, then its name, what it asked for and the points come in, and several unlocked together share one screen. It never interrupts singing or the score reveal, waiting until the song, the score and any new record are done; a click or Esc closes it, and it closes by itself after a few seconds; the first start catches up on past takes with one summary.
- A "Profile" at the very top of the sidebar, above the Library: a chibi, anime-style cartoon singer (big head on a short neck, big sparkly eyes, hatched blush) that bobs to the beat, sings, blinks and sends notes floating up, with a sticker of your best rank so far on it (such as SSS, shining from S up), as a woman, a man, a neutral person or one of four small animals (cat, dog, rabbit, bear); your name in large type with a pen to edit it, which exported videos and replays use (the export dialogs no longer ask for a player name); and the library overview (songs, ready to sing, songs sung, takes, time sung, best score). The sidebar button is the singer's face.
- An MV switch at the top right of the sing screen, while previewing and recording: the camera icon hides or shows the music video behind the roll, which then takes the whole stage; the choice is remembered, and Settings has a "Show the music video" switch for it too. Songs without a video do not show the button. Thanks to 莓子熊 (Mecokuma) for the idea.

### Improved
- Settings → Audio devices has an "Automatic volume target": the loudness the sing screen's automatic volume brings each song's backing to, -16 LUFS by default, adjustable from -24 to -8 LUFS in steps of 0.5. Songs whose volume you have not moved follow it; ones set by hand stay as set.
- "Report a problem" now fills in the audio devices in use on the GitHub form: the input (microphone) and output (marked when it is the system default), with the sample rate and latency; a device name you would rather not show can be edited before submitting.
- Songs added from YouTube get their artist, release year and language from the video's music info (the channel when there is no artist), and the Library shows the artist under the title; songs added before are filled in in the background after the app starts, once each.
- Settings → Data folder has "Move to another computer…": step-by-step help for taking songs, takes, the history, imported replays and achievements to a new computer, with the default locations on macOS and Windows, which settings to set up again, and what to watch for between Mac and Windows.
- Hot songs has "Measure your range" at the top right ("Measure your range again" once measured), the same steps as in Settings; once saved, every chorus range is recoloured for it. Genre tags are shown in the UI language too, e.g. 華語流行 and 抒情 in Chinese, マンドポップ and バラード in Japanese; genres without a common name stay in English, and the tooltip gives the original.
- In Hot songs the BPM is a column of its own (between the tags and the chorus range) instead of a tag, so songs' tempos compare at a glance. The six sub-score bars of the website's SSS demos and "How the score works", and of the demo cards on the app's Scoring rules page, use the same colours as the app's results card.

### Fixed
- After moving the data folder, or to another computer, "Reprocess" failed for songs added from files because their original could not be found (and YouTube songs downloaded the video again): a song kept the full path to its original. When that path is gone, the same file in the song's folder is now used.


## 1.2.0 — 2026-11-21

### Added
- The results' "Note analysis" table has a "Lyric" column: the lyrics are matched to the notes by time, a character per note in Chinese, Japanese and Korean and a word per note otherwise, with "～" on a note that holds the previous syllable. Lyrics are timed by line only, so a syllable or two may be off; the table says so.
- The Scoring rules page has "SSS demo songs": the result cards of the two SSS takes of 奇幻島 (Fantasy Island) on the website (夏語遙 99.2, 家家 98.7), laid out as there (total, the six sub-score bars, the onset judgements, AI feedback), with a count-up, bars filling in turn and a shining SSS badge when scrolled into view. "Download replay" downloads it and saves it to Import replays, with no file to find and import.
- Exported replays now carry the subtitles you added yourself (an imported subtitle file, pasted or typed lyrics, AI-generated subtitles; not the video's own YouTube subtitles). The first time the other person watches the replay they are added to their copy of the song, and become its main lyrics unless they have their own.
- In the lyrics editor, the line Enter stamps now follows the text caret: click into a line and Enter stamps that line; after stamping, the caret moves on to the next line, so you can type and stamp as you listen.
- Exporting a replay of a song imported from a local file now asks whether to pack the song in. "Include the song" comes with a copyright reminder, and the receiver can prepare the song straight from the included copy, perfectly in time; "Don't include the song" explains that they will need the same file themselves, or the voice will not line up if their version or its start differs.
- Songs from local files can have a cover image: "Set cover image…" in the song's ⋯ menu shows it as the library thumbnail and on the result and share cards; it can be changed or removed. When a replay is exported with "Include the song", the cover goes with it and the receiver's copy shows the same picture. A backing track you imported for the song goes with it too, and is applied to the receiver's copy once it is prepared (they can still go back to the separated one).
- A more dramatic score reveal after singing: the total spins up from 0 on slot-machine reels, slowing down until it clicks into place, the rank stamps down and the sub-score bars fill in one by one. Your previous best for the song is shown under the total and turns into "Record broken!" the moment the reels pass it. Beating your best now sets off a full-screen party (fireworks, confetti and a "NEW RECORD!" banner) with a cheering, clapping crowd, before the share card. Click or press any key to skip the spin, and click to skip the party; turn off "Results sound effects" in Settings for a silent reveal.
- A new "History" tab in the sidebar lists everything you have sung and been scored on, one entry per take, grouped by day with the newest first: the time, song, total, rank and sub-scores, and a click opens that take's full results. "Count from now" starts the stats and the list again from this moment without deleting anything; the date at the top right of the stats card sets where they count from: a day and time of your choice, now, or all takes.
- Setlists for streams in History: "OBS setlist" lists the songs of the History's current range (from the start date at the top right of the stats card) in order, with dates when it spans several days, and "Setlist text" next to a day lists just that day, with clock times or as a stream timeline (set when the stream started to get timestamps you can paste into a YouTube comment), with or without scores, ready to copy or save as a text file. The app also keeps a setlist of each day under setlist/ in the data folder; today.txt holds the same as "OBS setlist" and is updated after every song and whenever the start date changes, so an OBS Text source reading that file shows those songs on stream. Songs sung before 5 a.m. count as the day before, so a stream past midnight stays one day.
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
- The Library has the History page's look: a "Library overview" card at the top (songs, ready to sing, songs sung, takes, time sung and the best score, counting up), the song cards centred with room on both sides, each with its best rank's colour down the left edge, lighting up with a slight thumbnail zoom under the pointer, and a glowing best score from S up; the Import replays list has the same cards (without the stats). The six sub-score bars on the results card, and on the imported replay and share cards, use the same colours as the Scoring rules (pitch violet, rhythm pink, stability blue, vibrato green, expression orange, long notes yellow).
- The Scoring rules page is redesigned: a banner with a floating, shining SSS, the seven ranks popping in one by one, the six sub-scores' weights as one coloured bar that grows in and a card with an icon for each; what is not penalised and the tips are cards too, and every section fades in as it scrolls into view. The SSS demo songs have a play button on the cover that shows the demo video in a dialog. The History stats are a gradient card whose numbers count up, tile by tile, with the best score framed in gold; the list below has room on both sides, each day's heading shows how many takes it had, and each row has its rank's colour down the left edge and lights up under the pointer. In a short window the left sidebar scrolls instead of pushing the bottom buttons out of view.
- Rank tags S and above (S, SS, SSS) shine: a softly pulsing glow and a band of light sweeping across now and then, brighter and more often the higher the rank; SSS is now a gold gradient, and large tags sparkle. This is everywhere they appear: the library, history, imported replays, the scoring rules and the share card (a saved image or exported video never catches the light half way). The results card gets the same light as the SSS demo songs: once the total lands it glows in the rank's colour, and light runs along the sub-score bars one after another.
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
