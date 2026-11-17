# Replay clip

Source of `docs/media/replay.gif` and `site/assets/replay.{mp4,jpg}`: a drawn
(not recorded) 16 s loop showing the replay screen: judgement pop-ups on the
playhead, the FAST / LATE and HIGH / LOW tags next to a sung pitch line that is
late, flat, or early and sharp, a missed note, then the Hall reverb switch and the
MIX slider. It is a [HyperFrames](https://hyperframes.heygen.com) project; the
scene is `compositions/replay.html` (1920x1164, twice the 960x582 of the other
clips). The notes, the lyric lines and the score are made up for the clip.

Re-render after editing (needs Node.js 22+ and FFmpeg; run from this folder):

```bash
npx hyperframes check
npx hyperframes render --quality looks --output out/replay.mp4
ffmpeg -y -i out/replay.mp4 -vf "fps=12,scale=960:582:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" ../../docs/media/replay.gif
ffmpeg -y -i out/replay.mp4 -vf "scale=960:582:flags=lanczos" -an -c:v libx264 -pix_fmt yuv420p -crf 24 -preset slow -movflags +faststart ../../site/assets/replay.mp4
ffmpeg -y -ss 7.2 -i out/replay.mp4 -frames:v 1 -vf "scale=960:582:flags=lanczos" -q:v 3 ../../site/assets/replay.jpg
```

The text uses PingFang TC and Arial Black through `local()`, so render on macOS.

In `compositions/replay.html` a note at `left: x` crosses the playhead at
`0.3 + (x - 500) / 200` seconds; that is the time of its entry in `JUDGE`, so move
both together.
