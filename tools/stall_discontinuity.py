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


def edge_energy(path):
    """Mean gradient magnitude per frame - a sharpness proxy.

    Needed because frame-to-frame change alone cannot tell smooth continuity from
    ghosting. A cross-dissolve lowers the delta (it looks smoother) while overlaying
    two displaced copies of the scene, so a delta-only score rates the artifact as an
    improvement. Edge energy falls when frames are blended, so the two together
    separate the cases.
    """
    cap = cv2.VideoCapture(path)
    if not cap.isOpened():
        sys.exit(f"cannot open {path}")
    out = []
    while True:
        ok, fr = cap.read()
        if not ok:
            break
        g = cv2.cvtColor(fr, cv2.COLOR_BGR2GRAY).astype(np.float32)
        gx = cv2.Sobel(g, cv2.CV_32F, 1, 0, ksize=3)
        gy = cv2.Sobel(g, cv2.CV_32F, 0, 1, ksize=3)
        out.append(float(np.mean(np.sqrt(gx * gx + gy * gy))))
    cap.release()
    return np.array(out)


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
    print(f"{'variant':<28} {'baseline':>9} {'observed':>9} {'null med':>9} {'pctile':>7} "
          f"{'sharp@exit':>9}")
    for path in variants:
        d = frame_deltas(path)

        # Every exit must actually exist in this variant. A truncated render - the
        # pre-#3 output is exactly the thing someone would compare against - would
        # otherwise score a window that sits before the exit, or take max() of an empty
        # slice, and report a number as though it meant something.
        if len(d) <= max(exits):
            sys.exit(f"{path}: ends at frame {len(d)}, before the last stall exit at "
                     f"{max(exits)}. This variant is shorter than the source, so its "
                     f"exits cannot be scored against it - compare a full-length render.")

        near = np.zeros(len(d), bool)
        for e in exits:
            near[max(0, e - 6):min(len(d), e + 4)] = True
        if (~near).sum() < 50:
            sys.exit(f"{path}: too few frames away from stalls to form a baseline")

        baseline = float(np.median(d[~near]))
        if baseline <= 0:
            sys.exit(f"{path}: no ordinary motion away from the stalls (median frame change "
                     f"is {baseline}), so there is nothing to compare a stall exit against. "
                     f"This clip is too static for the measure to mean anything.")

        def ratio(i):
            return float(d[max(0, i - 5):min(len(d), i + 3)].max()) / baseline

        observed = float(np.mean([ratio(e) for e in exits]))

        # The null must be the SAME statistic as the observed value. Observed is a mean
        # over len(exits) windows; a distribution of single-window ratios has a wider
        # spread, so comparing against it understates how unusual the observation is.
        # Sample means of the same size instead.
        #
        # Candidates also need their whole window clear of a stall neighbourhood, not
        # just their centre - an eight-frame slice centred five frames away still
        # overlaps one.
        k = len(exits)
        pool = [i for i in range(6, len(d) - 4)
                if not near[max(0, i - 5):min(len(d), i + 3)].any()]
        if len(pool) < k:
            sys.exit(f"{path}: only {len(pool)} windows clear of a stall, need at least {k}")
        null = np.array([
            float(np.mean([ratio(i) for i in rng.choice(pool, k, replace=False)]))
            for _ in range(NULL_SAMPLES)
        ])
        pctile = float((null < observed).mean() * 100)

        # Sharpness at the exits against sharpness elsewhere. Below 1 means frames are
        # being blended there - smoother deltas bought with a ghost.
        e = edge_energy(path)
        at, away = np.zeros(len(e), bool), None
        for x in exits:
            at[max(0, x - 4):min(len(e), x + 1)] = True
        away = ~at
        sharp_ratio = float(np.mean(e[at]) / np.mean(e[away])) if away.sum() else float("nan")

        name = path.rsplit("/", 1)[-1]
        print(f"{name:<28} {baseline:9.4f} {observed:9.2f} {float(np.median(null)):9.2f} "
              f"{pctile:6.0f}% {sharp_ratio:8.3f}")
        print(f"{'':<28} per-exit: {[round(ratio(x), 2) for x in exits]}")

    print("\nabruptness percentile: near 50 means stall exits are indistinguishable from\n"
          "ordinary motion - nothing to fix. Well above 50 means more abrupt than the rest\n"
          "of the clip; well below means smoother.\n\n"
          "sharp@exit: edge energy at the exits over edge energy elsewhere. Below ~0.98\n"
          "means frames are being blended there, and a low abruptness percentile is then\n"
          "measuring a ghost rather than a graceful transition. Read the two together:\n"
          "smooth AND sharp is good; smooth AND soft is a dissolve smearing the picture.")


if __name__ == "__main__":
    main()
