# Code signing policy

[中文](CODE_SIGNING.md) · [English](CODE_SIGNING.en.md) · [日本語](CODE_SIGNING.ja.md)

Free code signing provided by [SignPath.io](https://about.signpath.io/), certificate by [SignPath Foundation](https://signpath.org/)

> Status: the project has applied to SignPath Foundation. Until the application is approved, Windows builds are
> unsigned and SmartScreen shows "Windows protected your PC" when you open them.

## What is signed

* Only files built from the source code in this repository by GitHub Actions
  ([`.github/workflows/build.yml`](../.github/workflows/build.yml)): `karaoke_battle.exe` and `karaoke_engine.dll`.
* Upstream files shipped in the same zip (the Flutter, ONNX Runtime, DirectML and media_kit DLLs) are not signed with
  this project's certificate; they keep their upstream signatures, if any.
* Every release is signed only after an approver below approves the signing request in SignPath.
* The macOS build is not covered by this policy (macOS uses Apple's signing and notarization).

## Team roles

| Role | Members |
| --- | --- |
| Committers and reviewers | [Hikari-Tsai](https://github.com/Hikari-Tsai) |
| Approvers | [Hikari-Tsai](https://github.com/Hikari-Tsai) (repository owner) |

Pull requests from outside contributors are reviewed before they are merged, including changes to build scripts and
CI configuration. All team members use multi-factor authentication on GitHub and SignPath.

## Privacy policy

Karaoke Battle has no accounts, no telemetry and no usage analytics, and it never uploads your recordings, songs or
takes. They stay on your computer (see [data locations](INSTALL.md#資料位置) in the install guide).

The app connects to the network only for the purposes below. These are ordinary HTTPS requests; the servers see your
IP address and the app name.

| Service | When | What is sent |
| --- | --- | --- |
| GitHub (`api.github.com`, `raw.githubusercontent.com`, `github.com`) | At every launch to check for a new version and read the list of external tools; when downloading yt-dlp, Deno and ffmpeg | Download requests only |
| ffmpeg download sites (`ffmpeg.martin-riedl.de`, `evermeet.cx`) | When the system has no ffmpeg and the app downloads it | Download requests only |
| Hugging Face (`huggingface.co`) | When you download the models | Download requests only |
| PyPI (`files.pythonhosted.org`) | When you choose to download the CUDA runtime on Windows | Download requests only |
| YouTube and other video sites (through yt-dlp) | When you paste a link to add a song | The link you pasted |
| KTV and streaming chart sites (Holiday, Cashbox, JOYSOUND, DAM, KKBOX) | When the charts page loads a ranking | Requests for the ranking only |
| Anthropic or OpenAI | Only when you enter your own API key and ask for AI singing advice | A text summary of the take's analysis (no audio; the song title can be hidden) and your API key |

"Report a problem" only opens the GitHub issue form in your browser; you review it and submit it yourself.

Each of these services has its own privacy policy:
[GitHub](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement),
[Hugging Face](https://huggingface.co/privacy),
[Anthropic](https://www.anthropic.com/legal/privacy),
[OpenAI](https://openai.com/policies/privacy-policy),
[YouTube / Google](https://policies.google.com/privacy).

## Uninstalling

See [Uninstall](INSTALL.md#解除安裝) in the install guide.
