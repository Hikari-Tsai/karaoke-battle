# Lyrics clip

Source of `docs/media/lyrics.gif` and `site/assets/lyrics.{mp4,jpg}`: a drawn
(not recorded) 16 s loop showing where lyrics can come from: the lyrics button
lists the four sources for a song without subtitles, the whole lyrics are pasted
and timed from the notes, and they colour in word by word during playback. It is a
[HyperFrames](https://hyperframes.heygen.com) project; the scene is
`compositions/lyrics.html` (1920x1164, twice the 960x582 of the other clips). The
lyric lines are made up for the clip.

Re-render after editing (needs Node.js 22+ and FFmpeg; run from this folder):

```bash
npx hyperframes check
npx hyperframes render --quality looks --output out/lyrics.mp4
ffmpeg -y -i out/lyrics.mp4 -vf "fps=12,scale=960:582:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" ../../docs/media/lyrics.gif
ffmpeg -y -i out/lyrics.mp4 -vf "scale=960:582:flags=lanczos" -an -c:v libx264 -pix_fmt yuv420p -crf 24 -preset slow -movflags +faststart ../../site/assets/lyrics.mp4
ffmpeg -y -ss 3.6 -i out/lyrics.mp4 -frames:v 1 -vf "scale=960:582:flags=lanczos" -q:v 3 ../../site/assets/lyrics.jpg
```

The text uses PingFang TC through `local()`, so render on macOS.
