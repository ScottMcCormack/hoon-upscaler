"""
Neural frame interpolation (RIFE), for footage whose motion defeats minterpolate.

WHY THIS EXISTS

`minterpolate` searches for each block's motion within `search_param` pixels, default 32.
That was never sized against footage that pans. Measured per-frame block motion:

    N90 clip (minterpolate fine)      windowed  3.36% of frame width
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
  rife.py interpolate <in> <out> [target_fps] [scale] [--no-audio]
                                                         interpolate to a target rate.
                                                         <in>'s audio is muxed into <out>
                                                         by default (re-encoded to AAC if
                                                         the container refuses a straight
                                                         copy) - pass --no-audio to skip
                                                         that, e.g. when a caller re-encodes
                                                         <out> itself and drops audio anyway.
                                                         <in> MUST be constant frame rate -
                                                         output_schedule() assumes uniform
                                                         spacing from probe()'s nominal fps
                                                         alone. finish.sh already restores
                                                         cadence to CFR before this runs; a
                                                         direct caller with genuinely VFR
                                                         input will get flattened timing.
"""
import math
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
# 6% sits between the two clips that calibrated it, measured on the actual
# `_lumafix_14fps.mp4` renders finish.sh passes to recommend() - not the raw source,
# which reads close but not identical (see the module docstring) - with the windowed
# statistic block_motion now uses (a single clip-wide p95 let a real, severe pan hide
# below the threshold whenever it was under ~5% of the clip's total length - see
# block_motion's docstring):
#     N90 clip (minterpolate fine)    3.36% windowed max, full 1556-frame render
#     MVI_0081 (glassy)               9.95% windowed max, full 852-frame render
# A 3.0x gap, wider than the un-windowed statistic's on the same renders (2.12% to
# 5.28%, a 2.5x gap) - windowing raises the floor for a clip that is MOSTLY calm with
# brief fast passages, which is what MVI_0081 partly is, more than it raises a clip
# with sustained panning.
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
#
# `.get("RIFE_HOME", default)` only falls back when the key is ABSENT - RIFE_HOME=""
# would resolve here to abspath("") (the cwd at import time), while finish.sh's
# `${RIFE_HOME:-default}` treats that same empty value as unset and falls back to the
# default path. The two sides of the pipeline would then probe and run two different
# installations. `or` falls back on any falsy value, matching bash's `:-` instead.
RIFE_HOME = os.path.abspath(os.environ.get("RIFE_HOME") or os.path.join(HERE, "..", "work", "rife"))
RIFE_REPO = os.path.join(RIFE_HOME, "Practical-RIFE")


def probe(path):
    # No check=True: grade.py's dims() carries the same fix with the trap written out -
    # check=True raises CalledProcessError before a clean message can run, so the
    # commonest bad input (a missing or non-video path) produced a raw traceback instead
    # of the SystemExit every other guard in this pipeline is tested against. Reproduced
    # here by accident while testing an unrelated change, which is how this was found.
    #
    # -count_frames/nb_read_frames, not -count_packets/nb_read_packets: this count feeds
    # output_schedule() directly, and a packet is not guaranteed to be a decoded frame -
    # ffmpeg does not promise a 1:1 mapping, so a container or codec that packs multiple
    # frames into one packet (or splits one across several) would build the wrong
    # schedule against a count interpolate()'s own decoder disagrees with, then either
    # hold early or try to read past what the decoder actually produces. Every codec
    # this pipeline's own encodes use (libx264, libx264rgb) matched 1:1 when checked
    # directly, but a standalone caller can point this at anything.
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
         "stream=width,height,r_frame_rate,nb_read_frames", "-count_frames",
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
    return windowed_max_mean(arr, win) / width


