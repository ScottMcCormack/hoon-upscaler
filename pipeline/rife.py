"""
Neural frame interpolation (RIFE), for footage whose motion defeats minterpolate.

WHY THIS EXISTS

`minterpolate` searches for each block's motion within `search_param` pixels, default 32.
That was never sized against footage that pans. Measured per-frame block motion:

    N90 clip (minterpolate fine)      windowed  3.27% of frame width
    MVI_0081, Canon (glassy)          windowed  9.95% of frame width

Measured on the actual `_lumafix_14fps.mp4` renders finish.sh passes to recommend() - not
the raw sources, which read close but not identical (N90 2.96%, MVI_0081 11.65%). Camera
stalls become repeated, zero-motion frames after cadence-restore, which can pull a
windowed-max statistic either up or down depending on where in the clip the repeats land
relative to the fastest window; measuring what production actually thresholds is what
matters, not which direction any one clip happened to move. Both margins stay comfortable
either way - the discrepancy has not been observed to flip a decision on real footage.

The mechanism is occlusion, not the search window. At this speed roughly 8.4% of the frame
width is newly revealed each frame, and that content has no correspondence in the previous
frame to warp from - so block compensation stretches neighbours into it, and the result
reads as the frame flowing rather than moving. RIFE synthesises those regions instead of
warping into them.

The search window is the hypothesis this replaced, and it was tested and ruled out: at
`search_param` 250 the measurement says ZERO frames are beyond range and the output is
still glassy. Block motion above the 32px default is therefore a good *predictor* of the
failure - the two travel together, since both follow from fast panning - but it is not the
cause, which is why raising the range does not help. The threshold below selects on it as
a proxy, deliberately.

WHAT IT CANNOT FIX

The source frames carry baked-in motion blur - gradient energy along the motion direction
falls to ~0.52 of the perpendicular at speed. Showing a 66ms exposure at 16ms intervals is
a mismatch no interpolator removes. If output still looks wrong after this, the answer is
a lower output frame rate, not a better interpolator.

SETUP (not automated - it needs a CUDA torch and a model this repo will not vendor)

    python -m venv work/rife/venv
    work/rife/venv/bin/pip install torch torchvision --index-url \\
        https://download.pytorch.org/whl/cu130      # cu130 for Blackwell; see CLAUDE.md
    git clone https://github.com/hzwer/Practical-RIFE.git work/rife/Practical-RIFE
    cd work/rife/Practical-RIFE && git checkout <pin a revision>   # HEAD is mutable

    # Then install the model this pipeline was tested against: RIFE v4.25, whose train_log/
    # carries flownet.pkl plus RIFE_HDv3.py and IFNet_HDv3.py. The version matters - the
    # repo publishes several models with different inference signatures, and this code
    # calls RIFE_HDv3's. A different model may import cleanly and then behave differently,
    # or fail inside the flow blocks a long way from the cause.
    #   work/rife/Practical-RIFE/train_log/{flownet.pkl,RIFE_HDv3.py,IFNet_HDv3.py}

Point RIFE_HOME elsewhere if you put it somewhere else.

  rife.py measure <video>                         report motion and the recommendation
  rife.py recommend <video> [--explain]           the recommendation, optionally with why
  rife.py why                                     whether RIFE can run here, and if not why
  rife.py interpolate <in> <out> [target_fps] [scale]   interpolate to a target rate
"""
import os
import subprocess
import sys

# Above this windowed motion, minterpolate's output warps. Block motion is a PROXY here,
# not the cause - see the module docstring: the mechanism is occlusion on a fast pan, and
# fast panning is what makes block motion large. Selecting on the symptom is deliberate;
# the cause has no cheap direct measurement.
#
# Expressed as a FRACTION OF FRAME WIDTH, not in pixels. Block motion scales with
# resolution, so an absolute threshold means different things on different renders:
# measured on one six-second clip, the same footage gives
#
#     width  296  ->  37.6px      width 1024  ->  141.9px
#     width  640  ->  84.7px      width 1914  ->  229.0px
#
# a 6.1x spread in pixels against 1.3x as a fraction. With a 60px threshold that footage
# was judged "minterpolate" at width 440 and "rife" at width 520 - the same footage, a
# different answer, decided by the output size rather than by the motion. This pipeline
# renders at 720p or 1080p, so that was reachable, not theoretical.
#
# 6% sits between the two clips that calibrated it, measured on the full clips with the
# windowed statistic block_motion now uses (a single clip-wide p95 let a real, severe
# pan hide below the threshold whenever it was under ~5% of the clip's total length -
# see block_motion's docstring):
#     N90 clip (minterpolate fine)    2.96% windowed max, full 1480-frame clip
#     MVI_0081 (glassy)              11.65% windowed max, full 852-frame clip
# A 3.9x gap, wider than the un-windowed statistic's (1.94% to 5.58%, a 2.9x gap) gave -
# windowing raises the floor for a clip that is MOSTLY calm with brief fast passages,
# which is what MVI_0081 partly is, more than it raises a clip with sustained panning.
MOTION_THRESHOLD = 0.06

