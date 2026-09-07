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
SAMPLE_EVERY = 20          # frames - for CHOOSING a preset only, never for the guard
PINNED = 0.01              # >1% of pixels on a rail means that end needs help
UNREVIEWED = {"dark"}      # eye-approval pending; never auto-selected (see below)

# Each preset is a fixed curve. Do not tune these to hit a number.
#
# A preset listed in UNREVIEWED has not been checked by eye and is never chosen
# automatically: the measurement may say a clip needs it, but "which curve looks right" is
# the one question this project has established that measurement cannot answer. Selecting
# an unapproved look silently is how an unreviewed grade ends up baked into a master.
# Falling back to neutral is safe rather than good - it shapes the middle and leaves the
# rails alone, so it neither helps nor destroys.
#
# To promote one: render the comparison, look at it, and remove it from this set.
PRESETS = {
    # Content jammed against white. Pulls the bright band down off the ceiling and
    # stretches it, which is what brings tarmac texture back. Approved by eye on
    # MVI_0081 against three alternatives, 2026-09-06.
    "bright": "curves=all='0/0 0.5/0.49 0.78/0.72 0.90/0.85 1/0.99',eq=saturation=1.22",
    # Content jammed against black. Lifts the floor so shadow detail separates, and
    # leaves the top alone. NOT yet checked by eye, and therefore NOT auto-selected -
    # see UNREVIEWED below. No footage in this project currently reaches it.
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
    if not (w.isdigit() and h.strip().rstrip(",").isdigit()):
        raise SystemExit(
            f"!! {path}: could not read dimensions (ffprobe said {out!r}). "
            f"The file is missing, unreadable, or not a video.")
    return int(w), int(h.strip().rstrip(","))


def frame_count(path):
    """Frames the container DECLARES, for cross-checking what we actually decoded.

    nb_frames comes from the header and survives truncation; counting packets does not -
    a truncated file recounts to the number that happen to be left, which then agrees
    with however many decoded and the check proves nothing. Measured on a file cut by
    600 bytes: nb_frames 60, recounted packets 25. Same nb_frames-then-fallback shape
    that cloud/run_on_pod.sh uses on inference output.
    """
    def probe(args, key):
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "v:0", *args,
             "-show_entries", f"stream={key}", "-of", "csv=p=0", path],
            capture_output=True, text=True).stdout.strip().rstrip(",")
        return int(out) if out.isdigit() else 0
    return probe([], "nb_frames") or probe(["-count_packets"], "nb_read_packets")


def histogram(path, every=1):
    """256-bin luma histogram of a clip, streamed.

    Returns (counts, frames). Memory is constant in clip length: frames are consumed as
    they arrive and only the bin counts are kept. That is what makes scanning EVERY frame
    affordable - buffering a 1480-frame 1080p render would be ~3GB, on a machine whose
    docs already record the OOM killer taking processes out. Measured: 622MB for 300
    frames at 1080p, which extrapolates to 3.07GB for the real clip.

    `every=1` scans everything. Sampling is a speed knob for choosing a preset, never for
    the guard: a sampled check can step straight over a clipped shot shorter than its
    stride, which is precisely the destruction it exists to prevent.
    """
    import numpy as np
    w, h = dims(path)
    expected = frame_count(path)
    if every <= 1:
        vf = "format=gray"
        want = expected
    else:
        # -fps_mode passthrough matters: without it ffmpeg's default sync DUPLICATES the
        # selected frames back up to a constant rate, so `every=20` decoded ~70% of the
        # clip rather than 5% and the "speed knob" barely turned.
        vf = rf"select='not(mod(n\,{every}))',format=gray"
        want = (expected + every - 1) // every if expected else 0

    cmd = ["ffmpeg", "-v", "error", "-i", path, "-an", "-vf", vf]
    if every > 1:
        cmd += ["-fps_mode", "passthrough"]
    cmd += ["-f", "rawvideo", "-pix_fmt", "gray", "-"]

    # stderr goes to a file, never a pipe. A pipe deadlocks: this loop blocks reading
    # stdout, ffmpeg blocks writing a full stderr pipe nobody is draining, and neither
    # side can move. Reproduced on a densely corrupted file - 128KB of decode errors,
    # zero output frames, hung until killed.
    import tempfile
    with tempfile.TemporaryFile() as errf:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=errf)
        counts = np.zeros(256, dtype=np.int64)
        frame_bytes, frames, buf = w * h, 0, b""
        while True:
            chunk = proc.stdout.read(frame_bytes)
            if not chunk:
                break
            buf += chunk
            n = len(buf) // frame_bytes
            if n:
                whole, buf = buf[:n * frame_bytes], buf[n * frame_bytes:]
                counts += np.bincount(np.frombuffer(whole, dtype=np.uint8), minlength=256)
                frames += n
        proc.stdout.close()
        rc = proc.wait()
        errf.seek(0)
        err = errf.read().decode(errors="replace")

    if rc != 0:
        raise SystemExit(f"!! {path}: ffmpeg failed while measuring\n{err.strip()}")
    if frames == 0:
        raise SystemExit(f"!! {path}: decoded no frames to measure")

    # ffmpeg exits 0 after dropping frames it could not decode, so a truncated file
    # measures clean on whatever survived. CLAUDE.md already records this exact trap for
    # inference output: a crashed run left a plausible short file that only its duration
    # gave away. A guard that reports "verified" on half a clip is worse than no guard.
    if want and frames != want:
        raise SystemExit(
            f"!! {path}: decoded {frames} frames but the file claims {want}. "
            f"The file is truncated or failed to decode, and any measurement of it "
            f"describes only the part that survived.\n{err.strip()}")
    if buf:
        raise SystemExit(f"!! {path}: trailing {len(buf)} bytes, not a whole frame")
    return counts, frames