def windowed_max_mean(arr, win):
    """The highest mean of any length-`win` contiguous slice of `arr`.

    Pulled out of block_motion() as its own pure function so this can be tested against
    plain arrays - no video, no OpenCV, no optical flow - the same reasoning that already
    applies to output_schedule().

    EVERY possible window start is checked, not a stride-sampled subset. A half-window
    stride (the previous approach) still leaves gaps a pan can fall into: with win=15 and
    stride=7, a 15-sample pan starting at an array index 3 or 4 past a multiple of 7 is
    only ever seen by the two windows straddling it, and BOTH dilute it with samples from
    outside the pan - proven directly (not just plausible) by checking every possible
    start against the strided subset on a synthetic array built to land exactly on that
    offset: the strided approach's best answer is real, but demonstrably not the best
    ANY window achieves. A dedicated fix for the clip's tail (always trying the last
    possible start) caught the specific case where the strided grid runs out of clip
    before it runs out of stride, but the same dilution can happen at ANY interior offset
    the grid skips over - fixing it only at the tail was the "standard applied once" trap
    CLAUDE.md names. A cumulative-sum sliding mean costs the same O(n) the strided version
    did and checks literally every start, so there is no grid left to fall between.
    """
    import numpy as np
    if len(arr) <= win:
        # Shorter than one window - nothing to slide, the clip IS the window.
        return float(arr.mean())
    cumsum = np.cumsum(np.insert(arr, 0, 0.0))
    window_sums = cumsum[win:] - cumsum[:-win]
    return float(window_sums.max()) / win


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
    # Downsampling (target < source) is refused, not attempted. A lower target means the
    # schedule does not need every source frame - `want` can skip some entirely - and the
    # ones it skips are never read from interpolate()'s decoder. Closing that decoder's
    # stdout before it finishes writing makes ffmpeg exit on a broken pipe (reproduced
    # directly), which is then reported as "unreadable input" for what was actually a
    # perfectly good decode. This tool only interpolates UP to a higher rate anyway -
    # finish.sh always targets 60fps from a source at or below it - so this never bites
    # the pipeline, only a standalone caller asking for a rate the tool was never built
    # to produce.
    if target_fps < src_fps:
        raise SystemExit(
            f"!! cannot schedule {src_fps}->{target_fps}fps: this only interpolates UP "
            f"to a higher rate, not down to a lower one")
    # The full playback duration, not the position of the last frame's START. n_src frames
    # at src_fps each occupy 1/src_fps seconds, so the clip runs n_src/src_fps seconds in
    # total - (n_src-1)/src_fps stops one frame-duration short of that, at the moment the
    # last frame BEGINS rather than the moment it ENDS. finish.sh's own tpad/trim step masks
    # the shortfall for the one caller that has it (it pads to a duration computed
    # independently, from the real source's timestamps), but the standalone, documented
    # `rife.py interpolate <in> <out>` CLI has no such step: reproduced directly, one real
    # second of 15fps source (15 frames) used to emit 57 output frames at 60fps (0.95s),
    # not the 60 (1.0s) a caller publishing that file straight would expect - a visibly
    # clipped ending, 50ms short, on every direct (non-finish.sh) use.
    span = n_src / src_fps
    # Ceiling, not round(): round() can land BELOW the target instead of at or past it -
    # this was true of the old (n_src-1)-based span too (see the regression test below for
    # a concrete case), and a small tolerance keeps an exact multiple from gaining a
    # spurious extra frame to floating-point noise.
    n_out = int(math.ceil(span * target_fps - 1e-9))
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


