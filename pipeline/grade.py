"""
Pick a grade for a clip from that clip's own luma distribution, and verify the result.

THE BUG THIS EXISTS TO PREVENT

`eq=contrast=N` expands contrast around a FIXED pivot of 128. That suits footage whose
content sits near 128 and destroys footage that does not:

    N90 night clip     mean 139.6    3.5% of the picture crushed to black
    Canon day clip     mean 208.1   51.8% of the picture clipped to white

51.8% is not a grading choice, it is deleting half of every frame. The tarmac sits at
230-245 and the grade maps it straight onto the ceiling, so every difference between
those values becomes the same white.

Dialling the constant down does not fix it. At mean 208 the tarmac is already within ~20
units of the ceiling, so even `contrast=1.06` still clipped 39.4%. There is no safe
value, because the pivot is wrong, not the gain.

WHAT THIS DOES, AND WHAT IT DELIBERATELY DOES NOT

It selects among a few hand-vetted presets using an objective measurement, and then
checks the result. It does NOT synthesise a curve per clip.

That restraint is deliberate. Synthesising one was tried: three successive versions,
each tuned to land closer to a curve that had already been approved by eye, each still
measurably worse than it (tarmac stdev 32.95, then 36.78, against the hand-tuned 39.03).
That is the shape of the six failed perceptual metrics in docs/findings.md — an
increasingly elaborate automatic thing chasing a target only an eye can call. So the
curves here are fixed and were each checked by eye; only the CHOICE between them is
automatic, and only clipping — which has an objective definition — is asserted.

  grade.py pick <video>                choose a preset, print its filter string
  grade.py measure <video>             print the luma stats behind the choice
  grade.py verify <ungraded> <graded>  fail if grading made clipping materially worse
"""
import json
import subprocess
import sys

TOLERANCE = 0.005          # graded may exceed ungraded clipping by this much, no more
SAMPLE_EVERY = 20          # frames
PINNED = 0.01              # >1% of pixels on a rail means that end needs help

# Each preset is a fixed, eye-checked curve. Do not tune these to hit a number.
PRESETS = {
    # Content jammed against white. Pulls the bright band down off the ceiling and
    # stretches it, which is what brings tarmac texture back. Approved by eye on
    # MVI_0081 against three alternatives, 2026-09-06.
    "bright": "curves=all='0/0 0.5/0.49 0.78/0.72 0.90/0.85 1/0.99',eq=saturation=1.22",
    # Content jammed against black. Lifts the floor so shadow detail separates, and
    # leaves the top alone. NOT yet checked by eye - see finish.sh, which will use it
    # only if you point it at dark footage.
    "dark": "curves=all='0/0.02 0.15/0.175 0.35/0.365 0.6/0.60 0.85/0.85 1/0.98',eq=saturation=1.18",
    # Neither end pinned: a mild lift in the middle, nothing near the rails.
    "neutral": "curves=all='0/0 0.25/0.24 0.5/0.51 0.75/0.77 1/1',eq=saturation=1.20",
}


def dims(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=width,height", "-of", "csv=p=0", path],
        capture_output=True, text=True, check=True).stdout.strip()
    w, _, h = out.partition(",")
    return int(w), int(h)


def luma(path):
    """Sampled luma plane of a clip, as a flat uint8 array."""
    import numpy as np
    w, h = dims(path)
    p = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", path, "-an",
         "-vf", rf"select='not(mod(n\,{SAMPLE_EVERY}))',format=gray",
         "-f", "rawvideo", "-pix_fmt", "gray", "-"],
        capture_output=True, check=True).stdout
    a = np.frombuffer(p, dtype=np.uint8)
    n = a.size // (w * h)
    if n == 0:
        raise SystemExit(f"!! {path}: decoded no frames to measure")
    return a[:n * w * h]


def stats(path):
    import numpy as np
    a = luma(path)
    return {
        "mean": float(a.mean()),
        "p01": float(np.percentile(a, 1)),
        "p50": float(np.percentile(a, 50)),
        "p99": float(np.percentile(a, 99)),
        "clipped": float((a >= 254).mean()),
        "crushed": float((a <= 1).mean()),
    }


def pick(st):
    """Which end, if any, is jammed against a rail."""
    top = st["clipped"] > PINNED or st["p99"] >= 250
    bot = st["crushed"] > PINNED or st["p01"] <= 2
    if top and not bot:
        return "bright"
    if bot and not top:
        return "dark"
    if top and bot:
        # Both rails occupied: the source spans more range than the display. Widening
        # either end costs the other, so shape the middle and leave both rails alone.
        return "neutral"
    return "neutral"


def verify(ungraded, graded):
    a, b = stats(ungraded), stats(graded)
    print(f"    ungraded: clipped {100*a['clipped']:.3f}%  crushed {100*a['crushed']:.3f}%")
    print(f"    graded:   clipped {100*b['clipped']:.3f}%  crushed {100*b['crushed']:.3f}%")
    bad = []
    if b["clipped"] > a["clipped"] + TOLERANCE:
        bad.append(f"clipping rose {100*a['clipped']:.2f}% -> {100*b['clipped']:.2f}%")
    if b["crushed"] > a["crushed"] + TOLERANCE:
        bad.append(f"crushing rose {100*a['crushed']:.2f}% -> {100*b['crushed']:.2f}%")
    if bad:
        raise SystemExit(
            "!! the grade is destroying picture, not shaping it: " + "; ".join(bad) +
            f"\n   (tolerance {100*TOLERANCE:.1f} points over the ungraded render). Pixels "
            f"pinned to a rail have lost the differences between them, and no later step "
            f"recovers that. Set GRADE explicitly, or let finish.sh pick one."
        )
    return 0


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    cmd, path = sys.argv[1], sys.argv[2]
    if cmd == "measure":
        st = stats(path)
        st["preset"] = pick(st)
        print(json.dumps(st, indent=2))
    elif cmd == "pick":
        name = pick(stats(path))
        if len(sys.argv) > 3 and sys.argv[3] == "--name":
            print(name)
        else:
            print(PRESETS[name])
    elif cmd == "verify":
        if len(sys.argv) < 4:
            raise SystemExit("usage: grade.py verify <ungraded> <graded>")
        sys.exit(verify(path, sys.argv[3]))
    else:
        raise SystemExit(f"unknown command '{cmd}'")


if __name__ == "__main__":
    main()