def _order_stat(cumsum, k):
    """Value at sorted index k, read out of the cumulative histogram."""
    import numpy as np
    return float(np.searchsorted(cumsum, k + 1, side="left"))


def _percentile(counts, total, pct):
    """Percentile matching numpy's default linear interpolation.

    Snapping to a bin edge instead - the obvious thing to do with a histogram - is not
    equivalent, and the difference reached 9 luma levels in testing. It matters because
    pick() branches on `p99 >= 250` and `p01 <= 2`: a clip measured at p99 241.09 by
    interpolation reads 250.00 when snapped, which silently changes the chosen preset.
    """
    import numpy as np
    cumsum = np.cumsum(counts)
    pos = pct / 100.0 * (total - 1)
    lo = int(np.floor(pos))
    hi = min(int(np.ceil(pos)), total - 1)
    v_lo = _order_stat(cumsum, lo)
    if hi == lo:
        return v_lo
    return v_lo + (pos - lo) * (_order_stat(cumsum, hi) - v_lo)


def summarise(counts):
    """Luma statistics from bin counts. Separate from stats() so the rail boundaries can
    be tested exactly, without a video file and an encoder in the way: 254 and 255 count
    as clipped, 0 and 1 as crushed, and an off-by-one either way went unnoticed by every
    test in the suite before this was extracted.
    """
    total = int(counts.sum())
    return {
        "mean": float(sum(i * c for i, c in enumerate(counts)) / total),
        "p01": _percentile(counts, total, 1),
        "p50": _percentile(counts, total, 50),
        "p99": _percentile(counts, total, 99),
        "clipped": float(int(counts[254:].sum()) / total),
        "crushed": float(int(counts[:2].sum()) / total),
    }


def stats(path, every=1):
    counts, _ = histogram(path, every)
    return summarise(counts)


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
    # every=1 on both sides. Sampling here would let a clipped shot shorter than the
    # stride pass unseen, and a guard that can step over the damage it checks for is
    # worse than none - it reports "verified".
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
        st = stats(path, SAMPLE_EVERY)
        st["preset"] = pick(st)
        print(json.dumps(st, indent=2))
    elif cmd == "pick":
        name = pick(stats(path, SAMPLE_EVERY))
        import os
        if name in UNREVIEWED and os.environ.get("GRADE_ALLOW_UNREVIEWED") != "1":
            print(f"!! measurement selected the '{name}' preset, which has not been checked "
                  f"by eye.\n"
                  f"   Falling back to 'neutral', which is safe but does nothing for this "
                  f"footage.\n"
                  f"   To use it anyway: GRADE_ALLOW_UNREVIEWED=1, or set GRADE explicitly.\n"
                  f"   To approve it: look at a render and remove '{name}' from UNREVIEWED "
                  f"in grade.py.", file=sys.stderr)
            name = "neutral"
        arg = sys.argv[3] if len(sys.argv) > 3 else ""
        if arg == "--name":
            print(name)
        elif arg == "--both":
            # Name then filter, so a caller needing both pays for one measurement.
            print(name)
            print(PRESETS[name])
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
