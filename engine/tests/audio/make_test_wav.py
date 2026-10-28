#!/usr/bin/env python3
"""Synthetic test signal for the SwiftF0 / live-audio tests.

Writes a mono float32 WAV containing a sung-like tone: a glide from --f-start to
--f-end Hz (log sweep) with vibrato, a few harmonics, a slow amplitude envelope
and short silent gaps, so the file exercises voiced/unvoiced decisions,
pitch tracking under modulation and the silence gate.

    python make_test_wav.py out.wav --rate 48000 --seconds 8
    python make_test_wav.py out16k.wav --rate 16000 --seconds 8 --seed 1

Also writes "<out>.truth.json" with the instantaneous f0 (Hz) every 1 ms and
the gap intervals, so a test can check absolute accuracy, not only agreement
between two implementations.
"""
import argparse
import json
import math

import numpy as np
import soundfile as sf


def synth(rate, seconds, f_start, f_end, vib_hz, vib_cents, seed, gaps):
    rng = np.random.default_rng(seed)
    n = int(rate * seconds)
    t = np.arange(n) / rate
    # log glide f_start -> f_end plus vibrato
    glide = f_start * (f_end / f_start) ** (t / seconds)
    vib = 2 ** (vib_cents / 1200 * np.sin(2 * math.pi * vib_hz * t))
    f0 = glide * vib
    phase = 2 * math.pi * np.cumsum(f0) / rate
    # harmonics with decaying amplitudes (vowel-ish)
    amps = [1.0, 0.6, 0.4, 0.25, 0.15, 0.08]
    sig = sum(a * np.sin(k * phase) for k, a in enumerate(amps, start=1))
    sig /= np.abs(sig).max()
    # slow amplitude envelope between -18 dBFS and -6 dBFS
    env = 10 ** ((-12 + 6 * np.sin(2 * math.pi * 0.23 * t + 1.0)) / 20)
    sig = sig * env
    # gaps of digital silence and of near-silence (below swift-f0's 1e-3 gate)
    gap_list = []
    for g in range(gaps):
        start = (g + 1) * seconds / (gaps + 1)
        a, b = int(start * rate), int((start + 0.25) * rate)
        fade = min(int(0.01 * rate), (b - a) // 4)
        sig[a - fade:a] *= np.linspace(1, 0, fade)
        sig[a:b] = 0.0 if g % 2 == 0 else rng.standard_normal(b - a) * 1e-4
        sig[b:b + fade] *= np.linspace(0, 1, fade)
        gap_list.append([a / rate, b / rate])
    # a little noise so the file is not pathologically clean
    sig += rng.standard_normal(n) * 1e-4
    truth_t = np.arange(0, seconds, 0.001)
    truth_f0 = np.interp(truth_t, t, f0)
    return sig.astype(np.float32), {"rate": rate, "truth_hop": 0.001, "f0": truth_f0.round(3).tolist(), "gaps": gap_list}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--rate", type=int, default=48000)
    ap.add_argument("--seconds", type=float, default=8.0)
    ap.add_argument("--f-start", type=float, default=130.0)
    ap.add_argument("--f-end", type=float, default=520.0)
    ap.add_argument("--vib-hz", type=float, default=5.5)
    ap.add_argument("--vib-cents", type=float, default=40.0)
    ap.add_argument("--gaps", type=int, default=3)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--stereo", action="store_true", help="write a (slightly different L/R) stereo file")
    a = ap.parse_args()
    sig, truth = synth(a.rate, a.seconds, a.f_start, a.f_end, a.vib_hz, a.vib_cents, a.seed, a.gaps)
    if a.stereo:
        sig = np.stack([sig, sig * 0.8], axis=1)
    sf.write(a.out, sig, a.rate, subtype="FLOAT")
    with open(a.out + ".truth.json", "w") as f:
        json.dump(truth, f)
    print(f"wrote {a.out}: {a.rate} Hz, {a.seconds:.1f} s, glide {a.f_start}->{a.f_end} Hz, {a.gaps} gaps")


if __name__ == "__main__":
    main()
