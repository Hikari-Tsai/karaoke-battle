#!/usr/bin/env python3
"""Generates a synthetic 20 s "singing" WAV at 44.1 kHz mono.

Several phrases of notes (sum of harmonics following a melody with vibrato and an
amplitude envelope) separated by short silences so that GAME's slicer produces
multiple slices. Deterministic (fixed seed).

usage: make_synthetic.py OUT.wav [--seconds 20] [--seed 0]
"""
import argparse

import numpy as np
import soundfile as sf

SR = 44100


def midi_to_hz(m):
    return 440.0 * 2.0 ** ((m - 69.0) / 12.0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--seconds", type=float, default=20.0)
    ap.add_argument("--seed", type=int, default=0)
    a = ap.parse_args()

    rng = np.random.default_rng(a.seed)
    total = int(a.seconds * SR)
    y = np.zeros(total, dtype=np.float64)
    scale = np.array([60, 62, 64, 65, 67, 69, 71, 72])  # C major, C4..C5

    t_cursor = 0.3  # leading silence
    phrase_idx = 0
    while t_cursor < a.seconds - 1.0:
        # phrase: 4..8 notes of 0.25..0.6 s each, then 0.4..0.8 s of silence
        n_notes = int(rng.integers(4, 9))
        pitch = int(rng.choice(scale))
        for _ in range(n_notes):
            dur = float(rng.uniform(0.25, 0.6))
            if t_cursor + dur > a.seconds - 0.5:
                break
            step = int(rng.integers(-2, 3))
            pitch = int(np.clip(scale[(np.abs(scale - pitch).argmin() + step) % len(scale)], 55, 79))
            n = int(dur * SR)
            tt = np.arange(n) / SR
            # vibrato: 5.5 Hz, +-30 cents, starting after 80 ms
            vib = 0.3 * np.sin(2 * np.pi * 5.5 * tt) * np.clip((tt - 0.08) / 0.1, 0, 1)
            f0 = midi_to_hz(pitch + vib)
            phase = 2 * np.pi * np.cumsum(f0) / SR
            # harmonic stack with a slightly decaying spectrum
            sig = np.zeros(n)
            for h in range(1, 9):
                sig += (0.6 ** (h - 1)) * np.sin(h * phase + rng.uniform(0, 2 * np.pi))
            # amplitude envelope: 30 ms attack, 60 ms release
            env = np.minimum(1.0, tt / 0.03) * np.minimum(1.0, (dur - tt) / 0.06)
            env *= 0.9 + 0.1 * np.sin(2 * np.pi * 0.7 * tt)
            start = int(t_cursor * SR)
            y[start:start + n] += 0.25 * sig * env
            t_cursor += dur
        phrase_idx += 1
        t_cursor += float(rng.uniform(0.4, 0.8))

    # a tiny bit of noise floor well below -40 dB
    y += rng.normal(0, 1e-4, size=total)
    y = np.clip(y, -1, 1).astype(np.float32)
    sf.write(a.out, y, SR, subtype="FLOAT")
    print(f"wrote {a.out}: {a.seconds:.1f} s, {phrase_idx} phrases")


if __name__ == "__main__":
    main()
