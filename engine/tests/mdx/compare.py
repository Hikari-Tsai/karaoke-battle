#!/usr/bin/env python3
"""Compare C++ engine stems against reference stems.

Prints the SNR in dB of each C++ stem relative to the reference stem
(SNR = 10 log10(|ref|^2 / |ref - ours|^2)) after trimming both to the common
length, plus the least-squares gain between them and the SNR after applying
that gain (to spot pure scaling differences).

usage: compare.py --ref-primary a.wav --our-primary b.wav
                  [--ref-secondary c.wav --our-secondary d.wav] [--min-snr 30]
exit status 1 when any SNR is below --min-snr.
"""
import argparse
import sys

import numpy as np
import soundfile as sf


def load(path):
    x, sr = sf.read(path, dtype="float64", always_2d=True)
    return x, sr


def snr_db(ref, est):
    noise = ref - est
    num = np.sum(ref ** 2)
    den = np.sum(noise ** 2)
    if den == 0:
        return float("inf")
    return 10.0 * np.log10(num / den)


def compare(name, ref_path, our_path):
    ref, sr_r = load(ref_path)
    our, sr_o = load(our_path)
    if sr_r != sr_o:
        print(f"{name}: sample rate mismatch {sr_r} vs {sr_o}")
        return -np.inf
    n = min(len(ref), len(our))
    if len(ref) != len(our):
        print(f"{name}: length differs ({len(ref)} vs {len(our)} frames), comparing first {n}")
    ref = ref[:n]
    our = our[:n]
    if ref.shape[1] != our.shape[1]:
        print(f"{name}: channel count differs ({ref.shape[1]} vs {our.shape[1]})")
        return -np.inf
    raw = snr_db(ref, our)
    g = float(np.sum(ref * our) / max(np.sum(our * our), 1e-20))
    fitted = snr_db(ref, our * g)
    maxabs = float(np.max(np.abs(ref - our)))
    print(f"{name}: SNR = {raw:.2f} dB   (gain-fitted {fitted:.2f} dB at gain {g:.4f}, "
          f"max |diff| = {maxabs:.2e}, ref peak = {np.max(np.abs(ref)):.3f})")
    return raw


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref-primary", required=True)
    ap.add_argument("--our-primary", required=True)
    ap.add_argument("--ref-secondary")
    ap.add_argument("--our-secondary")
    ap.add_argument("--min-snr", type=float, default=30.0)
    args = ap.parse_args()
    results = [compare("primary", args.ref_primary, args.our_primary)]
    if args.ref_secondary and args.our_secondary:
        results.append(compare("secondary", args.ref_secondary, args.our_secondary))
    ok = all(r >= args.min_snr for r in results)
    print("PASS" if ok else f"FAIL (threshold {args.min_snr} dB)")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
