#!/usr/bin/env python3
"""Produce reference stems with the `audio-separator` MDXSeparator (the Python
port of UVR's SeperateMDX) for a given ONNX model.

The separator is built directly from the manifest parameters (no model-data
download). Stems are produced the way the engine's ke_separate contract defines
them:
    primary   = MDXSeparator.demix(mix)              (unscaled)
    secondary = mix - primary * compensate
and written as 32-bit float stereo 44.1 kHz WAVs with soundfile.

Optionally (--full) the stock MDXSeparator.separate() path is run as well; note
that it normalises/scales the output (`* peak`, normalization_threshold) and
writes through pydub, so it is only useful as a sanity check.

usage: run_reference.py --model <onnx> --manifest <manifest.json> --in mix.wav
                        --primary ref_primary.wav --secondary ref_secondary.wav
                        [--overlap 0.25] [--batch-size 1] [--full-dir DIR]
"""
import argparse
import json
import logging
import os
import time

import numpy as np
import soundfile as sf


def manifest_entry(manifest_path, model_path):
    with open(manifest_path, encoding="utf-8") as f:
        man = json.load(f)
    name = os.path.basename(model_path)
    for e in man["files"]:
        if e["name"] == name:
            return e
    raise SystemExit(f"{name} not in manifest {manifest_path}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--in", dest="inp", required=True)
    ap.add_argument("--primary", required=True)
    ap.add_argument("--secondary", required=True)
    ap.add_argument("--overlap", type=float, default=0.25)
    ap.add_argument("--batch-size", type=int, default=1)
    ap.add_argument("--full-dir", default=None, help="also run stock separate() into this dir")
    args = ap.parse_args()

    import torch
    from audio_separator.separator.architectures.mdx_separator import MDXSeparator

    e = manifest_entry(args.manifest, args.model)
    model_data = {
        "compensate": e["compensate"],
        "mdx_dim_f_set": e["dim_f"],
        "mdx_dim_t_set": e["dim_t_log2"],
        "mdx_n_fft_scale_set": e["n_fft"],
        "primary_stem": e["primary_stem"],
    }
    logger = logging.getLogger("ref")
    logging.basicConfig(level=logging.INFO)
    common = {
        "logger": logger,
        "log_level": logging.INFO,
        "torch_device": torch.device("cpu"),
        "torch_device_cpu": torch.device("cpu"),
        "torch_device_mps": None,
        "onnx_execution_provider": ["CPUExecutionProvider"],
        "model_name": os.path.splitext(os.path.basename(args.model))[0],
        "model_path": args.model,
        "model_data": model_data,
        "output_dir": args.full_dir or os.path.dirname(os.path.abspath(args.primary)),
        "output_format": "WAV",
        "output_bitrate": None,
        "normalization_threshold": 1.0,
        "amplification_threshold": 0.0,
        "output_single_stem": None,
        "invert_using_spec": False,
        "sample_rate": 44100,
        "use_soundfile": True,
    }
    arch = {"segment_size": 256, "overlap": args.overlap, "batch_size": args.batch_size,
            "hop_length": e["hop_length"], "enable_denoise": False}
    sep = MDXSeparator(common, arch)

    mix = sep.prepare_mix(args.inp)              # [2, N] float32 @ 44.1 kHz (librosa)
    t0 = time.time()
    primary = sep.demix(mix)                     # [2, N]
    t1 = time.time()
    secondary = mix - primary * e["compensate"]
    print(f"demix: {t1 - t0:.1f}s for {mix.shape[1] / 44100:.1f}s audio, "
          f"primary stem = {e['primary_stem']}, compensate = {e['compensate']}")
    sf.write(args.primary, primary.T.astype(np.float32), 44100, subtype="FLOAT")
    sf.write(args.secondary, secondary.T.astype(np.float32), 44100, subtype="FLOAT")
    print("wrote", args.primary, args.secondary)

    if args.full_dir:
        os.makedirs(args.full_dir, exist_ok=True)
        files = sep.separate(args.inp)
        print("stock separate() wrote", files)


if __name__ == "__main__":
    main()
