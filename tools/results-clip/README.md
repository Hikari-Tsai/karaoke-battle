# Results clip

Source of `docs/media/results.gif` and `site/assets/results.{mp4,jpg}`: a drawn
(not recorded) 16 s loop showing the score counting up, the share card and the
exported performance video. It is a [HyperFrames](https://hyperframes.heygen.com)
project; the scene is `compositions/results.html` (1920x1164, twice the 960x582 of
the other clips).

Re-render after editing (needs Node.js 22+ and FFmpeg; run from this folder):

```bash
npx hyperframes check
npx hyperframes render --quality looks --output out/results.mp4
ffmpeg -y -i out/results.mp4 -vf "fps=12,scale=960:582:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" ../../docs/media/results.gif
ffmpeg -y -i out/results.mp4 -vf "scale=960:582:flags=lanczos" -an -c:v libx264 -pix_fmt yuv420p -crf 24 -preset slow -movflags +faststart ../../site/assets/results.mp4
ffmpeg -y -ss 7.9 -i out/results.mp4 -frames:v 1 -vf "scale=960:582:flags=lanczos" -q:v 3 ../../site/assets/results.jpg
```

The text uses PingFang TC through `local()`, so render on macOS.
