#!/usr/bin/env python3
"""Compares two GAME notes JSON files (engine output vs. Python reference).

Notes are matched one-to-one by onset (greedy, nearest onset within --onset-tol
seconds, default 0.030). For each matched pair the pitch difference is reported.

Pass criteria (see docs/ARCHITECTURE.md, GAME pipeline):
  * >= 95 % of reference notes have a match within 30 ms onset AND 0.5 semitone pitch
  * note counts differ by <= 5 %

usage: compare.py A.json B.json [--onset-tol 0.03] [--pitch-tol 0.5] [--count-tol 0.05]
Exit code 0 when the criteria pass, 1 otherwise.
"""
import argparse
import json
import sys


def load(path):
    with open(path, "r", encoding="utf8") as f:
        d = json.load(f)
    notes = [(float(n["onset"]), float(n["offset"]), float(n["pitch"])) for n in d["notes"]]
    return sorted(notes), d


def match(a, b, onset_tol):
    """Greedy one-to-one matching on onset: for each note in a (sorted) take the
    unmatched note in b with the closest onset within tolerance."""
    used = [False] * len(b)
    pairs = []
    j0 = 0
    for i, na in enumerate(a):
        best, best_d = -1, None
        # advance the lower bound
        while j0 < len(b) and (used[j0] or b[j0][0] < na[0] - onset_tol):
            j0 += 1
        j = j0
        while j < len(b) and b[j][0] <= na[0] + onset_tol:
            if not used[j]:
                d = abs(b[j][0] - na[0])
                if best_d is None or d < best_d:
                    best, best_d = j, d
            j += 1
        if best >= 0:
            used[best] = True
            pairs.append((i, best))
    return pairs


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("a", help="notes JSON (e.g. engine output)")
    ap.add_argument("b", help="notes JSON (e.g. Python reference)")
    ap.add_argument("--onset-tol", type=float, default=0.030)
    ap.add_argument("--pitch-tol", type=float, default=0.5)
    ap.add_argument("--count-tol", type=float, default=0.05)
    ap.add_argument("--min-match", type=float, default=0.95)
    ap.add_argument("--dump", action="store_true", help="print every unmatched / pitch-mismatched note")
    args = ap.parse_args()

    a, da = load(args.a)
    b, db = load(args.b)
    na, nb = len(a), len(b)
    print(f"A: {args.a}: {na} notes (model={da.get('model')}, language={da.get('language')!r})")
    print(f"B: {args.b}: {nb} notes (model={db.get('model')}, language={db.get('language')!r})")
    if na == 0 or nb == 0:
        print("FAIL: one of the files has no notes")
        sys.exit(1)

    pairs = match(a, b, args.onset_tol)
    onset_diffs = [abs(a[i][0] - b[j][0]) for i, j in pairs]
    offset_diffs = [abs(a[i][1] - b[j][1]) for i, j in pairs]
    pitch_diffs = [abs(a[i][2] - b[j][2]) for i, j in pairs]
    good = [(i, j) for (i, j), pd in zip(pairs, pitch_diffs) if pd <= args.pitch_tol]
    ref_n = max(na, nb)
    match_rate = len(good) / ref_n
    count_ratio = abs(na - nb) / ref_n

    def stats(x):
        if not x:
            return "n/a"
        xs = sorted(x)
        return (f"mean {sum(xs) / len(xs):.4f}  median {xs[len(xs) // 2]:.4f}  "
                f"p95 {xs[min(len(xs) - 1, int(0.95 * len(xs)))]:.4f}  max {xs[-1]:.4f}")

    print(f"matched by onset (<= {args.onset_tol * 1000:.0f} ms): {len(pairs)} / {ref_n}")
    print(f"matched by onset and pitch (<= {args.pitch_tol} st): {len(good)} / {ref_n}  = {match_rate * 100:.1f} %")
    print(f"note count difference: {abs(na - nb)} ({count_ratio * 100:.1f} %)")
    print(f"onset  |diff| s : {stats(onset_diffs)}")
    print(f"offset |diff| s : {stats(offset_diffs)}")
    print(f"pitch  |diff| st: {stats(pitch_diffs)}")
    if pitch_diffs:
        exact = sum(1 for d in pitch_diffs if d < 0.01)
        print(f"pitch identical (< 0.01 st): {exact} / {len(pairs)}")

    if args.dump:
        matched_a = {i for i, _ in pairs}
        matched_b = {j for _, j in pairs}
        for i, n in enumerate(a):
            if i not in matched_a:
                print(f"  A only : {n[0]:8.3f} {n[1]:8.3f} {n[2]:7.2f}")
        for j, n in enumerate(b):
            if j not in matched_b:
                print(f"  B only : {n[0]:8.3f} {n[1]:8.3f} {n[2]:7.2f}")
        for (i, j), pd in zip(pairs, pitch_diffs):
            if pd > args.pitch_tol:
                print(f"  pitch  : A {a[i][0]:8.3f} {a[i][2]:7.2f}  B {b[j][0]:8.3f} {b[j][2]:7.2f}  diff {pd:.2f}")

    ok = match_rate >= args.min_match and count_ratio <= args.count_tol
    print("PASS" if ok else "FAIL",
          f"(need match >= {args.min_match * 100:.0f} % and count diff <= {args.count_tol * 100:.0f} %)")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