HERE = os.path.dirname(os.path.abspath(__file__))
# abspath() here, not just on the default: a relative RIFE_HOME override breaks in two
# different ways downstream, verified by direct reproduction rather than assumed. The
# probe in unavailable_reason() passes the venv python as a relative executable to
# subprocess.run(cwd=RIFE_REPO) - Python's documented behaviour is to resolve a relative
# executable against the CHILD's cwd, not the caller's, so it looked for
# RIFE_REPO/RIFE_REPO/venv/bin/python and failed with "No such file". interpolate()
# fails differently: sys.path.insert(0, RIFE_REPO) followed by os.chdir(RIFE_REPO) means
# the still-relative sys.path entry gets re-resolved against the POST-chdir cwd at
# import time, doubling the path the same way. Normalising once here, before either code
# path can see the raw value, removes both failure modes instead of patching each one.
RIFE_HOME = os.path.abspath(os.environ.get("RIFE_HOME", os.path.join(HERE, "..", "work", "rife")))
RIFE_REPO = os.path.join(RIFE_HOME, "Practical-RIFE")


def probe(path):
    # No check=True: grade.py's dims() carries the same fix with the trap written out -
    # check=True raises CalledProcessError before a clean message can run, so the
    # commonest bad input (a missing or non-video path) produced a raw traceback instead
    # of the SystemExit every other guard in this pipeline is tested against. Reproduced
    # here by accident while testing an unrelated change, which is how this was found.
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
         "stream=width,height,r_frame_rate,nb_read_packets", "-count_packets",
         "-of", "csv=p=0", path], capture_output=True, text=True).stdout.strip()
    parts = out.split(",")
    if len(parts) != 4 or not all(parts[:2] + [parts[3]]):
        raise SystemExit(
            f"!! {path}: could not read video info (ffprobe said {out!r}). "
            f"The file is missing, unreadable, or not a video.")
    w, h, rate, n = parts
    if not (w.isdigit() and h.isdigit() and n.isdigit()):
        raise SystemExit(
            f"!! {path}: could not read video info (ffprobe said {out!r}). "
            f"The file is missing, unreadable, or not a video.")
    num, _, den = rate.partition("/")
    return int(w), int(h), float(num) / float(den or 1), int(n)


def pad_to(scale):
    """
    Padding multiple for a given scale.

    NOT the network stride. The coarsest pyramid level is 16/scale, so a lower scale needs
    a coarser multiple - at scale 0.5 that is 256. Guessing 32 fails with a shape mismatch
    deep inside the flow blocks, nowhere near the padding, which is a long way to travel
    for a wrong constant.
    """
    if scale not in (0.25, 0.5, 1.0, 2.0, 4.0):
        raise SystemExit(f"!! scale must be one of 0.25/0.5/1.0/2.0/4.0, got {scale}")
    return max(128, int(128 / scale))


