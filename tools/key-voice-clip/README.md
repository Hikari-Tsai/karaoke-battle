# Key and voice clip

Source of `docs/media/key-voice.gif` and `site/assets/key-voice.{mp4,jpg}`: a drawn
(not recorded) 15 s loop showing the key shift, the vocal return and the hall
reverb mix. It is a [HyperFrames](https://hyperframes.heygen.com) project; the
scene is `compositions/keyvoice.html` (1920x1164, twice the 960x582 of the other
clips).

Re-render after editing (needs Node.js 22+ and FFmpeg; run from this folder):

```bash
npx hyperframes check
npx hyperframes render --quality looks --output out/key-voice.mp4
ffmpeg -y -i out/key-voice.mp4 -vf "fps=12,scale=960:582:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" ../../docs/media/key-voice.gif
ffmpeg -y -i out/key-voice.mp4 -vf "scale=960:582:flags=lanczos" -an -c:v libx264 -pix_fmt yuv420p -crf 24 -preset slow -movflags +faststart ../../site/assets/key-voice.mp4
ffmpeg -y -ss 12.9 -i out/key-voice.mp4 -frames:v 1 -vf "scale=960:582:flags=lanczos" -q:v 3 ../../site/assets/key-voice.jpg
```

The text uses PingFang TC through `local()`, so render on macOS.