def interpolate(src, dst, target_fps=60.0, scale=1.0, with_audio=True):
    tmp = pad_to(scale)
    # Resolve BEFORE the chdir below. Practical-RIFE must be imported from its own
    # directory, and after chdir a relative src/dst resolves against that directory
    # instead of the caller's - which surfaced as an ffprobe CalledProcessError naming a
    # file that plainly exists, pointing nowhere near the actual problem.
    src, dst = os.path.abspath(src), os.path.abspath(dst)
    # Written under a temp name and moved into place only after the frame count is
    # verified, not opened directly on dst - a model exception, a decoder failure, or a
    # short count would otherwise leave a plausible partial file at the path a caller is
    # about to publish, which is exactly the failure the count check two lines below
    # exists to catch, just one step too late.
    #
    # The marker goes BEFORE the extension, not after: dst + ".partial" turns
    # "i60_raw.mp4" into "i60_raw.mp4.partial", and ffmpeg's output muxer is inferred
    # from the extension when none is given explicitly - reproduced directly, it refuses
    # that path with "Unable to find a suitable output format" before writing a single
    # frame. Splitting first keeps a real, recognised video extension on the temp file.
    root, ext = os.path.splitext(dst)
    dst_tmp = f"{root}.partial{ext}"

    # Probed before torch or the model are imported - a missing or unreadable src is a
    # cheap, common mistake that should fail with probe()'s own clean message, not pay
    # for (and on a box with no torch installed at all, be masked entirely by) a torch
    # import first.
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

    import numpy as np
    import torch
    sys.path.insert(0, RIFE_REPO)
    os.chdir(RIFE_REPO)
    from train_log.RIFE_HDv3 import Model
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
    #
    # libx264rgb, not libx264 with -pix_fmt yuv420p: crf 0 only makes the ENCODE step
    # lossless relative to whatever pixel format it is handed, and yuv420p permanently
    # subsamples chroma to a quarter of luma's resolution before that encode ever runs -
    # measured directly: a yuv420p/crf-0 roundtrip of a test frame differs from the RGB
    # source by up to 37/255 (mean 2.5), while an RGB-native (libx264rgb) roundtrip is
    # bit-exact. libx264rgb keeps the model's own rgb24 output all the way through, which
    # is the actual lossless intermediate this comment always claimed to produce.
    wr = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt",
                           "rgb24", "-s", f"{w}x{h}", "-r", f"{target_fps:g}", "-i", "-",
                           "-c:v", "libx264rgb", "-preset", "veryfast", "-crf", "0",
                           dst_tmp], stdin=subprocess.PIPE)
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
                f"!! writing {dst_tmp} failed: the encoder exited while frames were still "
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
        raise SystemExit(f"!! writing {dst_tmp} failed (ffmpeg exit {wr_rc}) - "
                         f"no encoder, no space, or an unwritable path")

    got = probe(dst_tmp)[3]
    # A truncated interpolation still plays; only the frame count gives it away.
    if got != n_out:
        raise SystemExit(f"!! wrote {got} frames, expected {n_out}")
    if with_audio:
        publish_with_audio(dst_tmp, src, dst)
    else:
        # finish.sh's own next step re-encodes with -an, discarding audio outright, so
        # muxing it in here would stream-copy this whole (large, lossless) intermediate
        # to a second temp file purely to attach a track nobody downstream reads -
        # doubling peak disk use and I/O for nothing. with_audio=True stays the default
        # for the documented standalone CLI, which has no such downstream step.
        os.replace(dst_tmp, dst)
    print(f"    {got} frames")