def block_motion(path, sample=None, window_s=1.0):
    """Windowed motion, as a FRACTION of frame width: the fastest ~window_s-second
    stretch in the clip, not a single global percentile over the whole thing.

    Normalised deliberately - see MOTION_THRESHOLD. The pixel figure is resolution
    dependent and this decision must not be.

    Per-BLOCK, not global camera displacement. On the N90 clip block motion exceeds
    global by 2.33x because the camera is near-static and the subject moves; deriving
    from global displacement there would under-size the search by more than half.

    WHY WINDOWED, NOT A SINGLE CLIP-WIDE p95. p95 over N per-frame values discards the
    top 5% by definition - fine when the fast stretch IS a big enough share of the clip,
    silent otherwise. A clip 4% panning at the same speed that correctly selects rife at
    12.5% measured 0.00% and picked minterpolate: the pan sat entirely inside the
    discarded top 5%, so it could not affect the statistic no matter how severe it was.
    Taking the mean within short windows and the MAX across windows instead means a
    window only has to be internally fast, never a minimum share of the whole clip - a
    single bad half-second registers the same whether the clip is 10 seconds or 10
    minutes long.
    """
    import cv2
    import numpy as np
    # Whole clip by default. The old default of 400 frames covered 27% of the N90 clip -
    # a clip that is static early and pans later could never influence the recommendation,
    # which is precisely the case this tool exists to catch. It is also not free of cost
    # to be wrong here and it is nearly free to be right: 1.1s against 0.5s on 1480 frames,
    # and the answer moved (1.86% -> 1.94%), so even the calibration clip was not
    # represented by its opening.
    cap = cv2.VideoCapture(path)
    fps = cap.get(cv2.CAP_PROP_FPS) or 15.0
    prev, vals, n, width = None, [], 0, 0
    while sample is None or n < sample:
        ok, f = cap.read()
        if not ok:
            break
        h, w = f.shape[:2]
        width = w
        small = cv2.resize(cv2.cvtColor(f, cv2.COLOR_BGR2GRAY), (w // 4, h // 4))
        if prev is not None:
            fl = cv2.calcOpticalFlowFarneback(prev, small, None, 0.5, 3, 15, 3, 5, 1.2, 0)
            vals.append(np.percentile(np.hypot(fl[..., 0], fl[..., 1]).ravel() * 4, 99))
        prev = small
        n += 1
    cap.release()
    if not vals:
        raise SystemExit(f"!! {path}: could not measure motion")
    if not width:
        raise SystemExit(f"!! {path}: frame width is zero, cannot normalise motion")
    arr = np.array(vals)
    win = max(1, int(round(window_s * fps)))
    if len(arr) <= win:
        # Shorter than one window - nothing to slide, the clip IS the window.
        return float(arr.mean()) / width
    # Half-window stride: a pan that straddles a window boundary still lands fully
    # inside at least one offset window, rather than being split and diluted in both.
    stride = max(1, win // 2)
    starts = range(0, len(arr) - win + 1, stride)
    worst = max(float(arr[i:i + win].mean()) for i in starts)
    return worst / width


def output_schedule(n_src, src_fps, target_fps=60.0):
    """The (source_index, fraction) pairs to synthesise, one per output frame.

    Pure and separable from the model on purpose. RIFE's output on synthetic test footage
    is not a reliable way to measure cadence - a textureless bar gives it nothing to
    estimate flow from - so what gets asserted is the schedule, which is the part this
    code decides. Even spacing here is what "no judder" means before the model is
    involved at all.
    """
    if n_src < 1 or src_fps <= 0 or target_fps <= 0:
        raise SystemExit(f"!! cannot schedule {n_src} frames at {src_fps}->{target_fps}fps")
    span = (n_src - 1) / src_fps
    n_out = int(round(span * target_fps)) + 1
    out = []
    for j in range(n_out):
        pos = j * src_fps / target_fps
        i = min(int(pos + 1e-9), n_src - 1)
        out.append((i, pos - i))
    return out


def unavailable_reason():
    """Why RIFE cannot run here, or None if it can.

    Three distinct failures, and they want different messages: files missing, a venv that
    cannot import what interpolate() imports, and a runtime that imports but cannot
    compute. The third is not hypothetical here - CLAUDE.md records that this machine's
    RTX 5060 Ti is Blackwell (sm_120) and that stock torch builds carry no kernels for it,
    so `import torch` succeeds and the first real op fails. A CPU-only box is the same
    shape: importable, and hours per clip rather than minutes.

    Checking it here rather than at inference is the whole point. Auto-selection commits
    to RIFE on the strength of this answer, and the fallback it is choosing between only
    exists before the expensive stage starts.
    """
    py = os.path.join(RIFE_HOME, "venv", "bin", "python")
    if not os.access(py, os.X_OK):
        return f"no executable interpreter at {py}"
    for fname in ("flownet.pkl", "RIFE_HDv3.py", "IFNet_HDv3.py"):
        f = os.path.join(RIFE_REPO, "train_log", fname)
        if not os.path.exists(f):
            return f"model file missing: {f}"
    probe_src = (
        "import sys; sys.path.insert(0, %r)\n"
        "import torch\n"
        "from train_log.RIFE_HDv3 import Model\n"
        "assert torch.cuda.is_available(), 'no CUDA device'\n"
        # A kernel launch, not just a device count. This is what distinguishes a usable
        # build from one that reports a device and has no kernels for its architecture.
        "torch.ones(8, device='cuda').sum().item()\n" % RIFE_REPO)
    try:
        p = subprocess.run([py, "-c", probe_src], cwd=RIFE_REPO,
                           capture_output=True, text=True, timeout=180)
    except (OSError, subprocess.SubprocessError) as e:
        return f"could not run {py}: {e}"
    if p.returncode != 0:
        last = (p.stderr or "").strip().splitlines()
        return f"venv cannot run the model: {last[-1] if last else 'unknown error'}"
    return None


def available():
    return unavailable_reason() is None


def interpolate(src, dst, target_fps=60.0, scale=1.0):
    import numpy as np
    import torch

    tmp = pad_to(scale)
    # Resolve BEFORE the chdir below. Practical-RIFE must be imported from its own
    # directory, and after chdir a relative src/dst resolves against that directory
    # instead of the caller's - which surfaced as an ffprobe CalledProcessError naming a
    # file that plainly exists, pointing nowhere near the actual problem.
    src, dst = os.path.abspath(src), os.path.abspath(dst)
    sys.path.insert(0, RIFE_REPO)
    os.chdir(RIFE_REPO)
    from train_log.RIFE_HDv3 import Model

    w, h, fps, n = probe(src)
    ph = ((h - 1) // tmp + 1) * tmp
    pw = ((w - 1) // tmp + 1) * tmp
    # Output times, not a whole-number multiple of the input. RIFE takes an arbitrary
    # timestep, so the frames can be synthesised AT the 60Hz instants rather than at
    # source-multiples that are then resampled to 60. Resampling was the defect: a 24fps
    # source x3 is 72fps, and `fps=60` on that advances motion in a mix of 1/72 and 2/72
    # steps, repeating some frames outright - measured 0/1/2-frame steps over one second.
    # Uniform container timestamps hid it; the motion itself juddered.
    sched = output_schedule(n, fps, target_fps)
    n_out = len(sched)
    print(f"    {w}x{h} @ {fps:g}fps, {n} frames -> {target_fps:g}fps, "
          f"{n_out} frames (pad {pw}x{ph}, scale {scale})")

    torch.set_grad_enabled(False)
    dev = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    if dev.type != "cuda":
        print("    !! no CUDA device - this will be extremely slow on CPU")
    model = Model()
    model.load_model("train_log", -1)
    model.eval()
    model.device()

    rd = subprocess.Popen(["ffmpeg", "-v", "error", "-i", src, "-f", "rawvideo",
                           "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
    # Lossless (crf 0), not crf 12: this file is an INTERMEDIATE that finish.sh
    # immediately re-encodes again (tpad/fps/trim, its own crf 12). The minterpolate path
    # is a single lossy generation; without this, the rife path was two - crf 12 here,
    # crf 12 again in finish.sh - so an eye comparison between `auto`-selected RIFE and
    # forced minterpolate confounded "which interpolator" with "how many times was this
    # re-encoded," the exact "more than the variable under test differs" trap CLAUDE.md
    # names as the cause of every prior wrong conclusion in this project. Larger on disk,
    # briefly, which is the cheaper resource here - not memory (streamed for that reason
    # already, see below) and not something that survives past finish.sh's next pass.
    wr = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt",
                           "rgb24", "-s", f"{w}x{h}", "-r", f"{target_fps:g}", "-i", "-",
                           "-c:v", "libx264", "-preset", "veryfast", "-crf", "0", "-pix_fmt",
                           "yuv420p", dst], stdin=subprocess.PIPE)
    fsz = w * h * 3

    def read():
        b = rd.stdout.read(fsz)
        return None if len(b) < fsz else np.frombuffer(b, np.uint8).reshape(h, w, 3)

    def to_t(a):
        t = torch.from_numpy(a.copy()).to(dev).permute(2, 0, 1)[None].float() / 255.0
        return torch.nn.functional.pad(t, (0, pw - w, 0, ph - h), mode="replicate")

    def emit(t):
        # An encoder that has already exited turns this write into BrokenPipeError, which
        # would surface as a traceback rather than as the stage-specific message the exit
        # code checks below produce. Same failure, so give it the same answer.
        try:
            wr.stdin.write((t[0, :, :h, :w].clamp(0, 1) * 255).byte()
                           .permute(1, 2, 0).cpu().numpy().tobytes())
        except BrokenPipeError:
            raise SystemExit(
                f"!! writing {dst} failed: the encoder exited while frames were still "
                f"being sent (ffmpeg's own error is above). Usually an unwritable path, "
                f"a full disk, or no encoder for the requested format.")

    # Streaming, deliberately. 852 input frames plus 3405 output at 1902x1080 is ~30GB
    # held at once, against 15GB of RAM (CLAUDE.md), so the whole-file approach meets the
    # OOM killer rather than finishing.
    prev = read()
    if prev is None:
        raise SystemExit("!! no frames decoded")
    t_prev = to_t(prev)

    # Walk the OUTPUT clock. For each 60Hz instant, find the source interval containing it
    # and ask the model for exactly that fraction. Source frames are reused as-is only
    # when an instant lands on one (fraction 0), which is what keeps 15fps->60fps
    # identical to the old multiple-of-4 behaviour.
    # t_prev is source frame `i`; t_cur is the lookahead for frame `i+1`, or None when it
    # has not been read yet. Advancing consumes the lookahead - an earlier version read a
    # frame into t_cur without counting it, so every later advance skipped one and the
    # output tracked the source at roughly double speed.
    i, t_cur = 0, None

    def ensure_cur():
        nonlocal t_cur
        if t_cur is None:
            nxt = read()
            t_cur = None if nxt is None else to_t(nxt)
        return t_cur

    for j, (want, frac) in enumerate(sched):
        while i < want:
            if ensure_cur() is None:
                break
            t_prev, t_cur, i = t_cur, None, i + 1
        if frac <= 1e-9:
            emit(t_prev)
        elif ensure_cur() is None:
            emit(t_prev)                      # past the last source frame; hold it
        else:
            emit(model.inference(t_prev, t_cur, frac, scale))
        if (j + 1) % 200 == 0:
            print(f"    {j+1}/{n_out}", flush=True)


    wr.stdin.close()
    rd.stdout.close()
    wr_rc = wr.wait()
    rd_rc = rd.wait()
    # Without this, a decoder or encoder failure surfaces later as "could not probe the
    # output", which points at the wrong thing entirely. Report the stage that failed.
    if rd_rc != 0:
        raise SystemExit(f"!! reading {src} failed (ffmpeg exit {rd_rc}) - "
                         f"unreadable input, or no decoder for it")
    if wr_rc != 0:
        raise SystemExit(f"!! writing {dst} failed (ffmpeg exit {wr_rc}) - "
                         f"no encoder, no space, or an unwritable path")

    got = probe(dst)[3]
    # A truncated interpolation still plays; only the frame count gives it away.
    if got != n_out:
        raise SystemExit(f"!! wrote {got} frames, expected {n_out}")
    print(f"    {got} frames")


def recommendation(m):
    """The decision itself, in one place. `measure` and `recommend` used to each spell
    out `"rife" if m > MOTION_THRESHOLD else "minterpolate"` independently - harmless
    while the comparison is one operator against one constant, but a future change (>=,
    a resolution-aware threshold) would have two call sites to update with nothing to
    say whether both were, and the two commands could silently disagree on the same clip.
    """
    return "rife" if m > MOTION_THRESHOLD else "minterpolate"


def main():
    # `why` is the one command that takes no argument, so the arity check cannot be a
    # single threshold — it printed the whole docstring instead of answering.
    if len(sys.argv) < 2 or (len(sys.argv) < 3 and sys.argv[1] != "why"):
        raise SystemExit(__doc__)
    cmd = sys.argv[1]
    if cmd == "measure":
        m = block_motion(sys.argv[2])
        rec = recommendation(m)
        print(f"block motion (windowed max): {100*m:.2f}% of width  "
              f"threshold {100*MOTION_THRESHOLD:.1f}%  -> {rec}")
    elif cmd == "recommend":
        m = block_motion(sys.argv[2])
        rec = recommendation(m)
        print(rec)
        # Second line only on request, so a caller needing the number for its log does not
        # pay for a second pass over the clip - which is now the WHOLE clip, making the
        # saving larger than when this was written against a 400-frame cap. Same shape as
        # grade.py --both.
        if len(sys.argv) > 3 and sys.argv[3] == "--explain":
            print(f"block motion (windowed max): {100*m:.2f}% of width, "
                  f"threshold {100*MOTION_THRESHOLD:.1f}%")
    elif cmd == "why":
        why = unavailable_reason()
        print(why or "available")
        sys.exit(0 if why is None else 1)
    elif cmd == "interpolate":
        if len(sys.argv) < 4:
            raise SystemExit("usage: rife.py interpolate <in> <out> [target_fps] [scale]")
        interpolate(sys.argv[2], sys.argv[3],
                    float(sys.argv[4]) if len(sys.argv) > 4 else 60.0,
                    float(sys.argv[5]) if len(sys.argv) > 5 else 1.0)
    else:
        raise SystemExit(f"unknown command '{cmd}'")


if __name__ == "__main__":
    main()
