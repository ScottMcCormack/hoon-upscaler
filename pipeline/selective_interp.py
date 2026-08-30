"""
Selective interpolation: smooth the good stretches, hold through the stalls.

The camera stalls for 2-4 frame periods about 3% of the time. Interpolating across
those gaps invents a lot of motion from nothing, which reads as warping/jumping.
Between normally-spaced frames (67ms) interpolation works well.

So: run a full 60fps interpolation, then wherever an output frame falls inside a
STALL, substitute the held source frame. Normal stretches stay smooth; stalls judder
as the original does, with no invented motion.

EASE: optionally cross-dissolve into the next real frame over the last N frames of a
stall, so it arrives rather than cuts. A dissolve is honest - it invents no motion,
it just softens the transition.

usage: selective_interp.py <interp60.mp4> <source.mp4> <pts.txt> <out.mkv> [gap_ms] [ease_frames]
"""
import sys
import cv2
import numpy as np

if len(sys.argv) < 5:
    sys.exit(__doc__.strip())

INTERP, SOURCE, PTSFILE, OUT = sys.argv[1:5]
GAP_MS = float(sys.argv[5]) if len(sys.argv) > 5 else 100.0
EASE = int(sys.argv[6]) if len(sys.argv) > 6 else 0

pts = []
for line in open(PTSFILE):
    s = line.strip().rstrip(",")
    if s:
        try:
            pts.append(float(s))
        except ValueError:
            pass
pts = np.array(pts)
gaps = np.diff(pts)
is_stall = gaps > (GAP_MS / 1000.0)
print(f"source {len(pts)} frames, {int(is_stall.sum())} stalls >{GAP_MS:.0f}ms, ease={EASE}")

ci = cv2.VideoCapture(INTERP)
cs = cv2.VideoCapture(SOURCE)
fps = ci.get(cv2.CAP_PROP_FPS)
w = int(ci.get(cv2.CAP_PROP_FRAME_WIDTH))
h = int(ci.get(cv2.CAP_PROP_FRAME_HEIGHT))
vw = cv2.VideoWriter(OUT, cv2.VideoWriter_fourcc(*"FFV1"), fps, (w, h))

# rolling two-frame source buffer: cur = frame i, nxt = frame i+1
cur_idx = -1
cur = nxt = None


def advance_to(i):
    """Make cur = source frame i, nxt = source frame i+1."""
    global cur_idx, cur, nxt
    while cur_idx < i:
        if nxt is None:
            ok, f = cs.read()
            if not ok:
                break
            cur = f
        else:
            cur = nxt
        ok, nxt = cs.read()
        if not ok:
            nxt = None
        cur_idx += 1


k = passed = held = eased = 0
while True:
    ok, f_interp = ci.read()
    if not ok:
        break
    t = k / fps
    i = int(np.searchsorted(pts, t, side="right") - 1)
    i = max(0, min(i, len(pts) - 2))
    advance_to(i)

    if is_stall[i] and cur is not None:
        # how far through this stall are we, in output frames?
        stall_out = max(1, int(round((pts[i + 1] - pts[i]) * fps)))
        pos = int(round((t - pts[i]) * fps))
        remain = stall_out - pos
        if EASE > 0 and remain <= EASE and nxt is not None:
            # dissolve into the next real frame over the final EASE frames
            a = (EASE - remain + 1) / (EASE + 1)
            vw.write(cv2.addWeighted(cur, 1 - a, nxt, a, 0))
            eased += 1
        else:
            vw.write(cur)
            held += 1
    else:
        vw.write(f_interp)
        passed += 1
    k += 1

ci.release(); cs.release(); vw.release()
print(f"{k} frames: {passed} interpolated ({100*passed/max(k,1):.0f}%), "
      f"{held} held ({100*held/max(k,1):.0f}%), {eased} eased ({100*eased/max(k,1):.0f}%)")
