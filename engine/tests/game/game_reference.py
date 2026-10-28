#!/usr/bin/env python3
"""Pure onnxruntime + numpy reference of the engine's GAME pipeline.

Mirrors engine/src/models/game.cpp + slicer.cpp (which in turn mirror openvpi/GAME
v1.0.3 inference/me_infer.py, inference/data.py, inference/callbacks.py and
inference/slicer2.py) and writes the same notes JSON:

    {"timestep": 0.01, "language": "zh", "model": "<basename of model dir>",
     "notes": [{"onset": .., "offset": .., "pitch": ..}, ...]}

usage:
    game_reference.py --model-dir DIR --in IN.wav --out NOTES.json [--language zh]
                      [--seg-threshold 0.2] [--seg-radius 0.02] [--t0 0] [--nsteps 8]
                      [--est-threshold 0.2] [--max-chunk-seconds 40]
                      [--slicer-threshold-db -40] [--slicer-min-length-ms 1000]
                      [--slicer-min-interval-ms 200] [--slicer-hop-ms 20]
                      [--slicer-max-sil-kept-ms 100] [--verbose]

The input WAV must already be mono/stereo at the model sample rate (44.1 kHz); use
ffmpeg to convert first. Stereo is averaged to mono. NOTE: the segmenter contains a
RandomUniformLike node, so two runs (or the engine vs. this script) are not
bit-identical; compare with compare.py (onset +-30 ms, pitch +-0.5 semitone).
"""
import argparse
import json
import os
import sys
import time

import numpy as np
import onnxruntime as ort
import soundfile as sf


# ---------------------------------------------------------------------------
# slicer2.py port (numpy). Kept structurally identical to the upstream file.
# ---------------------------------------------------------------------------

