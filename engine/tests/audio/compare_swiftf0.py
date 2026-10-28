#!/usr/bin/env python3
"""Compare ke_cli's SwiftF0 JSON against the upstream swift-f0 Python package.

    python compare_swiftf0.py --wav test.wav --ke-json f0.json [--fmin 46.875 --fmax 2093.75]
                              [--truth test.wav.truth.json] [--max-cents 5] [--min-agree 0.95]

Runs swift_f0.SwiftF0().detect_file(wav) (the pip package bundles the same
model.onnx) and reports, over frames both sides call voiced (confidence >= 0.5):
  * median / p95 / max |cents| difference
  * voicing agreement (fraction of frames where voiced flags agree)
  * max |confidence| difference and the number of frames
Optionally compares both against the synthesiser's ground truth f0.
Exit code 0 when median |cents| < --max-cents and agreement > --min-agree.
"""
import argparse
import json
import sys

import numpy as np


def cents(a, b):
    return 1200.0 * np.log2(a / b)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wav", required=True)
    ap.add_argument("--ke-json", required=True)
    ap.add_argument("--fmin", type=float, default=None)
    ap.add_argument("--fmax", type=float, default=None)
    ap.add_argument("--truth", default=None, help="<wav>.truth.json from make_test_wav.py")
    ap.add_argument("--max-cents", type=float, default=5.0)
    ap.add_argument("--min-agree", type=float, default=0.95)
    a = ap.parse_args()

    from swift_f0 import SwiftF0

    ref = SwiftF0().detect_file(a.wav, fmin=a.fmin, fmax=a.fmax)
    with open(a.ke_json) as f:
        ke = json.load(f)
    ke_t = np.asarray(ke["times"], dtype=np.float64)
    ke_f0 = np.asarray(ke["f0"], dtype=np.float64)
    ke_c = np.asarray(ke["confidence"], dtype=np.float64)

    n_ref, n_ke = len(ref.timestamps), len(ke_t)
    print(f"frames: swift-f0={n_ref} ke_cli={n_ke}  hop={ke['hop']}  range={ke['fmin']}..{ke['fmax']} Hz")
    n = min(n_ref, n_ke)
    if n_ref != n_ke:
        print(f"WARNING: frame count differs by {abs(n_ref - n_ke)}; comparing the first {n}")
    dt = np.abs(ke_t[:n] - ref.timestamps[:n]).max() if n else 0.0
    print(f"max |timestamp diff| = {dt * 1000:.3f} ms")

    ref_voiced = ref.confidence[:n] >= 0.5
    ke_voiced = ke_c[:n] >= 0.5
    agree = float(np.mean(ref_voiced == ke_voiced)) if n else 0.0
    both = ref_voiced & ke_voiced & (ke_f0[:n] > 0) & (ref.pitch_hz[:n] > 0)
    dc = np.abs(ke_c[:n] - ref.confidence[:n])
    print(f"voicing: swift-f0 voiced={ref_voiced.sum()} ke voiced={ke_voiced.sum()} agreement={agree * 100:.2f}%")
    print(f"max |confidence diff| = {dc.max() if n else 0:.5f}")
    if both.sum() == 0:
        print("FAIL: no frames voiced on both sides")
        sys.exit(1)
    d = np.abs(cents(ke_f0[:n][both], ref.pitch_hz[:n][both]))
    med, p95, mx = float(np.median(d)), float(np.percentile(d, 95)), float(d.max())
    print(f"|cents| on {both.sum()} voiced frames: median={med:.3f} p95={p95:.3f} max={mx:.3f}")

    # consistency with the ke JSON convention: f0 == 0 exactly where confidence < 0.5
    bad = np.sum((ke_f0[:n] == 0) != (ke_c[:n] < 0.5))
    if bad:
        print(f"WARNING: {bad} frames where f0==0 does not match confidence<0.5")

    if a.truth:
        with open(a.truth) as f:
            truth = json.load(f)
        tf = np.asarray(truth["f0"])
        tt = np.arange(len(tf)) * truth["truth_hop"]
        gaps = truth.get("gaps", [])
        in_gap = np.zeros(n, dtype=bool)
        for g0, g1 in gaps:
            in_gap |= (ke_t[:n] >= g0 - 0.05) & (ke_t[:n] <= g1 + 0.05)
        t_f0 = np.interp(ke_t[:n], tt, tf)
        for name, f0v, voiced in (("swift-f0", ref.pitch_hz[:n], ref_voiced), ("ke_cli", ke_f0[:n], ke_voiced)):
            m = voiced & ~in_gap & (f0v > 0)
            e = np.abs(cents(f0v[m], t_f0[m]))
            print(f"{name} vs ground truth on {m.sum()} frames: median={np.median(e):.2f} cents, p95={np.percentile(e, 95):.2f}, "
                  f"voiced outside gaps={np.mean(voiced[~in_gap]) * 100:.1f}%")

    ok = med < a.max_cents and agree > a.min_agree and n_ref == n_ke
    print("PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
