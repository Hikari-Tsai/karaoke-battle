#!/usr/bin/env python3
"""Synthesizes the results-screen sound effects into app/assets/sfx/.

Everything is generated from noise and oscillators, so the sounds carry no
third-party license. Re-run after tweaking:

    python3 tools/sfx/make_sfx.py

Needs numpy, scipy and ffmpeg (for the mp3 encode).

  roll.mp3       slot-machine reel ticks, fast then slowing, timed to the
                 score counter (ROLL_SECONDS, ROLL_EASE)
  ding.mp3       the reels locking in: a thunk and a bell
  celebrate.mp3  new personal best: fanfare stab, cheering crowd, applause
                 and whistles
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
    write_mp3('roll', roll(), 0.7)
    write_mp3('ding', ding(), 0.8)
    write_mp3('celebrate', celebrate())