def get_rms(y, *, frame_length=2048, hop_length=512, pad_mode="constant"):
    padding = (int(frame_length // 2), int(frame_length // 2))
    y = np.pad(y, padding, mode=pad_mode)
    axis = -1
    out_strides = y.strides + tuple([y.strides[axis]])
    x_shape_trimmed = list(y.shape)
    x_shape_trimmed[axis] -= frame_length - 1
    out_shape = tuple(x_shape_trimmed) + tuple([frame_length])
    xw = np.lib.stride_tricks.as_strided(y, shape=out_shape, strides=out_strides)
    target_axis = axis - 1 if axis < 0 else axis + 1
    xw = np.moveaxis(xw, -1, target_axis)
    slices = [slice(None)] * xw.ndim
    slices[axis] = slice(0, None, hop_length)
    x = xw[tuple(slices)]
    power = np.mean(np.abs(x) ** 2, axis=-2, keepdims=True)
    return np.sqrt(power)


class Slicer:
    def __init__(self, sr, threshold=-40., min_length=5000, min_interval=300, hop_size=20, max_sil_kept=5000):
        if not min_length >= min_interval >= hop_size:
            raise ValueError("The following condition must be satisfied: min_length >= min_interval >= hop_size")
        if not max_sil_kept >= hop_size:
            raise ValueError("The following condition must be satisfied: max_sil_kept >= hop_size")
        min_interval = sr * min_interval / 1000
        self.sr = sr
        self.threshold = 10 ** (threshold / 20.)
        self.hop_size = round(sr * hop_size / 1000)
        self.win_size = min(round(min_interval), 4 * self.hop_size)
        self.min_length = round(sr * min_length / 1000 / self.hop_size)
        self.min_interval = round(min_interval / self.hop_size)
        self.max_sil_kept = round(sr * max_sil_kept / 1000 / self.hop_size)

    def _apply_slice(self, waveform, begin, end):
        # returns (begin_sample, end_sample) instead of the waveform copy
        return begin * self.hop_size, min(waveform.shape[0], end * self.hop_size)

    def slice(self, waveform):
        samples = waveform
        if (samples.shape[0] + self.hop_size - 1) // self.hop_size <= self.min_length:
            return [(0, waveform.shape[0])]
        rms_list = get_rms(y=samples, frame_length=self.win_size, hop_length=self.hop_size).squeeze(0)
        sil_tags = []
        silence_start = None
        clip_start = 0
        for i, rms in enumerate(rms_list):
            if rms < self.threshold:
                if silence_start is None:
                    silence_start = i
                continue
            if silence_start is None:
                continue
            is_leading_silence = silence_start == 0 and i > self.max_sil_kept
            need_slice_middle = i - silence_start >= self.min_interval and i - clip_start >= self.min_length
            if not is_leading_silence and not need_slice_middle:
                silence_start = None
                continue
            if i - silence_start <= self.max_sil_kept:
                pos = rms_list[silence_start: i + 1].argmin() + silence_start
                if silence_start == 0:
                    sil_tags.append((0, pos))
                else:
                    sil_tags.append((pos, pos))
                clip_start = pos
            elif i - silence_start <= self.max_sil_kept * 2:
                pos = rms_list[i - self.max_sil_kept: silence_start + self.max_sil_kept + 1].argmin()
                pos += i - self.max_sil_kept
                pos_l = rms_list[silence_start: silence_start + self.max_sil_kept + 1].argmin() + silence_start
                pos_r = rms_list[i - self.max_sil_kept: i + 1].argmin() + i - self.max_sil_kept
                if silence_start == 0:
                    sil_tags.append((0, pos_r))
                    clip_start = pos_r
                else:
                    sil_tags.append((min(pos_l, pos), max(pos_r, pos)))
                    clip_start = max(pos_r, pos)
            else:
                pos_l = rms_list[silence_start: silence_start + self.max_sil_kept + 1].argmin() + silence_start
                pos_r = rms_list[i - self.max_sil_kept: i + 1].argmin() + i - self.max_sil_kept
                if silence_start == 0:
                    sil_tags.append((0, pos_r))
                else:
                    sil_tags.append((pos_l, pos_r))
                clip_start = pos_r
            silence_start = None
        total_frames = rms_list.shape[0]
        if silence_start is not None and total_frames - silence_start >= self.min_interval:
            silence_end = min(total_frames, silence_start + self.max_sil_kept)
            pos = rms_list[silence_start: silence_end + 1].argmin() + silence_start
            sil_tags.append((pos, total_frames + 1))
        if len(sil_tags) == 0:
            return [(0, waveform.shape[0])]
        chunks = []
        if sil_tags[0][0] > 0:
            chunks.append(self._apply_slice(waveform, 0, sil_tags[0][0]))
        for i in range(len(sil_tags) - 1):
            chunks.append(self._apply_slice(waveform, sil_tags[i][1], sil_tags[i + 1][0]))
        if sil_tags[-1][1] < total_frames:
            chunks.append(self._apply_slice(waveform, sil_tags[-1][1], total_frames))
        return [(b, e) for b, e in chunks if e > b]


def split_long_slices(mono, slices, slicer, max_samples):
    """Same algorithm as ke::game::split_long_slices (slicer.cpp)."""
    out = []
    rms = None
    hop = slicer.hop_size
    for root in slices:
        stack = [root]
        while stack:
            b, e = stack.pop()
            n = e - b
            if n <= max_samples:
                if n > 0:
                    out.append((b, e))
                continue
            if rms is None:
                rms = get_rms(y=mono, frame_length=slicer.win_size, hop_length=hop).squeeze(0)
            lo = b + n // 4
            hi = e - n // 4
            f0 = (lo + hop - 1) // hop
            f1 = min(hi // hop, len(rms) - 1)
            if f1 >= f0 >= 0:
                best = int(rms[f0:f1 + 1].argmin()) + f0
                split = best * hop
            else:
                split = b + n // 2
            if split <= b or split >= e:
                split = b + n // 2
            stack.append((split, e))
            stack.append((b, split))
    return out


# ---------------------------------------------------------------------------
# model
# ---------------------------------------------------------------------------

class Game:
    def __init__(self, model_dir, verbose=False):
        with open(os.path.join(model_dir, "config.json"), "r", encoding="utf8") as f:
            self.config = json.load(f)
        self.samplerate = int(self.config["samplerate"])
        self.timestep = float(self.config["timestep"])
        self.languages = self.config.get("languages") or {}
        self.loop = bool(self.config.get("loop", True))
        self.name = os.path.basename(os.path.normpath(model_dir))
        so = ort.SessionOptions()
        so.log_severity_level = 3
        providers = ["CPUExecutionProvider"]
        t0 = time.time()
        self.encoder = ort.InferenceSession(os.path.join(model_dir, "encoder.onnx"), so, providers=providers)
        self.segmenter = ort.InferenceSession(os.path.join(model_dir, "segmenter.onnx"), so, providers=providers)
        self.estimator = ort.InferenceSession(os.path.join(model_dir, "estimator.onnx"), so, providers=providers)
        self.dur2bd = ort.InferenceSession(os.path.join(model_dir, "dur2bd.onnx"), so, providers=providers)
        self.bd2dur = ort.InferenceSession(os.path.join(model_dir, "bd2dur.onnx"), so, providers=providers)
        self.segmenter_inputs = {i.name for i in self.segmenter.get_inputs()}
        if verbose:
            print(f"[ref] loaded {self.name} in {time.time() - t0:.2f} s", file=sys.stderr)

    def language_id(self, name):
        if not name:
            return 0
        return int(self.languages.get(name, 0))

    def run_chunk(self, wav, offset, a, language_id):
        """wav: float32 [L] at samplerate. Returns list of (onset, offset, pitch) as floats."""
        n = wav.shape[0]
        length = np.float32(n / self.samplerate)
        waveform = wav.reshape(1, -1).astype(np.float32)
        x_seg, x_est, maskT = self.encoder.run(
            ["x_seg", "x_est", "maskT"], {"waveform": waveform, "duration": np.array([length], dtype=np.float32)})
        (known_boundaries,) = self.dur2bd.run(
            ["boundaries"], {"durations": np.array([[length]], dtype=np.float32), "maskT": maskT})
        boundaries = known_boundaries
        radius = round(a.seg_radius / self.timestep)
        if self.loop:
            step = (1 - a.t0) / a.nsteps
            ts = [a.t0 + i * step for i in range(a.nsteps)]
        else:
            ts = [0.0]
        for t in ts:
            feed = {
                "x_seg": x_seg,
                "language": np.array([language_id], dtype=np.int64),
                "known_boundaries": known_boundaries,
                "prev_boundaries": boundaries,
                "t": np.array([t], dtype=np.float32),
                "maskT": maskT,
                "threshold": np.array(a.seg_threshold, dtype=np.float32),
                "radius": np.array(radius, dtype=np.int64),
            }
            feed = {k: v for k, v in feed.items() if k in self.segmenter_inputs}
            (boundaries,) = self.segmenter.run(["boundaries"], feed)
        durations, maskN = self.bd2dur.run(["durations", "maskN"], {"boundaries": boundaries, "maskT": maskT})
        presence, scores = self.estimator.run(
            ["presence", "scores"],
            {"x_est": x_est, "boundaries": boundaries, "maskT": maskT, "maskN": maskN,
             "threshold": np.array(a.est_threshold, dtype=np.float32)})
        durations = durations[0].astype(np.float32)
        scores = scores[0].astype(np.float32)
        presence = presence[0]
        # SaveCombinedFileCallback.on_predict_batch_end (float32 tensor arithmetic)
        offset32 = np.float32(offset)
        cum = np.cumsum(durations, dtype=np.float32)
        note_onset = np.minimum(np.concatenate([[np.float32(0)], cum]).astype(np.float32)[:-1], length) + offset32
        note_offset = np.minimum(cum, length) + offset32
        notes = []
        for on, off, score, valid in zip(note_onset.tolist(), note_offset.tolist(), scores.tolist(), presence.tolist()):
            if off - on <= 0:
                continue
            if not valid:
                continue
            notes.append((on, off, score))
        return notes


def merge_notes(notes):
    """SaveCombinedFileCallback.save_file"""
    sorted_notes = [list(n) for n in sorted(notes, key=lambda x: (x[0], x[1], x[2]))]
    last_time = 0
    i = 0
    while i < len(sorted_notes):
        note = sorted_notes[i]
        note[0] = max(note[0], last_time)
        note[1] = max(note[1], note[0])
        if note[1] <= note[0]:
            sorted_notes.pop(i)
        else:
            last_time = note[1]
            i += 1
    return [tuple(n) for n in sorted_notes]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model-dir", required=True)
    ap.add_argument("--in", dest="inp", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--language", default="")
    ap.add_argument("--seg-threshold", type=float, default=0.2)
    ap.add_argument("--seg-radius", type=float, default=0.02, help="seconds")
    ap.add_argument("--t0", type=float, default=0.0)
    ap.add_argument("--nsteps", type=int, default=8)
    ap.add_argument("--est-threshold", type=float, default=0.2)
    ap.add_argument("--max-chunk-seconds", type=float, default=40.0)
    ap.add_argument("--slicer-threshold-db", type=float, default=-40.0)
    ap.add_argument("--slicer-min-length-ms", type=int, default=1000)
    ap.add_argument("--slicer-min-interval-ms", type=int, default=200)
    ap.add_argument("--slicer-hop-ms", type=int, default=20)
    ap.add_argument("--slicer-max-sil-kept-ms", type=int, default=100)
    ap.add_argument("--seed", type=int, default=None, help="onnxruntime global seed (RandomUniformLike)")
    ap.add_argument("--verbose", action="store_true")
    a = ap.parse_args()

    if a.seed is not None:
        ort.set_seed(a.seed)

    game = Game(a.model_dir, verbose=a.verbose)
    data, sr = sf.read(a.inp, dtype="float32", always_2d=True)
    mono = data.mean(axis=1).astype(np.float32) if data.shape[1] > 1 else data[:, 0]
    if sr != game.samplerate:
        sys.exit(f"input is {sr} Hz; convert to {game.samplerate} Hz first "
                 f"(ffmpeg -i in -ar {game.samplerate} -ac 1 out.wav)")
    language_id = game.language_id(a.language)
    if a.language and language_id == 0:
        print(f"[ref] warning: language '{a.language}' unknown to this model, using 0", file=sys.stderr)

    slicer = Slicer(sr=game.samplerate, threshold=a.slicer_threshold_db, min_length=a.slicer_min_length_ms,
                    min_interval=a.slicer_min_interval_ms, hop_size=a.slicer_hop_ms,
                    max_sil_kept=a.slicer_max_sil_kept_ms)
    slices = slicer.slice(mono)
    slices = split_long_slices(mono, slices, slicer, int(round(a.max_chunk_seconds * game.samplerate)))
    if a.verbose:
        print(f"[ref] {len(slices)} slice(s):", file=sys.stderr)
        for b, e in slices:
            print(f"[ref]   {b / sr:.3f} .. {e / sr:.3f} s", file=sys.stderr)

    t0 = time.time()
    notes = []
    for i, (b, e) in enumerate(slices):
        notes.extend(game.run_chunk(mono[b:e], b / game.samplerate, a, language_id))
        if a.verbose:
            print(f"[ref] slice {i + 1}/{len(slices)} done ({time.time() - t0:.1f} s)", file=sys.stderr)
    notes = merge_notes(notes)
    if a.verbose:
        print(f"[ref] {len(notes)} notes in {time.time() - t0:.2f} s", file=sys.stderr)

    out = {
        "timestep": game.timestep,
        "language": a.language,
        "model": game.name,
        "notes": [{"onset": on, "offset": off, "pitch": p} for on, off, p in notes],
    }
    with open(a.out, "w", encoding="utf8") as f:
        json.dump(out, f)
    print(f"wrote {a.out}: {len(notes)} notes")


if __name__ == "__main__":
    main()
