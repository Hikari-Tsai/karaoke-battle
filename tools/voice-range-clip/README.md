# Voice range clip

Source of `docs/media/voice-range.gif` and `site/assets/voice-range.{mp4,jpg}`: a
drawn (not recorded) 16 s loop showing the range keyboard: the song's range
against the comfortable male and female ranges, a sung scale that measures your
own range, and "One-click key" moving the song into it. It is a
[HyperFrames](https://hyperframes.heygen.com) project; the scene is
`compositions/voicerange.html` (1920x1164, twice the 960x582 of the other clips).

Re-render after editing (needs Node.js 22+ and FFmpeg; run from this folder):

```bash
npx hyperframes check
npx hyperframes render --quality looks --output out/voice-range.mp4
ffmpeg -y -i out/voice-range.mp4 -vf "fps=12,scale=960:582:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" ../../docs/media/voice-range.gif
ffmpeg -y -i out/voice-range.mp4 -vf "scale=960:582:flags=lanczos" -an -c:v libx264 -pix_fmt yuv420p -crf 24 -preset slow -movflags +faststart ../../site/assets/voice-range.mp4
ffmpeg -y -ss 13.4 -i out/voice-range.mp4 -frames:v 1 -vf "scale=960:582:flags=lanczos" -q:v 3 ../../site/assets/voice-range.jpg
```

The text uses PingFang TC through `local()`, so render on macOS.
