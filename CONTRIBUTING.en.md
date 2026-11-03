# Contributing to Karaoke Battle

[中文](CONTRIBUTING.md) · **English** · [日本語](CONTRIBUTING.ja.md)

Thank you for helping! Karaoke Battle is a singing-score app made for streamers, so the main way to test it is simple: **use it live on your stream, and report anything that goes wrong in [Issues](https://github.com/Hikari-Tsai/karaoke-battle/issues)**.

## Testing on stream

1. Download the latest version from [Releases](https://github.com/Hikari-Tsai/karaoke-battle/releases/latest); see the [install guide](docs/INSTALL.md).
2. Use it the way you normally stream: add songs, preview, record, check results and replays, export replays, make share images, capture the window in OBS.
3. No test script needed. Anything that feels off on stream is worth reporting, for example:
   * song preparation fails or hangs, or the app crashes or stops responding;
   * the score, judgement pop-ups or pitch line clearly disagree with what you heard;
   * pop-ups, lyrics or the backing track are out of sync with the screen;
   * something is hard to read at stream quality, or viewers can't follow it;
   * anything awkward to use while you are live.
4. If the stream is recorded (VOD), note the time it happened; a link with the timestamp helps the most.

## Reporting a problem

The app has two ways in. Both open the GitHub report form with the version, operating system and compute backend already filled in:

* **Report a problem** at the bottom of the navigation bar on the left;
* the **Report a problem** button on the **About** page.

You can also go straight to [New issue](https://github.com/Hikari-Tsai/karaoke-battle/issues/new/choose). Reporting needs a GitHub account.

Please include as much as you can:

| Item | What to write |
| --- | --- |
| Version and setup | Filled in when you open the form from the app; otherwise the version on the About page, your OS and CPU / CUDA / DirectML |
| What happened | What you did, what you expected and what you saw |
| Steps | Steps to reproduce if you can; please report it even if it happened only once |
| Song | The YouTube link, or the kind of local file (mp3, mp4…) |
| Screen | Screenshots, a clip, or a VOD link with the timestamp |
| Replay file (optional) | If a score looks wrong, the exported replay zip of that take |

Please note:

* Issues are **public**. A replay zip contains your singing, so attach it only if you are happy to; never post accounts, passwords or other personal details.
* Search first: if someone already reported the same problem, add your case to that issue.
* One problem per issue makes it easier to track.

## Feature requests

Ideas are welcome as issues too. Describe what you want to do on stream and what stops you today.

## Contributing code

* See [docs/BUILD.md](docs/BUILD.md) to build, [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the architecture and [docs/SCORING.en.md](docs/SCORING.en.md) for the scoring algorithm.
* Before opening a pull request, run `flutter analyze` and `flutter test` in `app/`; if you change the engine, make sure it builds on both macOS and Windows.
* If you change how scoring works, update all three `docs/SCORING*.md`; if you change UI text, add all three languages in `app/lib/state/i18n.dart`.
* Don't add model files or third-party binaries to the repo. Check the license before adding a model; see [docs/CITATIONS.md](docs/CITATIONS.md) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
* Contributions are released under the project's [MIT license](LICENSE).