def publish_with_audio(video_tmp, src, dst):
    """Move video_tmp to dst, muxing in src's audio when it has any.

    A standalone concern, kept out of interpolate() itself: interpolate() only ever
    changes VIDEO timing - its own encoder never sees audio at all - so without this the
    documented standalone `interpolate` CLI silently dropped every audio track.
    finish.sh never notices, because it remuxes the ORIGINAL source's audio into its own
    final deliverable regardless of what interpolate() writes, but a direct caller
    publishing dst as-is got a silent picture.

    Pulled out as its own function - unlike the rest of interpolate(), this needs no CUDA
    torch or model to reach, so it can be exercised directly.
    """
    root, ext = os.path.splitext(dst)
    has_audio = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "a", "-show_entries",
         "stream=index", "-of", "csv=p=0", src], capture_output=True, text=True
    ).stdout.strip() != ""
    if not has_audio:
        os.replace(video_tmp, dst)
        return
    # Stream copy, not re-encode: the video is already final, and the audio is untouched
    # by anything upstream of this, so copying is exact and free. Muxed into a second
    # temp file, not into video_tmp itself (ffmpeg cannot read and write the same path in
    # one invocation) nor directly into dst (the same atomicity interpolate()'s own video
    # write already needs - a failed mux must not leave a half-written file at the path a
    # caller is about to publish).
    dst_tmp2 = f"{root}.partial2{ext}"
    mux_rc = subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-i", video_tmp, "-i", src,
         "-map", "0:v:0", "-map", "1:a:0", "-c", "copy", dst_tmp2]).returncode
    if mux_rc != 0:
        # The source audio codec is not always one the destination container accepts
        # as-is - reproduced directly: pcm_u8 and wmav2 both refuse to mux into MP4 via
        # stream copy ("codec not currently supported in container"). Losing an
        # otherwise-complete, expensive interpolation to a container mismatch after the
        # fact would be a worse failure than a lossy but universally-accepted re-encode,
        # so retry with AAC before giving up.
        mux_rc = subprocess.run(
            ["ffmpeg", "-v", "error", "-y", "-i", video_tmp, "-i", src,
             "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy",
             "-c:a", "aac", "-b:a", "128k", dst_tmp2]).returncode
    # video_tmp is kept until dst is confirmed published, not deleted the moment the mux
    # succeeds - the mux producing a good dst_tmp2 is not the same fact as os.replace()
    # actually landing it at dst (dst can be an existing directory, on a different
    # filesystem, or otherwise unwritable), and until that replace lands, video_tmp is
    # still the only recoverable copy of an otherwise-complete interpolation.
    if mux_rc != 0:
        raise SystemExit(
            f"!! muxing audio from {src} into {dst} failed (ffmpeg exit {mux_rc}), "
            f"even after transcoding to AAC. The completed video-only interpolation is "
            f"preserved at {video_tmp} - move it into place manually, or retry.")
    os.replace(dst_tmp2, dst)
    os.remove(video_tmp)


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
    # Reject extra arguments rather than silently ignoring them - the same convention
    # cloud/run_on_pod.sh already enforces. Without this, `recommend video --explan` (a
    # typo) ran to completion with no explanation and no complaint, and a stray extra
    # argument to `interpolate` still launched the (expensive) model.
    max_argc = {"measure": 3, "recommend": 4, "why": 2, "interpolate": 7}.get(cmd)
    if max_argc is not None and len(sys.argv) > max_argc:
        raise SystemExit(f"!! unexpected extra argument(s) to '{cmd}': {sys.argv[max_argc:]}")
    if cmd == "measure":
        m = block_motion(sys.argv[2])
        rec = recommendation(m)
        print(f"block motion (windowed max): {100*m:.2f}% of width  "
              f"threshold {100*MOTION_THRESHOLD:.1f}%  -> {rec}")
    elif cmd == "recommend":
        # Checked before block_motion() runs, not after: a bad option is a usage error,
        # not something that should have to wait behind a full clip scan (or fail with a
        # confusing unrelated message, if the video path was ALSO bad - "could not measure
        # motion" for what was actually a mistyped flag) to be reported.
        if len(sys.argv) > 3 and sys.argv[3] != "--explain":
            raise SystemExit(f"!! unknown option '{sys.argv[3]}', expected --explain")
        m = block_motion(sys.argv[2])
        rec = recommendation(m)
        print(rec)
        # Second line only on request, so a caller needing the number for its log does not
        # pay for a second pass over the clip - which is now the WHOLE clip, making the
        # saving larger than when this was written against a 400-frame cap. Same shape as
        # grade.py --both.
        if len(sys.argv) > 3:
            print(f"block motion (windowed max): {100*m:.2f}% of width, "
                  f"threshold {100*MOTION_THRESHOLD:.1f}%")
    elif cmd == "why":
        why = unavailable_reason()
        print(why or "available")
        sys.exit(0 if why is None else 1)
    elif cmd == "interpolate":
        if len(sys.argv) < 4:
            raise SystemExit(
                "usage: rife.py interpolate <in> <out> [target_fps] [scale] [--no-audio]")
        # --no-audio is a FLAG, not a positional argument fixed to argv[6] - the usage
        # line advertises target_fps and scale as independently optional, so
        # `interpolate in out --no-audio` (skipping both) has to work, not just
        # `interpolate in out 60 1.0 --no-audio` (giving both first). Found by
        # reproduction: the fixed-position version raised a raw ValueError from
        # float("--no-audio") for exactly that shorter, equally valid form. Removed from
        # wherever it appears among the trailing args, then whatever remains is read
        # positionally as [target_fps] [scale].
        rest = sys.argv[4:]
        with_audio = "--no-audio" not in rest
        rest = [a for a in rest if a != "--no-audio"]
        bad_flags = [a for a in rest if a.startswith("--")]
        if bad_flags:
            raise SystemExit(f"!! unknown option '{bad_flags[0]}', expected --no-audio")
        if len(rest) > 2:
            raise SystemExit(f"!! unexpected extra argument(s) to 'interpolate': {rest[2:]}")
        interpolate(sys.argv[2], sys.argv[3],
                    float(rest[0]) if len(rest) > 0 else 60.0,
                    float(rest[1]) if len(rest) > 1 else 1.0,
                    with_audio=with_audio)
    else:
        raise SystemExit(f"unknown command '{cmd}'")


if __name__ == "__main__":
    main()
