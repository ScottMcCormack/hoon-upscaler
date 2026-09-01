"""
How abrupt is each stall exit, compared with ordinary motion in the same clip?

usage: stall_discontinuity.py <source.mp4> <variant.mp4> [variant2.mp4 ...]
  source     the original camera file - read only for its frame timestamps
  variant    one or more 60fps renders to compare

Six metrics were built during development to score perceptual artifacts and all six
failed; docs/findings.md records why. The common fault was going looking for an artifact
whose location was unknown, and finding sharpness instead - one correlated with sharpness
at r = 0.88, because speckle IS high-frequency content.

This one is anchored differently. A stall's exit time is known in advance, from the
source timestamps, so there is nothing to search for: the question is only whether the
frame-to-frame change AT that known instant is larger than the clip's own ordinary
motion. That is the "boundary alignment" class CLAUDE.md already records as reliable.

The null control is the part that makes it trustworthy, and it is not optional. A
max-over-window divided by a median is greater than 1 by construction, so a raw ratio
always looks like a finding. Comparing it against the same statistic computed at windows
placed anywhere else says whether the value is actually elevated. On the clip this was
built for, that control overturned the raw reading: a variant whose exits scored 1.44
looked defective until the null median came back at 1.42.

What it does NOT do: say whether a discontinuity is visible. A step twice the size of
ordinary motion may be imperceptible. Use this to find out whether there is anything to
look at, then look.
"""
import subprocess
import sys

import cv2
import numpy as np

FPS = 60.0          # the interpolated deliverable's rate
GAP_MS = 150.0      # what counts as a stall, matching pipeline/finish.sh
NULL_SAMPLES = 400


def timestamps(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "frame=pts_time", "-of", "csv=p=0", path],
        capture_output=True, text=True).stdout
    p = np.array([float(x.rstrip(",")) for x in out.split() if x.strip()])
    if p.size < 2:
        sys.exit(f"{path}: need at least 2 timestamps, found {p.size}")
    return p - p[0]


def frame_deltas(path):
    """Mean absolute luma change between consecutive frames."""
    cap = cv2.VideoCapture(path)
    if not cap.isOpened():
        sys.exit(f"cannot open {path}")
    prev, d = None, []
    while True:
        ok, fr = cap.read()
        if not ok:
            break
        g = cv2.cvtColor(fr, cv2.COLOR_BGR2GRAY).astype(np.float32)
        if prev is not None:
            d.append(float(np.mean(np.abs(g - prev))))
        prev = g
    cap.release()
    if not d:
        sys.exit(f"{path}: decoded no frames")
    return np.array(d)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__.strip())
    source, variants = sys.argv[1], sys.argv[2:]

    pts = timestamps(source)
    gaps = np.diff(pts)
    exits = [int(round(pts[i + 1] * FPS)) for i, g in enumerate(gaps) if g > GAP_MS / 1000.0]
    if not exits:
        sys.exit(f"{source}: no gaps over {GAP_MS:.0f}ms, so there are no stall exits to score")
    print(f"{len(exits)} stall exits, at output frames {exits}\n")

    rng = np.random.default_rng(0)
    print(f"{'variant':<28} {'baseline':>9} {'observed':>9} {'null med':>9} {'pctile':>7}")
    for path in variants:
        d = frame_deltas(path)
        near = np.zeros(len(d), bool)
        for e in exits:
            near[max(0, e - 6):min(len(d), e + 4)] = True
        if (~near).sum() < 50:
            sys.exit(f"{path}: too few frames away from stalls to form a baseline")

        baseline = float(np.median(d[~near]))
        def ratio(i):
            return float(d[max(0, i - 5):min(len(d), i + 3)].max()) / baseline

        observed = float(np.mean([ratio(e) for e in exits]))
        pool = [i for i in range(6, len(d) - 4) if not near[i]]
        null = np.array([ratio(i) for i in rng.choice(pool, min(NULL_SAMPLES, len(pool)), replace=False)])
        pctile = float((null < observed).mean() * 100)

        name = path.rsplit("/", 1)[-1]
        print(f"{name:<28} {baseline:9.4f} {observed:9.2f} {float(np.median(null)):9.2f} {pctile:6.0f}%")
        print(f"{'':<28} per-exit: {[round(ratio(e), 2) for e in exits]}")

    print("\nA percentile near 50 means stall exits are indistinguishable from ordinary\n"
          "motion - there is no discontinuity to fix. Well above 50 means they are more\n"
          "abrupt than the rest of the clip; well below means they are smoother.")


if __name__ == "__main__":
    main()
