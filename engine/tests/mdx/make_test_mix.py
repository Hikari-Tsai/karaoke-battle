#!/usr/bin/env python3
"""Synthesise a 20 s, 44.1 kHz stereo test mixture for the MDX separation tests.

"Vocal": a harmonic tone with vibrato following a short melody, with a
sung-like amplitude envelope and a slowly moving formant filter.
"Instruments": a bass line, sustained chords and a drum pattern built from
noise bursts. Written as 32-bit float WAVs:
  <out_dir>/mix.wav, <out_dir>/vocal_true.wav, <out_dir>/inst_true.wav

usage: make_test_mix.py <out_dir> [--seconds 20] [--seed 1]
"""
import argparse
import os

import numpy as np
import soundfile as sf

SR = 44100


def midi_to_hz(m):
    return 440.0 * 2.0 ** ((m - 69) / 12.0)


def adsr(n, a, d, s_level, r):
    """Attack/decay/sustain/release envelope with n samples."""
    env = np.ones(n, dtype=np.float64) * s_level
    a = min(a, n); d = min(d, max(0, n - a)); r = min(r, n)
    env[:a] = np.linspace(0, 1, a, endpoint=False)
    env[a:a + d] = np.linspace(1, s_level, d, endpoint=False)
    env[n - r:] *= np.linspace(1, 0, r)
    return env


def vocal(seconds, rng):
    # Melody in MIDI notes with durations (beats at 100 bpm)
    bpm = 100.0
    beat = 60.0 / bpm
    melody = [(67, 1), (69, 1), (71, 2), (69, 1), (67, 1), (64, 2),
              (62, 1), (64, 1), (67, 2), (66, 1), (64, 1), (62, 2),
              (0, 1), (71, 1), (74, 2), (72, 1), (71, 1), (69, 2),
              (67, 1), (69, 1), (71, 1), (72, 1), (74, 4)]
    total = int(seconds * SR)
    out = np.zeros(total)
    t_cursor = 0.0
    while t_cursor < seconds:
        for note, dur in melody:
            n0 = int(t_cursor * SR)
            n = int(dur * beat * SR)
            if n0 >= total:
                break
            n = min(n, total - n0)
            if note > 0:
                t = np.arange(n) / SR
                f0 = midi_to_hz(note)
                # vibrato 5.5 Hz, ~40 cents, ramps in after 150 ms; small pitch glide at onset
                vib_depth = 0.04 * np.clip((t - 0.15) / 0.25, 0, 1)
                glide = -0.5 * np.exp(-t / 0.05)
                inst_f = f0 * 2.0 ** ((glide + vib_depth * np.sin(2 * np.pi * 5.5 * t)) / 12.0)
                phase = 2 * np.pi * np.cumsum(inst_f) / SR
                sig = np.zeros(n)
                # harmonic series with formant-like weighting that drifts (vowel change)
                for h in range(1, 25):
                    fh = h * f0
                    if fh > 16000:
                        break
                    form = (np.exp(-((fh - 700) / 400.0) ** 2) + 0.7 * np.exp(-((fh - 1200 + 300 * np.sin(2 * np.pi * 0.7 * t)) / 500.0) ** 2)
                            + 0.4 * np.exp(-((fh - 2600) / 700.0) ** 2) + 0.05)
                    sig += form * np.sin(h * phase) / h ** 0.7
                # breathiness: filtered noise following the envelope
                noise = rng.standard_normal(n)
                noise = np.convolve(noise, np.ones(8) / 8, mode="same")
                sig += 0.03 * noise
                env = adsr(n, int(0.04 * SR), int(0.1 * SR), 0.8, int(0.08 * SR))
                out[n0:n0 + n] += sig * env
            t_cursor += dur * beat
        # loop the melody if there is time left
    out /= np.max(np.abs(out)) + 1e-9
    return 0.5 * out


def bass(seconds, rng):
    bpm = 100.0
    beat = 60.0 / bpm
    pattern = [43, 43, 50, 48, 40, 40, 47, 45]   # G2 G2 D3 C3 E2 E2 B2 A2
    total = int(seconds * SR)
    out = np.zeros(total)
    i = 0
    t_cursor = 0.0
    while t_cursor < seconds:
        n0 = int(t_cursor * SR)
        n = min(int(beat * SR), total - n0)
        if n <= 0:
            break
        t = np.arange(n) / SR
        f0 = midi_to_hz(pattern[i % len(pattern)])
        sig = np.sin(2 * np.pi * f0 * t) + 0.4 * np.sin(2 * np.pi * 2 * f0 * t) + 0.15 * np.sin(2 * np.pi * 3 * f0 * t)
        env = adsr(n, int(0.005 * SR), int(0.2 * SR), 0.6, int(0.05 * SR))
        out[n0:n0 + n] += sig * env
        t_cursor += beat
        i += 1
    return 0.35 * out / (np.max(np.abs(out)) + 1e-9)


