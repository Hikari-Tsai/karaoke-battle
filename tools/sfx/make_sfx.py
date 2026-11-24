#!/usr/bin/env python3
"""Synthesizes the results-screen sound effects into app/assets/sfx/.

Everything is generated from noise and oscillators, so the sounds carry no
third-party license. Re-run after tweaking:

    python3 tools/sfx/make_sfx.py

Needs numpy, scipy and ffmpeg (for the mp3 encode).

  roll.mp3         slot-machine reel ticks, fast then slowing, timed to the
                   score counter (ROLL_SECONDS, ROLL_EASE)
  ding.mp3         the reels locking in: a thunk and a bell
  ding_s.mp3       the same for an S or better: a bright chord and sparkles
  celebrate.mp3    new personal best: fanfare stab, cheering crowd, applause
                   and whistles
  achievement.mp3  an achievement unlocked: a marimba run up to a ringing chord
  item.mp3         an item redeemed: a harp sweep up to a chime
  daily.mp3        the daily top-up: two music-box notes and a twinkle
  wand.mp3         the Tuning Wand used: a swish up and sparkles, then a ting
  field.mp3        the Resonance Field cast: a low swell opening into a shimmer
"""
import os
import subprocess
import sys
import tempfile
import wave

import numpy as np
from scipy import signal

SR = 44100
ROLL_SECONDS = 3.2  # keep in step with kRevealRoll in score_reveal.dart
OUT = os.path.join(os.path.dirname(__file__), '..', '..', 'app', 'assets', 'sfx')
rng = np.random.default_rng(7)


def t_axis(seconds):
    return np.arange(int(seconds * SR)) / SR


def bandpass(x, lo, hi, order=2):
    sos = signal.butter(order, [lo, hi], btype='band', fs=SR, output='sos')
    return signal.sosfilt(sos, x)


def lowpass(x, hz, order=2):
    return signal.sosfilt(signal.butter(order, hz, fs=SR, output='sos'), x)


def resonator(x, freq, bw):
    """Two-pole formant filter."""
    r = np.exp(-np.pi * bw / SR)
    c = 2 * r * np.cos(2 * np.pi * freq / SR)
    return signal.lfilter([1 - r], [1, -c, r * r], x)


def place(buf, clip, at):
    i = int(at * SR)
    if i >= len(buf):
        return
    n = min(len(clip), len(buf) - i)
    buf[i:i + n] += clip[:n]


ROLL_EASE = 2.2  # keep in step with kRevealEase in score_reveal.dart


def ease_out(u):
    return 1 - (1 - u) ** ROLL_EASE


# ---------------------------------------------------------------- roll ----
def tick(pitch):
    n = int(0.03 * SR)
    t = np.arange(n) / SR
    click = bandpass(rng.standard_normal(n), 2500, 7000) * np.exp(-t / 0.0025)
    ping = np.sin(2 * np.pi * pitch * t) * np.exp(-t / 0.012)
    return 0.6 * click + 0.35 * ping


def roll():
    buf = np.zeros(int((ROLL_SECONDS + 0.1) * SR))
    # Tick whenever a reel with 70 symbols passes the next one.
    steps = 70
    fine = np.linspace(0, 1, 20000)
    pos = ease_out(fine) * steps
    crossings = np.searchsorted(pos, np.arange(1, steps))
    for k, idx in enumerate(crossings):
        at = fine[min(idx, len(fine) - 1)] * ROLL_SECONDS
        place(buf, tick(1500 + 300 * (k % 2) + rng.uniform(-40, 40)), at)
    # A soft whirr under the fast part.
    t = t_axis(len(buf) / SR)
    whirr = bandpass(rng.standard_normal(len(buf)), 300, 1200) * 0.05
    whirr *= np.clip(1 - t / (ROLL_SECONDS * 0.6), 0, 1) ** 2
    return buf + whirr


# ---------------------------------------------------------------- ding ----
def ding():
    t = t_axis(1.6)
    thunk = lowpass(rng.standard_normal(len(t)), 400) * np.exp(-t / 0.03) * 1.5
    thunk += np.sin(2 * np.pi * 90 * t) * np.exp(-t / 0.06)
    bell = np.zeros_like(t)
    for ratio, amp, decay in [(1, 1, 0.9), (2.76, 0.5, 0.45), (5.40, 0.25, 0.25), (8.93, 0.12, 0.15)]:
        bell += amp * np.sin(2 * np.pi * 1320 * ratio * t) * np.exp(-t / decay)
    out = 0.5 * thunk
    place(out, 0.45 * bell, 0.02)
    return out


