# Privacy policy

[中文](PRIVACY.md) · [English](PRIVACY.en.md) · [日本語](PRIVACY.ja.md)

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
| The KTV Charts site (`hikari-tsai.github.io`, GitHub Pages) | When the charts page loads a ranking (it collects the Holiday, Cashbox, JOYSOUND, DAM and KKBOX charts) | Requests for the ranking only |
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
