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
for lineno, line in enumerate(open(PTSFILE), 1):
    s = line.strip().rstrip(",")
    if not s:
        continue
    try:
        pts.append(float(s))
    except ValueError:
        # Skipping the line would shift every later timestamp against its source frame
        # index, holding the wrong frames while still producing a plausible video.
        sys.exit(f"{PTSFILE}:{lineno}: cannot read {s!r} as a timestamp.")
pts = np.array(pts)
if pts.size < 2:
    sys.exit(f"{PTSFILE} holds {pts.size} timestamps - need at least 2")
if not np.all(np.isfinite(pts)):
    sys.exit(f"{PTSFILE} contains non-finite timestamps")
# i60.mp4 and the concat render both start at t=0, but a source with a non-zero first
# PTS would shift every stall boundary. No-op when already zero-based.
pts = pts - pts[0]
gaps = np.diff(pts)
# searchsorted below assumes sorted input, and finish.sh already requires this of the
# same file. Duplicate or decreasing timestamps would select the wrong interval and
# hold the wrong frames, silently.
if np.any(gaps <= 0):
    bad = int(np.argmax(gaps <= 0))
    sys.exit(f"{PTSFILE} is not strictly increasing at index {bad}: "
             f"{pts[bad]:.6f} -> {pts[bad + 1]:.6f}")
is_stall = gaps > (GAP_MS / 1000.0)
print(f"source {len(pts)} frames, {int(is_stall.sum())} stalls >{GAP_MS:.0f}ms, ease={EASE}")

ci = cv2.VideoCapture(INTERP)
cs = cv2.VideoCapture(SOURCE)
fps = ci.get(cv2.CAP_PROP_FPS)
w = int(ci.get(cv2.CAP_PROP_FRAME_WIDTH))
h = int(ci.get(cv2.CAP_PROP_FRAME_HEIGHT))
vw = cv2.VideoWriter(OUT, cv2.VideoWriter_fourcc(*"FFV1"), fps, (w, h))

# The source-cadence render is CFR with held frames repeated, so its frame indices are
# not source frame indices: a 267ms stall occupies four render frames. Work out where
# each source frame begins, so `cur` is the right image and `nxt` is the next REAL
# frame rather than another copy of the current one - the ease dissolves into it.
base_fps = cs.get(cv2.CAP_PROP_FPS) or 15.0
reps = [max(1, int(round(g * base_fps))) for g in gaps]
start = [0]
for r in reps:
    start.append(start[-1] + r)
starts_at = {v: j for j, v in enumerate(start)}

render_pos = -1   # index of the last render frame read (NOT the stall-relative
                  # `pos` used below - they are different things)
buf = {}          # source index -> frame; never holds more than the two in use
cur = nxt = None


def advance_to(i):
    """Make cur = source frame i and nxt = source frame i+1, reading forward only."""
    global render_pos, cur, nxt
    need = start[min(i + 1, len(start) - 1)]
    while render_pos < need:
        ok, f = cs.read()
        if not ok:
            break
        render_pos += 1
        j = starts_at.get(render_pos)
        if j is not None and j >= i:
            buf[j] = f
    for j in [j for j in buf if j < i]:
        del buf[j]
    cur, nxt = buf.get(i), buf.get(i + 1)


k = passed = held = eased = tail = 0
while True:
    ok, f_interp = ci.read()
    if not ok:
        break
    t = k / fps
    i = int(np.searchsorted(pts, t, side="right") - 1)

    # Past the final source timestamp there is no interval to be inside. Clamping back
    # into the last one drives `remain` negative, which pushes the ease weights outside
    # 0..1 and extrapolates instead of blending - a visibly wrong tail. Hold the final
    # frame instead.
    if i >= len(pts) - 1:
        advance_to(len(pts) - 1)
        vw.write(cur if cur is not None else f_interp)
        tail += 1
        k += 1
        continue

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
      f"{held} held ({100*held/max(k,1):.0f}%), {eased} eased ({100*eased/max(k,1):.0f}%), "
      f"{tail} past the last timestamp")