def chords(seconds, rng):
    bpm = 100.0
    bar = 4 * 60.0 / bpm
    prog = [[55, 59, 62, 67], [50, 54, 57, 62], [52, 55, 59, 64], [57, 60, 64, 69]]
    total = int(seconds * SR)
    out = np.zeros(total)
    i = 0
    t_cursor = 0.0
    while t_cursor < seconds:
        n0 = int(t_cursor * SR)
        n = min(int(bar * SR), total - n0)
        if n <= 0:
            break
        t = np.arange(n) / SR
        sig = np.zeros(n)
        for m in prog[i % len(prog)]:
            f0 = midi_to_hz(m)
            # detuned saw-ish pad (band limited)
            for h in range(1, 12):
                sig += (np.sin(2 * np.pi * h * f0 * 1.002 * t) + np.sin(2 * np.pi * h * f0 * 0.998 * t)) / h
        env = adsr(n, int(0.3 * SR), int(0.5 * SR), 0.7, int(0.4 * SR))
        out[n0:n0 + n] += sig * env
        t_cursor += bar
        i += 1
    return 0.25 * out / (np.max(np.abs(out)) + 1e-9)


def drums(seconds, rng):
    bpm = 100.0
    step = 60.0 / bpm / 4   # 16th notes
    total = int(seconds * SR)
    out = np.zeros(total)
    k = 0
    t_cursor = 0.0
    while t_cursor < seconds:
        n0 = int(t_cursor * SR)
        pos = k % 16
        if pos in (0, 8, 10):                       # kick: low sine burst with pitch drop
            n = min(int(0.25 * SR), total - n0)
            t = np.arange(n) / SR
            f = 50 + 120 * np.exp(-t / 0.03)
            out[n0:n0 + n] += 0.9 * np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.12)
        if pos in (4, 12):                          # snare: noise burst + tone
            n = min(int(0.2 * SR), total - n0)
            t = np.arange(n) / SR
            noise = rng.standard_normal(n)
            noise = noise - np.convolve(noise, np.ones(16) / 16, mode="same")
            out[n0:n0 + n] += (0.6 * noise * np.exp(-t / 0.06) + 0.4 * np.sin(2 * np.pi * 190 * t) * np.exp(-t / 0.04))
        if pos % 2 == 0:                            # hats
            n = min(int(0.05 * SR), total - n0)
            t = np.arange(n) / SR
            noise = rng.standard_normal(n)
            noise = noise - np.convolve(noise, np.ones(4) / 4, mode="same")
            out[n0:n0 + n] += 0.25 * noise * np.exp(-t / (0.012 if pos % 4 else 0.03))
        t_cursor += step
        k += 1
    return 0.4 * out / (np.max(np.abs(out)) + 1e-9)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out_dir")
    ap.add_argument("--seconds", type=float, default=20.0)
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()
    rng = np.random.default_rng(args.seed)
    os.makedirs(args.out_dir, exist_ok=True)

    v = vocal(args.seconds, rng)
    b = bass(args.seconds, rng)
    c = chords(args.seconds, rng)
    d = drums(args.seconds, rng)
    n = len(v)

    # stereo placement: vocal centre, bass centre, chords wide, drums slightly left/right
    voc = np.stack([v, v], axis=1)
    inst = np.stack([b + 0.8 * c + 1.0 * d, b + 0.6 * c + 0.9 * d], axis=1)
    # slight stereo decorrelation of chords via delay on the right channel
    delay = int(0.012 * SR)
    inst[delay:, 1] += 0.3 * c[:n - delay]
    mix = voc + inst
    peak = np.max(np.abs(mix))
    g = 0.89 / peak
    voc *= g; inst *= g; mix *= g

    sf.write(os.path.join(args.out_dir, "mix.wav"), mix.astype(np.float32), SR, subtype="FLOAT")
    sf.write(os.path.join(args.out_dir, "vocal_true.wav"), voc.astype(np.float32), SR, subtype="FLOAT")
    sf.write(os.path.join(args.out_dir, "inst_true.wav"), inst.astype(np.float32), SR, subtype="FLOAT")
    print(f"wrote {args.out_dir}/mix.wav ({args.seconds:.1f}s, peak {np.max(np.abs(mix)):.3f})")


if __name__ == "__main__":
    main()
