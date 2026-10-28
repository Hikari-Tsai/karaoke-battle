#!/usr/bin/env python3
"""Smoke / accuracy test of the live audio path (ke_cli devices / live / calibrate).

    python live_test.py --ke-cli ../../build-audio/ke_cli --ort <libonnxruntime> --model <swiftf0.onnx>
                        [--track track.wav] [--seconds 5] [--loopback auto|none|<device-name-substring>]
                        [--work-dir /tmp/ke_live]

What it checks
  1. `ke_cli devices` returns JSON with capture/playback lists (fails if the device
     list is empty).
  2. `ke_cli live --track <synthetic> --seconds N --save take.wav` exits 0, reports the
     device info, produces MPM (source=0) and SwiftF0 (source=1) frames, writes
     take.wav + take.wav.json. This runs on the *default* devices; with no usable
     microphone the frames are simply unvoiced, which is still a pass.
  3. If a loopback device is available ("--loopback auto" looks for BlackHole /
     "Loopback" / VB-Cable / "Virtual" in the device list; or name one explicitly) the
     same run is repeated with playback and capture both on that device, so the
     capture "hears" the track and the frames can be checked against the synthetic
     ground truth: median |cents| vs truth after the best time offset must be < 10
     (MPM) / < 10 (SwiftF0), the best offset (= uncompensated latency) is printed, and
     take.wav is cross-correlated with the track to verify the sidecar offset.
     `ke_cli calibrate` is also run on the loopback and must report a round trip
     within 5 ms of the alignment found above.
"""
import argparse
import json
import os
import re
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))


def run(cmd, log=None, timeout=120):
    print("$", " ".join(cmd))
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if log:
        with open(log, "w") as f:
            f.write(p.stdout)
            f.write(p.stderr)
    return p


def parse_frames(text):
    rows = []
    for line in text.splitlines():
        m = re.match(r"\s*(-?[\d.]+)\s+f0=\s*([\d.]+)\s+conf=([\d.]+)\s+rms=\s*(-?[\d.]+) dB\s+src=(\d)", line)
        if m:
            rows.append([float(x) for x in m.groups()])
    return np.asarray(rows).reshape(-1, 5)


