#!/usr/bin/env python3
"""Renders the Karaoke Battle app icon with Pillow (no external assets).

    uv run --python 3.12 --with pillow python -I scripts/make_icon.py

Writes:
  app/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{16..1024}.png
  app/windows/runner/resources/app_icon.ico
  docs/icon.png (512 px, used by README)

Design: dark violet-to-magenta rounded square, a white microphone on the left,
four piano-roll note bars (the app's live-pitch colours) with a pitch curve on
the right.
"""
from __future__ import annotations

import math
import pathlib

from PIL import Image, ImageDraw, ImageFilter

ROOT = pathlib.Path(__file__).resolve().parent.parent
SS = 4  # supersampling factor
N = 1024 * SS


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient(size, top, bottom):
    img = Image.new("RGB", (size, size))
    d = ImageDraw.Draw(img)
    for y in range(size):
        d.line([(0, y), (size, y)], fill=lerp(top, bottom, y / (size - 1)))
    return img


def rounded_mask(size, radius):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m


def render_master() -> Image.Image:
    # --- background --------------------------------------------------------
    bg = gradient(N, (46, 24, 92), (168, 40, 110))  # deep violet -> magenta
    # soft radial glow top-left
    glow = Image.new("L", (N, N), 0)
    ImageDraw.Draw(glow).ellipse([-N * 0.2, -N * 0.25, N * 0.75, N * 0.65], fill=120)
    glow = glow.filter(ImageFilter.GaussianBlur(N * 0.12))
    bg = Image.composite(Image.new("RGB", (N, N), (120, 70, 190)), bg, glow)

    # macOS-style squircle-ish rounded square (22.5 % radius)
    mask = rounded_mask(N, int(N * 0.225))
    icon = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    icon.paste(bg, (0, 0), mask)

    layer = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    u = N / 1024.0  # 1 "design pixel"

    # --- pitch curve + piano-roll note bars (right side) ------------------------
    def curve(x):  # design px -> design px
        return 440 - 45 * math.sin((x - 500) / 90.0) - 70 * math.sin((x - 500) / 260.0)

    colours = [(76, 175, 80, 255), (255, 235, 59, 255), (76, 175, 80, 255), (244, 67, 54, 255)]
    bars = [(505, 655), (680, 800), (820, 905), (925, 990)]  # x ranges, centred on the curve
    h = 84 * u
    for (x0, x1), col in zip(bars, colours):
        y = curve((x0 + x1) / 2) * u
        d.rounded_rectangle([x0 * u, y - h / 2, x1 * u, y + h / 2], radius=h / 2, fill=col)
    # curve as one filled band (offset polygon) so there are no segment joints
    xs = list(range(500, 991, 2))
    half = 9.0
    upper, lower = [], []
    for x in xs:
        dy = (curve(x + 1) - curve(x - 1)) / 2.0
        nx, ny = -dy, 1.0
        norm = math.hypot(nx, ny)
        nx, ny = nx / norm * half, ny / norm * half
        upper.append(((x + nx) * u, (curve(x) + ny) * u))
        lower.append(((x - nx) * u, (curve(x) - ny) * u))
    cl = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    cd = ImageDraw.Draw(cl)
    cd.polygon(upper + lower[::-1], fill=(255, 255, 255, 255))
    for x in (xs[0], xs[-1]):
        y = curve(x)
        cd.ellipse([(x - half) * u, (y - half) * u, (x + half) * u, (y + half) * u], fill=(255, 255, 255, 255))
    cl.putalpha(cl.split()[3].point(lambda a: int(a * 0.95)))
    layer.alpha_composite(cl)

    # --- microphone (left side) ---------------------------------------------
    white = (255, 255, 255, 255)
    cx = 330 * u
    # capsule
    cap_w, cap_top, cap_bot = 190 * u, 150 * u, 470 * u
    d.rounded_rectangle([cx - cap_w / 2, cap_top, cx + cap_w / 2, cap_bot], radius=cap_w / 2, fill=white)
    # grille lines (cut from the capsule)
    for i in range(5):
        yy = cap_top + (90 + i * 60) * u
        d.line([(cx - cap_w / 2 + 28 * u, yy), (cx + cap_w / 2 - 28 * u, yy)], fill=(0, 0, 0, 0), width=int(14 * u))
    # cradle arc
    arc_r = 160 * u
    arc_box = [cx - arc_r, cap_bot - arc_r * 1.35, cx + arc_r, cap_bot + arc_r * 0.65]
    d.arc(arc_box, start=20, end=160, fill=white, width=int(34 * u))
    # stem + base
    d.rounded_rectangle([cx - 17 * u, cap_bot + 100 * u, cx + 17 * u, 800 * u], radius=17 * u, fill=white)
    d.rounded_rectangle([cx - 120 * u, 790 * u, cx + 120 * u, 840 * u], radius=25 * u, fill=white)

    # drop shadow for the foreground
    shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    alpha = layer.split()[3].filter(ImageFilter.GaussianBlur(N * 0.012))
    shadow.putalpha(alpha.point(lambda a: int(a * 0.45)))
    shadow = Image.alpha_composite(Image.new("RGBA", (N, N), (0, 0, 0, 0)), shadow)
    shadow = Image.new("RGBA", (N, N), (20, 0, 40, 0))
    shadow.putalpha(alpha.point(lambda a: int(a * 0.5)))
    off = int(10 * u)
    icon.alpha_composite(shadow, (off, off))
    icon.alpha_composite(layer)
    # keep everything inside the rounded square
    icon.putalpha(Image.composite(icon.split()[3], Image.new("L", (N, N), 0), mask))
    return icon


def main():
    master = render_master()
    master1024 = master.resize((1024, 1024), Image.LANCZOS)

    appiconset = ROOT / "app/macos/Runner/Assets.xcassets/AppIcon.appiconset"
    for s in (16, 32, 64, 128, 256, 512, 1024):
        master1024.resize((s, s), Image.LANCZOS).save(appiconset / f"app_icon_{s}.png")

    ico_sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
    ico_path = ROOT / "app/windows/runner/resources/app_icon.ico"
    master1024.resize((256, 256), Image.LANCZOS).save(ico_path, format="ICO", sizes=ico_sizes)

    docs = ROOT / "docs"
    docs.mkdir(exist_ok=True)
    master1024.resize((512, 512), Image.LANCZOS).save(docs / "icon.png")
    print("icon written:", appiconset, ico_path, docs / "icon.png")


if __name__ == "__main__":
    main()
