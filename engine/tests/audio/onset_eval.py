#!/usr/bin/env python3
"""Compares the live onset detector (tools/onset_eval.cpp) with GAME note
onsets on each song's separated vocal, to tune src/dsp/onset.cpp.

  python3 onset_eval.py <ke_onset_eval> <songs-dir> [delta floor_db combine_s]

Per song: recall (notes with a detected onset within +-TOL), recall of notes
that start after a rest, precision (detections near some note onset), and the
median signed error (detected - note) of the matches.
"""
import bisect, json, os, statistics, subprocess, sys

TOL = 0.12
SR = 48000


def detect(tool, wav, extra):
    pcm = subprocess.run(['ffmpeg', '-v', 'error', '-i', wav, '-ac', '1', '-ar', str(SR), '-f', 'f32le', '-'],
                         check=True, capture_output=True).stdout
    out = subprocess.run([tool, str(SR), *extra], input=pcm, check=True, capture_output=True).stdout
    return [float(x) for x in out.split()]


def nearest(sorted_vals, t):
    i = bisect.bisect_left(sorted_vals, t)
    best = None
    for j in (i - 1, i):
        if 0 <= j < len(sorted_vals) and (best is None or abs(sorted_vals[j] - t) < abs(best - t)):
            best = sorted_vals[j]
    return best


def main():
    tool, root, *extra = sys.argv[1:]
    tot = dict(n=0, hit=0, rn=0, rhit=0, d=0, dhit=0)
    errs_all = []
    for sid in sorted(os.listdir(root)):
        d = os.path.join(root, sid)
        wav, nj = os.path.join(d, 'vocals.wav'), os.path.join(d, 'notes.json')
        if not (os.path.exists(wav) and os.path.exists(nj)):
            continue
        notes = json.load(open(nj))['notes']
        onsets = [n['onset'] for n in notes]
        rest = [i == 0 or n['onset'] - notes[i - 1]['offset'] > 0.05 for i, n in enumerate(notes)]
        det = detect(tool, wav, extra)
        errs, hit, rhit = [], 0, 0
        for i, t in enumerate(onsets):
            m = nearest(det, t)
            if m is not None and abs(m - t) <= TOL:
                hit += 1
                rhit += rest[i]
                errs.append(m - t)
        dhit = sum(1 for t in det if (m := nearest(onsets, t)) is not None and abs(m - t) <= TOL)
        rn = sum(rest)
        med = statistics.median(errs) * 1000 if errs else float('nan')
        print(f'{sid[:8]} notes={len(onsets):4d} recall={hit/len(onsets):.2f} rest-recall={rhit/max(rn,1):.2f} '
              f'precision={dhit/max(len(det),1):.2f} median-err={med:+.0f}ms det={len(det)}')
        tot['n'] += len(onsets); tot['hit'] += hit; tot['rn'] += rn; tot['rhit'] += rhit
        tot['d'] += len(det); tot['dhit'] += dhit
        errs_all += errs
    if tot['n']:
        q = statistics.quantiles([e * 1000 for e in errs_all], n=4)
        print(f'ALL recall={tot["hit"]/tot["n"]:.3f} rest-recall={tot["rhit"]/tot["rn"]:.3f} '
              f'precision={tot["dhit"]/tot["d"]:.3f} err q1/med/q3={q[0]:+.0f}/{q[1]:+.0f}/{q[2]:+.0f}ms')


if __name__ == '__main__':
    main()