def align_to_truth(frames, truth, src):
    d = frames[frames[:, 4] == src]
    if len(d) == 0:
        return None
    tf = np.asarray(truth["f0"])
    tt = np.arange(len(tf)) * truth["truth_hop"]
    t, f0 = d[:, 0], d[:, 1]
    best = None
    for off in np.arange(-0.150, 0.151, 0.001):
        ref = np.interp(t + off, tt, tf)
        in_gap = np.zeros(len(t), bool)
        for g0, g1 in truth["gaps"]:
            in_gap |= (t + off > g0 - 0.06) & (t + off < g1 + 0.06)
        m = (f0 > 0) & ~in_gap & (t + off > 0.1) & (t + off < tt[-1] - 0.1)
        if m.sum() < 10:
            continue
        e = np.abs(1200 * np.log2(f0[m] / ref[m]))
        med = float(np.median(e))
        if best is None or med < best["median_cents"]:
            best = {"median_cents": med, "offset_ms": float(off * 1000), "p95_cents": float(np.percentile(e, 95)), "frames": int(m.sum())}
    return {"n": len(d), "voiced_frac": float(np.mean(f0 > 0)), **(best or {})}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ke-cli", required=True)
    ap.add_argument("--ort", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--track", default=None, help="synthetic track WAV from make_test_wav.py (made if omitted)")
    ap.add_argument("--seconds", type=float, default=5.0)
    ap.add_argument("--loopback", default="auto")
    ap.add_argument("--work-dir", default=os.path.join(HERE, "_live_out"))
    a = ap.parse_args()
    os.makedirs(a.work_dir, exist_ok=True)
    ok = True

    # 1. devices
    p = run([a.ke_cli, "devices"])
    if p.returncode != 0:
        print("FAIL: ke_cli devices:", p.stderr)
        sys.exit(1)
    devs = json.loads(p.stdout)
    print(f"backend {devs.get('backend')}: {len(devs['capture'])} capture, {len(devs['playback'])} playback devices")
    for kind in ("capture", "playback"):
        for d in devs[kind]:
            print(f"  {kind:8s} {'*' if d['default'] else ' '} {d['name']}")
    if not devs["capture"] or not devs["playback"]:
        print("FAIL: no audio devices")
        sys.exit(1)

    # synthetic track
    track = a.track
    if not track:
        track = os.path.join(a.work_dir, "track.wav")
        subprocess.check_call([sys.executable, "-I", os.path.join(HERE, "make_test_wav.py"), track, "--rate", "48000",
                               "--seconds", str(a.seconds + 1), "--seed", "3", "--f-start", "220", "--f-end", "330", "--stereo"])
    truth = json.load(open(track + ".truth.json"))

    # 2. default devices
    take = os.path.join(a.work_dir, "take_default.wav")
    p = run([a.ke_cli, "live", "--ort", a.ort, "--model", a.model, "--track", track, "--seconds", str(a.seconds), "--save", take, "--verbose"],
            log=os.path.join(a.work_dir, "live_default.log"))
    frames = parse_frames(p.stdout)
    info = [l for l in p.stderr.splitlines() if "audio:" in l or "latency" in l or "capture elapsed" in l]
    print("\n".join("  " + l for l in info))
    n0, n1 = int(np.sum(frames[:, 4] == 0)) if len(frames) else 0, int(np.sum(frames[:, 4] == 1)) if len(frames) else 0
    print(f"default devices: exit {p.returncode}, {n0} MPM frames, {n1} SwiftF0 frames, take written: {os.path.exists(take)} sidecar: {os.path.exists(take + '.json')}")
    if p.returncode != 0 or n0 < a.seconds * 50 or n1 < a.seconds * 30 or not os.path.exists(take + ".json"):
        print("FAIL: live run on default devices")
        ok = False
    else:
        print("PASS: live run on default devices (pitch content not checked: depends on what the microphone hears)")

    # 3. loopback
    loop = None
    if a.loopback != "none":
        names = [d["name"] for d in devs["playback"] if any(d["name"] == c["name"] for c in devs["capture"])]
        keys = ["blackhole", "loopback", "vb-audio", "cable", "virtual"] if a.loopback == "auto" else [a.loopback.lower()]
        for n in names:
            if any(k in n.lower() for k in keys):
                loop = n
                break
    if not loop:
        print("no loopback device found: pitch accuracy, timestamp alignment and calibration NOT verified")
    else:
        pid = next(d["id"] for d in devs["playback"] if d["name"] == loop)
        cid = next(d["id"] for d in devs["capture"] if d["name"] == loop)
        print(f"loopback device: {loop}")
        take = os.path.join(a.work_dir, "take_loop.wav")
        p = run([a.ke_cli, "live", "--ort", a.ort, "--model", a.model, "--track", track, "--seconds", str(a.seconds), "--save", take,
                 "--playback", pid, "--capture", cid, "--verbose"], log=os.path.join(a.work_dir, "live_loop.log"))
        frames = parse_frames(p.stdout)
        stats = [l for l in p.stderr.splitlines() if "capture stopped" in l]
        print("\n".join("  " + l for l in stats))
        res = {src: align_to_truth(frames, truth, src) for src in (0, 1)}
        for src, r in res.items():
            print(f"  source={src} ({'MPM' if src == 0 else 'SwiftF0'}): {r}")
        side = json.load(open(take + ".json"))
        import soundfile as sf
        x, sr = sf.read(take, dtype="float32")
        y, _ = sf.read(track, dtype="float32")
        y = y.mean(axis=1) if y.ndim == 2 else y
        n = min(len(x), len(y), sr * 4)
        lags = range(0, int(0.3 * sr), 4)
        c = [float(np.dot(x[l:n], y[:n - l])) for l in lags]
        lag = lags[int(np.argmax(c))]
        print(f"  take.wav lags the track by {lag / sr * 1000:.1f} ms; sidecar track_start_offset={side['track_start_offset'] * 1000:.1f} ms, latency={side['latency'] * 1000:.1f} ms "
              f"-> residual {(lag / sr - side['track_start_offset'] - side['latency']) * 1000:.1f} ms (= uncompensated input latency unless calibrated)")
        p = run([a.ke_cli, "calibrate", "--playback", pid, "--capture", cid, "--verbose"])
        m = re.search(r"roundtrip latency: ([\d.]+) ms", p.stdout)
        rt = float(m.group(1)) if m else None
        print(f"  calibrate: exit {p.returncode}, round trip {rt} ms")
        for src, r in res.items():
            if not r or "median_cents" not in r or r["median_cents"] > 10:
                print(f"FAIL: source {src} pitch accuracy")
                ok = False
        if rt is None or abs(rt - lag / sr * 1000) > 5:
            print("FAIL: calibration does not match the loopback alignment")
            ok = False
        for src, r in res.items():
            if r and "offset_ms" in r and abs(-r["offset_ms"] - (lag / sr * 1000 - side["latency"] * 1000)) > 12:
                print(f"FAIL: source {src} frame timestamps off by {r['offset_ms']} ms, expected ~{-(lag / sr * 1000 - side['latency'] * 1000):.0f}")
                ok = False
        if ok:
            print("PASS: loopback pitch accuracy, timestamps and calibration")
    print("ALL PASS" if ok else "SOME CHECKS FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