def bell_tone(freq, seconds, decay=0.9, partials=((1, 1, 1), (2.76, 0.5, 0.5), (5.40, 0.25, 0.28), (8.93, 0.12, 0.16))):
    """A struck bell: inharmonic partials, each fading at its own rate."""
    t = t_axis(seconds)
    out = np.zeros_like(t)
    for ratio, amp, d in partials:
        out += amp * np.sin(2 * np.pi * freq * ratio * t) * np.exp(-t / (decay * d))
    return out * np.minimum(t / 0.002, 1)


def marimba(freq, seconds=0.5):
    """A wooden bar: the fundamental and its 4th harmonic, short."""
    t = t_axis(seconds)
    out = np.sin(2 * np.pi * freq * t) * np.exp(-t / 0.22) + 0.35 * np.sin(2 * np.pi * freq * 4 * t) * np.exp(-t / 0.04)
    return out * np.minimum(t / 0.002, 1)


def pluck(freq, seconds=0.8):
    """A harp string (Karplus-Strong)."""
    n = int(seconds * SR)
    period = max(2, int(SR / freq))
    buf = rng.uniform(-1, 1, period)
    out = np.zeros(n)
    for i in range(n):
        out[i] = buf[i % period]
        buf[i % period] = 0.5 * (buf[i % period] + buf[(i + 1) % period]) * 0.996
    return lowpass(out, 6000)


def music_box(freq, seconds=1.4):
    t = t_axis(seconds)
    tone = np.sin(2 * np.pi * freq * t) + 0.3 * np.sin(2 * np.pi * freq * 3 * t) * np.exp(-t / 0.15)
    return tone * np.exp(-t / 0.55) * np.minimum(t / 0.003, 1) * (1 + 0.08 * np.sin(2 * np.pi * 6 * t))


def sparkles(seconds, count, lo=3000, hi=7000, start=0.0, spread=None, rise=False):
    """Tiny high pings scattered over [start, start + spread]."""
    out = np.zeros(int(seconds * SR))
    spread = spread or seconds - start - 0.2
    for k in range(count):
        u = k / max(count - 1, 1)
        f = (lo + (hi - lo) * u) if rise else rng.uniform(lo, hi)
        at = start + (u * spread if rise else rng.uniform(0, spread))
        t = t_axis(0.25)
        ping = np.sin(2 * np.pi * f * t) * np.exp(-t / 0.05) * np.minimum(t / 0.003, 1)
        place(out, ping * rng.uniform(0.3, 0.7), at)
    return out


def swish(seconds, f_from, f_to):
    """Noise through a band that sweeps from [f_from] to [f_to]."""
    # Fixed bands along the sweep, each faded in and out at its moment, so
    # the filters run continuously (no clicks between blocks).
    t = t_axis(seconds)
    u = t / seconds
    noise = rng.standard_normal(len(t))
    out = np.zeros_like(t)
    bands = 14
    for k in range(bands):
        c = f_from * (f_to / f_from) ** (k / (bands - 1))
        band = bandpass(noise, c * 0.75, min(c * 1.33, SR / 2 - 100))
        bump = np.exp(-((u - k / (bands - 1)) / (1.2 / bands)) ** 2)
        out += band * bump
    env = np.sin(np.pi * np.clip(u, 0, 1)) ** 1.5
    return out * env


def ding_s():
    """S and up: the reels lock in, then a bright major chord and a sparkle run."""
    out = ding() * 0.8
    out = np.concatenate([out, np.zeros(int(0.8 * SR))])
    for i, f in enumerate([1046.5, 1318.5, 1568.0, 2093.0]):
        place(out, bell_tone(f, 1.8, 0.8) * 0.28, 0.05 + 0.04 * i)
    out += sparkles(len(out) / SR, 10, 3500, 8000, start=0.12, spread=0.6, rise=True) * 0.35
    return out


def achievement():
    """Unlocked: a marimba run G5-C6-E6-G6, then a ringing C major chord."""
    out = np.zeros(int(2.4 * SR))
    for i, f in enumerate([783.99, 1046.5, 1318.5, 1568.0]):
        place(out, marimba(f) * 0.6, 0.075 * i)
    for f in [1046.5, 1318.5, 1568.0, 2093.0]:
        place(out, bell_tone(f, 2.0, 1.1) * 0.22, 0.32)
    out += sparkles(2.4, 12, 3000, 7500, start=0.35, spread=1.0) * 0.3
    return out


