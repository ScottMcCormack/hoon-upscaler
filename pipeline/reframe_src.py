"""
Rebuild the approved 'medium' reframe at SOURCE resolution.

The camera path was solved in the 1408x1152 upscaled space, so map it back through
the STABFIRST crop/scale to the 352x288 stabilised original. SeedVR2 then does the
only upscaling, instead of inheriting Real-ESRGAN's output.
"""
import json
import os
import sys
import cv2
import numpy as np

# usage: reframe_src.py [window_width] [tag]
#   860  = the 'medium' framing already approved
#   1150 = wider: more context, calmer camera, gentler upscale to 720p
WIN_W = int(sys.argv[1]) if len(sys.argv) > 1 else 860
TAG   = sys.argv[2] if len(sys.argv) > 2 else "tight"

DETS = os.environ.get("DETECTIONS", "detections.json")
SRC  = sys.argv[3] if len(sys.argv) > 3 else "stabilised.mp4"   # 352x288, stabilised
OUT  = os.environ.get("REFRAME_OUT", f"reframed_{TAG}.mp4")

# Camera solve happens in STABFIRST space (1408x1152) so framing matches TRACK_medium
WIN_H          = int(round(WIN_W / 16 * 9)) // 2 * 2
_s             = WIN_W / 860.0            # scale the deadzone with the window
DEAD_W, DEAD_H = 300 * _s, 170 * _s
EMA            = 0.15          # 'medium'
MAX_JUMP       = 350
FW, FH         = 1408, 1152

# STABFIRST was: fout(1408x1152) -> crop iw/1.12 (centred) -> scale back to 1408x1152
ZOOM = 1.12
CROP_OFF_X = (FW - FW / ZOOM) / 2
CROP_OFF_Y = (FH - FH / ZOOM) / 2
SCALE = 4.0                    # fout is 4x the 352x288 source


def stabfirst_to_src(X, Y):
    """Map a STABFIRST pixel back to stabilised-source coordinates."""
    fx = CROP_OFF_X + X / ZOOM
    fy = CROP_OFF_Y + Y / ZOOM
    return fx / SCALE, fy / SCALE


def pick_subject(dets, n):
    chosen, last = {}, None
    for i in range(n):
        cands = dets.get(str(i), [])
        if not cands:
            continue
        if last is None:
            best = max(cands, key=lambda d: d["conf"])
        else:
            scored = [(np.hypot(d["cx"] - last[0], d["cy"] - last[1]), d)
                      for d in cands
                      if np.hypot(d["cx"] - last[0], d["cy"] - last[1]) <= MAX_JUMP]
            if not scored:
                continue
            best = min(scored, key=lambda t: t[0])[1]
        chosen[i] = (best["cx"], best["cy"])
        last = chosen[i]
    return chosen


def fill_gaps(chosen, n):
    keys = sorted(chosen)
    out = {}
    for i in range(n):
        if i in chosen:
            out[i] = chosen[i]
            continue
        prev = [k for k in keys if k < i]
        nxt = [k for k in keys if k > i]
        if prev and nxt:
            a, b = prev[-1], nxt[0]
            t = (i - a) / (b - a)
            out[i] = (chosen[a][0] + t * (chosen[b][0] - chosen[a][0]),
                      chosen[a][1] + t * (chosen[b][1] - chosen[a][1]))
        else:
            out[i] = chosen[prev[-1]] if prev else chosen[nxt[0]]
    return out


def camera_path(subj, n):
    camx, camy = subj[0]
    path = {}
    for i in range(n):
        sx, sy = subj[i]
        dx, dy = sx - camx, sy - camy
        tx, ty = camx, camy
        if abs(dx) > DEAD_W / 2:
            tx = sx - np.sign(dx) * DEAD_W / 2
        if abs(dy) > DEAD_H / 2:
            ty = sy - np.sign(dy) * DEAD_H / 2
        camx += (tx - camx) * EMA
        camy += (ty - camy) * EMA
        camx = float(np.clip(camx, WIN_W / 2, FW - WIN_W / 2))
        camy = float(np.clip(camy, WIN_H / 2, FH - WIN_H / 2))
        path[i] = (camx, camy)
    return path


def main():
    dets = json.load(open(DETS))
    meta = dets.pop("_meta", None)
    if meta is None:
        print(f"    WARNING: {DETS} records no coordinate space; assuming {FW}x{FH}")
    elif (meta["width"], meta["height"]) != (FW, FH):
        sys.exit(f"detections are in {meta['width']}x{meta['height']} space but the camera "
                 f"solve expects STABFIRST ({FW}x{FH}). Re-run detect_car.py against the "
                 f"STABFIRST-space video.")
    cap = cv2.VideoCapture(SRC)
    n = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    sw = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    sh = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    fps = cap.get(cv2.CAP_PROP_FPS)
    print(f"stabilised source {sw}x{sh}, {n} frames")

    chosen = pick_subject(dets, n)
    if not chosen:
        sys.exit(f"no vehicle detected in any of {n} frames — nothing to track. Check "
                 f"{DETS} was generated from the right video, and that the subject is "
                 f"actually visible in it.")
    path = camera_path(fill_gaps(chosen, n), n)

    # Window size in source pixels, forced even for the encoder
    cw = int(round(WIN_W / ZOOM / SCALE)) // 2 * 2
    ch = int(round(WIN_H / ZOOM / SCALE)) // 2 * 2
    print(f"source-space window: {cw}x{ch}  ->  720p is {720/ch:.2f}x")

    # Write PNGs, not a lossy VideoWriter - this feeds a restoration model.
    from pathlib import Path
    fdir = Path(os.environ.get("FRAMES_DIR", f"frames_{TAG}"))
    fdir.mkdir(parents=True, exist_ok=True)
    for old in fdir.glob("f_*.png"):        # only what this script writes
        old.unlink()

    written = 0
    for i in range(n):
        ok, frame = cap.read()
        if not ok:
            break
        cx, cy = stabfirst_to_src(*path[i])
        x0 = int(round(cx - cw / 2))
        y0 = int(round(cy - ch / 2))
        x0 = max(0, min(x0, sw - cw))
        y0 = max(0, min(y0, sh - ch))
        crop = frame[y0:y0 + ch, x0:x0 + cw]
        if crop.shape[:2] != (ch, cw):
            continue
        cv2.imwrite(str(fdir / f"f_{written:06d}.png"), crop)
        written += 1

    cap.release()
    print(f"wrote {written} lossless frames to {fdir}")


if __name__ == "__main__":
    main()
