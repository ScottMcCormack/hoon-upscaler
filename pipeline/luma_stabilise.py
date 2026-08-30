"""
Temporal luma stabilisation - removes the camera's auto-exposure hunting.

The N90 had nothing stable to meter on (black tarmac, white smoke) so it kept
readjusting exposure. That shifts the whole frame's brightness slightly, frame to
frame. It is inherited from the source, but the grade's contrast boost amplifies
it ~19% and makes it visible on the large flat tarmac area.

Fix: measure each frame's overall level, compare against a smoothed trend, and
correct the difference. This is a GLOBAL level correction - it shifts brightness
only, so it cannot smear detail or alter geometry. Applied BEFORE grading so the
grade has nothing left to amplify.

usage: luma_stabilise.py <in.mp4> <out.mkv> [window] [strength]
  window   frames in the smoothing window (default 61, ~4s at 15fps)
  strength 0..1, how fully to correct toward the trend (default 1.0)
"""
import sys
import cv2
import numpy as np

if len(sys.argv) < 3:
    sys.exit(__doc__.strip())

IN, OUT = sys.argv[1], sys.argv[2]
WIN = int(sys.argv[3]) if len(sys.argv) > 3 else 61
STRENGTH = float(sys.argv[4]) if len(sys.argv) > 4 else 1.0

# ---- pass 1: measure each frame's level -------------------------------------
cap = cv2.VideoCapture(IN)
fps = cap.get(cv2.CAP_PROP_FPS)
w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
levels = []
while True:
    ok, f = cap.read()
    if not ok:
        break
    levels.append(float(cv2.cvtColor(f, cv2.COLOR_BGR2GRAY).mean()))
cap.release()
lv = np.array(levels)
n = len(lv)
print(f"{n} frames, {w}x{h} @ {fps:.2f}fps")

# ---- smoothed trend: what the exposure SHOULD have been ---------------------
# Moving average with edge padding, so genuine lighting changes still track
# through while frame-scale hunting is removed.
pad = WIN // 2
padded = np.pad(lv, pad, mode="edge")
kern = np.ones(WIN) / WIN
trend = np.convolve(padded, kern, mode="valid")[:n]

delta = trend - lv
print(f"level: mean {lv.mean():.2f}  correction: mean|d| {np.abs(delta).mean():.3f}  "
      f"max {np.abs(delta).max():.2f}")

# ---- pass 2: apply the correction -------------------------------------------
cap = cv2.VideoCapture(IN)
vw = cv2.VideoWriter(OUT, cv2.VideoWriter_fourcc(*"FFV1"), fps, (w, h))
i = 0
while True:
    ok, f = cap.read()
    if not ok:
        break
    adj = delta[i] * STRENGTH
    if abs(adj) > 0.01:
        # additive shift in luma; applied to all channels equally so colour is unchanged
        out = np.clip(f.astype(np.float32) + adj, 0, 255).astype(np.uint8)
    else:
        out = f
    vw.write(out)
    i += 1
cap.release()
vw.release()

# ---- report ------------------------------------------------------------------
corrected = lv + delta * STRENGTH
before = np.abs(np.diff(lv))
after = np.abs(np.diff(corrected))
print(f"frame-to-frame flicker: median {np.median(before):.3f} -> {np.median(after):.3f} "
      f"({100*(1-np.median(after)/np.median(before)):.0f}% reduction)")
print(f"                  p99  {np.percentile(before,99):.2f} -> {np.percentile(after,99):.2f}")