def item():
    """Redeemed: a harp sweep up a pentatonic scale to a chime."""
    out = np.zeros(int(2.0 * SR))
    scale = [523.25, 587.33, 659.25, 783.99, 880.0, 1046.5, 1174.66, 1318.5, 1568.0, 1760.0]
    for i, f in enumerate(scale):
        place(out, pluck(f, 0.9) * (0.35 + 0.04 * i), 0.035 * i)
    place(out, bell_tone(2093.0, 1.6, 0.9) * 0.35, 0.38)
    place(out, bell_tone(2637.0, 1.4, 0.7) * 0.2, 0.40)
    out += sparkles(2.0, 8, 4000, 8000, start=0.4, spread=0.8) * 0.25
    return out


def daily():
    """The daily top-up: two music-box notes and a soft twinkle."""
    out = np.zeros(int(2.0 * SR))
    place(out, music_box(1318.5) * 0.5, 0.0)
    place(out, music_box(1975.5) * 0.5, 0.18)
    place(out, music_box(1568.0) * 0.3, 0.18)
    out += sparkles(2.0, 6, 4000, 7000, start=0.3, spread=0.6) * 0.2
    return out


def wand():
    """The wand: a swish rising, sparkles trailing up, and a clear ting."""
    out = np.zeros(int(1.8 * SR))
    place(out, swish(0.45, 600, 6000) * 0.5, 0.0)
    out += sparkles(1.8, 9, 2500, 7500, start=0.08, spread=0.4, rise=True) * 0.4
    place(out, bell_tone(2349.3, 1.3, 0.8) * 0.5, 0.42)
    place(out, bell_tone(3135.9, 1.0, 0.6) * 0.25, 0.43)
    return out


def field():
    """The field: a low swell (a fifth) with wind, opening into a shimmer."""
    length = 2.2
    t = t_axis(length)
    swell = np.minimum(t / 0.7, 1) ** 2 * np.exp(-np.maximum(t - 0.8, 0) / 0.6)
    hum = (np.sin(2 * np.pi * 110 * t) + 0.6 * np.sin(2 * np.pi * 165 * t) + 0.3 * np.sin(2 * np.pi * 220 * t)) * swell * 0.5
    wind = swish(1.2, 300, 2500) * 0.35
    out = hum
    place(out, wind, 0.0)
    for i, f in enumerate([880.0, 1318.5, 1760.0, 2637.0]):
        place(out, bell_tone(f, 1.4, 0.9) * 0.18, 0.7 + 0.05 * i)
    out += sparkles(length, 10, 3000, 7000, start=0.75, spread=0.9) * 0.25
    return out


# ----------------------------------------------------------- celebrate ----
def saw(freq, t):
    """Band-limited-ish sawtooth (first 18 harmonics)."""
    out = np.zeros_like(t)
    phase = 2 * np.pi * np.cumsum(freq) / SR if np.ndim(freq) else 2 * np.pi * freq * t
    for h in range(1, 19):
        out += np.sin(h * phase) / h
    return out


def fanfare():
    # "ta-da-daaa": two short stabs and a long major chord, brassy.
    notes = [(0.00, 0.12, [523.25, 659.25, 783.99]), (0.16, 0.12, [587.33, 739.99, 880.0]),
             (0.32, 1.4, [659.25, 830.61, 987.77, 1318.5])]
    out = np.zeros(int(2.0 * SR))
    for at, dur, chord in notes:
        t = t_axis(dur + 0.4)
        env = np.minimum(t / 0.02, 1) * np.where(t < dur, 1, np.exp(-(t - dur) / 0.12))
        vib = 1 + 0.004 * np.sin(2 * np.pi * 5.5 * t) * np.minimum(t / 0.3, 1)
        tone = sum(saw(f * vib, t) for f in chord) / len(chord)
        # Brass: brighter as it gets louder.
        tone = lowpass(tone, 3200) * env
        place(out, tone * 0.35, at)
    return out


def voice(dur, f0, vowels):
    """One crowd voice: a glottal buzz through moving vowel formants."""
    t = t_axis(dur)
    u = t / dur
    # "wooo" contour: rise, hold, fall, with vibrato.
    contour = 1 + 0.35 * np.sin(np.pi * np.minimum(u * 1.3, 1)) - 0.15 * u
    freq = f0 * contour * (1 + 0.02 * np.sin(2 * np.pi * rng.uniform(4.5, 6.5) * t))
    src = saw(freq, t) + 0.15 * rng.standard_normal(len(t))
    # Interpolate formants across the vowel list.
    seg = np.minimum((u * (len(vowels) - 1)).astype(int), len(vowels) - 2)
    frac = u * (len(vowels) - 1) - seg
    out = np.zeros_like(t)
    for fi, bw in zip(range(3), (90, 110, 160)):
        a = np.array([v[fi] for v in vowels])
        target = a[seg] * (1 - frac) + a[seg + 1] * frac
        # Filter in short blocks with the block's formant frequency.
        block = 512
        for s in range(0, len(t), block):
            out[s:s + block] += resonator(src[s:s + block], target[s], bw) * (1.0, 0.6, 0.3)[fi]
    env = np.minimum(t / 0.08, 1) * np.minimum((dur - t) / 0.35, 1)
    return out * np.clip(env, 0, 1)


