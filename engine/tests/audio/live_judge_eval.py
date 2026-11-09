#!/usr/bin/env python3
"""Replays real takes through the onset-only live judge (a port of
app/lib/state/live_judge.dart fed by tools/onset_eval.cpp) and compares each
note's live timing tier with the post-take rhythm judgement in score.json.

  python3 live_judge_eval.py <ke_onset_eval> <songs-dir>
"""
import bisect, json, os, subprocess, sys

SR = 48000
TIERS = ['perfect', 'great', 'good', 'miss']


def frames(tool, wav):
    pcm = subprocess.run(['ffmpeg', '-v', 'error', '-i', wav, '-ac', '1', '-ar', str(SR), '-f', 'f32le', '-'],
                         check=True, capture_output=True).stdout
    out = subprocess.run([tool, str(SR), '0.06', '-50', '0.06', 'frames'], input=pcm, check=True, capture_output=True).stdout
    return [(float(t), o == b'1', float(r)) for t, o, r in (l.split() for l in out.splitlines())]


def live_tiers(notes, w, fr, offset, floor):
    t = [f[0] + offset for f in fr]
    on = [t[i] for i, f in enumerate(fr) if f[1]]
    out = []
    for i, n in enumerate(notes):
        o = n['onset']
        lo = o - w['good']
        hi = o + w['good']
        if i > 0: lo = max(lo, (notes[i - 1]['onset'] + o) / 2)
        if i + 1 < len(notes): hi = min(hi, (o + notes[i + 1]['onset']) / 2)
        k = bisect.bisect_left(on, lo)
        if k < len(on) and on[k] <= hi:
            e = abs(on[k] - o)
            out.append('perfect' if e <= w['perfect'] + 1e-9 else 'great' if e <= w['great'] + 1e-9 else 'good')
            continue
        a, b = bisect.bisect_left(t, lo), bisect.bisect_right(t, max(hi, o))
        out.append(None if any(fr[j][2] >= floor for j in range(a, b)) else 'miss')
    return out


def main():
    tool, root = sys.argv[1:]
    same = near = judged = silent = total = 0
    for sid in sorted(os.listdir(root)):
        tk = os.path.join(root, sid, 'takes')
        nj = os.path.join(root, sid, 'notes.json')
        if not (os.path.isdir(tk) and os.path.exists(nj)):
            continue
        notes = json.load(open(nj))['notes']
        for take in sorted(os.listdir(tk)):
            d = os.path.join(tk, take)
            try:
                score = json.load(open(os.path.join(d, 'score.json')))
                side = json.load(open(os.path.join(d, 'take.wav.json')))
            except (OSError, ValueError):
                continue
            rh = score.get('rhythm') or {}
            if not rh.get('notes') or len(rh['notes']) and max(n['index'] for n in rh['notes']) >= len(notes):
                continue
            w = {k: rh['windows'][k + '_ms'] / 1000 for k in ('perfect', 'great', 'good')}
            offset = side.get('track_start_offset', 0) - side.get('latency', 0)
            floor = score.get('noise_gate_db') or -50
            live = live_tiers(notes, w, frames(tool, os.path.join(d, 'take.wav')), offset, floor)
            s = n_ = j_ = sl = 0
            for r in rh['notes']:
                post = r['onset']
                lv = live[r['index']]
                total += 1
                if lv is None:
                    sl += 1
                    continue
                j_ += 1
                s += lv == post
                n_ += abs(TIERS.index(lv) - TIERS.index(post)) <= 1
            same += s; near += n_; judged += j_; silent += sl
            print(f'{sid[:8]}/{take[:8]} notes={len(rh["notes"]):4d} popups={j_:4d} same={s / max(j_, 1):.2f} within1={n_ / max(j_, 1):.2f}')
    print(f'ALL notes={total} popups={judged} ({judged / total:.0%}) same tier={same / judged:.1%} within one tier={near / judged:.1%}')


if __name__ == '__main__':
    main()