VOWELS = {
    'u': (320, 800, 2300), 'o': (500, 900, 2400), 'a': (750, 1250, 2600),
    'e': (500, 1900, 2600), 'ae': (680, 1700, 2500),
}


def whistle(dur):
    t = t_axis(dur)
    u = t / dur
    f = 2200 + 1300 * np.sin(np.pi * np.minimum(u * 1.6, 1)) ** 2 - 900 * np.maximum(u - 0.6, 0)
    tone = np.sin(2 * np.pi * np.cumsum(f) / SR) + 0.05 * rng.standard_normal(len(t))
    return tone * np.minimum(t / 0.03, 1) * np.minimum((dur - t) / 0.05, 1).clip(0, 1)


def clap():
    n = int(0.04 * SR)
    t = np.arange(n) / SR
    c = rng.uniform(900, 2600)
    return bandpass(rng.standard_normal(n), c * 0.6, c * 1.6) * np.exp(-t / rng.uniform(0.006, 0.014))


def celebrate():
    length = 7.0
    out = np.zeros(int(length * SR))
    t = t_axis(length)
    crowd_env = np.minimum(t / 0.5, 1) * np.clip((length - t) / 2.5, 0, 1)

    crowd = np.zeros_like(out)
    shouts = [['u', 'o', 'u'], ['e', 'ae', 'a'], ['u', 'u', 'o'], ['a', 'o', 'u'], ['o', 'a', 'a']]
    for _ in range(46):
        female = rng.random() < 0.5
        f0 = rng.uniform(230, 420) if female else rng.uniform(120, 220)
        dur = rng.uniform(0.7, 2.2)
        at = rng.uniform(0.05, 0.9) if rng.random() < 0.6 else rng.uniform(0.9, 4.0)
        v = voice(dur, f0, [VOWELS[k] for k in shouts[rng.integers(len(shouts))]])
        place(crowd, v * rng.uniform(0.4, 1.0) / np.max(np.abs(v) + 1e-9), at)
    for _ in range(4):
        place(crowd, whistle(rng.uniform(0.5, 0.9)) * 0.25, rng.uniform(0.2, 3.0))

    applause = np.zeros_like(out)
    at = 0.1
    while at < length - 0.1:
        rate = 40 + 220 * np.minimum(at / 0.8, 1)
        place(applause, clap() * rng.uniform(0.3, 1.0), at)
        at += rng.exponential(1 / rate)

    mix = 0.5 * crowd / (np.max(np.abs(crowd)) + 1e-9) + 0.45 * applause / (np.max(np.abs(applause)) + 1e-9)
    mix *= crowd_env
    # A short room so it sounds like one audience, not a pile of tracks.
    ir_t = t_axis(0.6)
    ir = rng.standard_normal(len(ir_t)) * np.exp(-ir_t / 0.15)
    ir[0] = 6
    room = signal.fftconvolve(mix, ir)[:len(mix)]
    mix = room / (np.max(np.abs(room)) + 1e-9) * 0.8

    place(mix, fanfare(), 0.0)
    return mix


# --------------------------------------------------------------- output ----
def write_mp3(name, x, peak=0.89):
    x = x / (np.max(np.abs(x)) + 1e-9) * peak
    pcm = (x * 32767).astype('<i2')
    os.makedirs(OUT, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, name + '.wav')
        with wave.open(wav, 'wb') as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(SR)
            w.writeframes(pcm.tobytes())
        dst = os.path.join(OUT, name + '.mp3')
        subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', wav, '-c:a', 'libmp3lame', '-b:a', '128k', dst], check=True)
    print(dst, os.path.getsize(dst), 'bytes', file=sys.stderr)


if __name__ == '__main__':
    only = set(sys.argv[1:])
    sounds = {
        'roll': (roll, 0.7), 'ding': (ding, 0.8), 'ding_s': (ding_s, 0.8), 'celebrate': (celebrate, 0.89),
        'achievement': (achievement, 0.8), 'item': (item, 0.8), 'daily': (daily, 0.7), 'wand': (wand, 0.75), 'field': (field, 0.75),
    }
    for name, (make, peak) in sounds.items():
        if not only or name in only:
            write_mp3(name, make(), peak)
