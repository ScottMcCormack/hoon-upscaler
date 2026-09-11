"""
Neural frame interpolation (RIFE), for footage whose motion defeats minterpolate.

WHY THIS EXISTS

`minterpolate` searches for each block's motion within `search_param` pixels, default 32.
That was never sized against footage that pans. Measured per-frame block motion:

    N90 clip (minterpolate fine)      p95  1.86% of frame width
    MVI_0081, Canon (glassy)          p95  6.81% of frame width

Measured on the sources themselves, and as a fraction because the pixel figure depends on
what resolution you measure at - see MOTION_THRESHOLD.

On the deliverable that is ~130px, well outside the 32px window the estimator can look in,
so it returns a
wrong one and the compensation warps the picture along it. The result reads as the frame
flowing rather than moving.

Raising `search_param` does not fix it. At 250 the measurement says ZERO frames are beyond
range and it is still glassy, which rules the search range out as the mechanism. What
remains is inherent to block compensation on a fast pan: up to 8.4% of the frame width is
newly revealed each frame and has no correspondence to warp from, so blocks get stretched
into it. RIFE synthesises those regions instead of warping into them.

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

  rife.py measure <video>                         report motion, recommend an interpolator
  rife.py interpolate <in> <out> [multi] [scale]  interpolate
"""
import os
import subprocess
import sys

# Above this p95 block motion, minterpolate's default 32px search is too small and its
# output warps.
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
# 3% sits between the two clips that calibrated it, measured at their own widths:
#     N90 clip (minterpolate fine)   5.8px / 312  = 1.86%
#     MVI_0081 (glassy)             20.2px / 296  = 6.82%
# The earlier "39px and 130px" figures are the same two clips measured on their upscaled
# deliverables (~2000px wide), which is why they could not be reproduced from the sources
# the docstring named. As fractions they agree with the numbers above.
MOTION_THRESHOLD = 0.03

HERE = os.path.dirname(os.path.abspath(__file__))
RIFE_HOME = os.environ.get("RIFE_HOME", os.path.join(HERE, "..", "work", "rife"))
RIFE_REPO = os.path.join(RIFE_HOME, "Practical-RIFE")


def probe(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
         "stream=width,height,r_frame_rate,nb_read_packets", "-count_packets",
         "-of", "csv=p=0", path], capture_output=True, text=True, check=True).stdout.strip()
    w, h, rate, n = out.split(",")
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


def block_motion(path, sample=None):
    """p95 of per-frame p99 block motion, as a FRACTION of frame width.

    Normalised deliberately - see MOTION_THRESHOLD. The pixel figure is resolution
    dependent and this decision must not be.

    Per-BLOCK, not global camera displacement. On the N90 clip block motion exceeds
    global by 2.33x because the camera is near-static and the subject moves; deriving
    from global displacement there would under-size the search by more than half.
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
    return float(np.percentile(vals, 95)) / width


def multiplier(base_fps, target=60.0):
    """How many RIFE frames per source frame, to reach at least `target` fps.

    Lives here rather than inline in finish.sh so it can be tested without a GPU. The
    value used to be hardcoded to 4, which is right only for a 15fps source: at 30fps that
    produces 120fps, and trimming to the expected 60fps frame count then keeps the first
    half of the clip while every frame-count check still passes.
    """
    import math
    n, _, d = str(base_fps).partition("/")
    try:
        fps = float(n) / float(d or 1)
    except ValueError:
        raise SystemExit(f"!! cannot read a frame rate from {base_fps!r}")
    if fps <= 0:
        raise SystemExit(f"!! frame rate must be positive, got {base_fps!r}")
    # 1 is legitimate at or above the target: interpolate()'s inner loop is
    # `for k in range(1, multi)`, so multi=1 emits the source frames and nothing else.
    # Forcing 2 there bought a 120fps model pass whose every other frame is then dropped
    # by the fps filter - the most expensive way to change nothing.
    return max(1, math.ceil(target / fps))


def available():
    """Whether RIFE can actually be RUN, not merely whether its files are present.

    os.access(X_OK) rather than exists(): finish.sh invokes the venv interpreter directly,
    so a present-but-not-executable python passed this check and then fell through to the
    system python - which has no torch, or a different one. The check and the invocation
    have to ask the same question.
    """
    py = os.path.join(RIFE_HOME, "venv", "bin", "python")
    # Everything interpolate() actually needs, not just the weights. It does
    # `from train_log.RIFE_HDv3 import Model`, so a setup carrying flownet.pkl without the
    # architecture file passed this friendly guard and then failed with ModuleNotFoundError
    # from inside the import - which is the failure this function exists to pre-empt.
    needed = [os.path.join(RIFE_REPO, "train_log", f)
              for f in ("flownet.pkl", "RIFE_HDv3.py", "IFNet_HDv3.py")]
    if not (os.access(py, os.X_OK) and all(os.path.exists(f) for f in needed)):
        return False
    # Files present is not the same as importable. The venv may lack torch, or carry one
    # built for another CUDA line - both of which surface deep inside the model instead of
    # here, after auto-selection has already committed to RIFE. Ask the interpreter that
    # will actually run it.
    probe_src = ("import sys; sys.path.insert(0, %r); import torch; "
                 "from train_log.RIFE_HDv3 import Model" % RIFE_REPO)
    try:
        return subprocess.run([py, "-c", probe_src], cwd=RIFE_REPO,
                              capture_output=True, timeout=120).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def interpolate(src, dst, multi=4, scale=1.0):
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
    print(f"    {w}x{h} @ {fps:g}fps, {n} frames -> {fps*multi:g}fps, "
          f"{(n-1)*multi+1} frames (pad {pw}x{ph}, scale {scale})")

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
    wr = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt",
                           "rgb24", "-s", f"{w}x{h}", "-r", f"{fps*multi:g}", "-i", "-",
                           "-c:v", "libx264", "-preset", "fast", "-crf", "12", "-pix_fmt",
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
    emit(t_prev)
    done = 1
    while True:
        cur = read()
        if cur is None:
            break
        t_cur = to_t(cur)
        for k in range(1, multi):
            emit(model.inference(t_prev, t_cur, k / multi, scale))
        emit(t_cur)
        t_prev, done = t_cur, done + 1
        if done % 100 == 0:
            print(f"    {done}/{n}", flush=True)

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
    want = (n - 1) * multi + 1
    # A truncated interpolation still plays; only the frame count gives it away.
    if got != want:
        raise SystemExit(f"!! wrote {got} frames, expected {want}")
    print(f"    {got} frames")


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    cmd = sys.argv[1]
    if cmd == "measure":
        m = block_motion(sys.argv[2])
        rec = "rife" if m > MOTION_THRESHOLD else "minterpolate"
        print(f"block motion p95: {100*m:.2f}% of width  "
              f"threshold {100*MOTION_THRESHOLD:.1f}%  -> {rec}")
    elif cmd == "recommend":
        m = block_motion(sys.argv[2])
        rec = "rife" if m > MOTION_THRESHOLD else "minterpolate"
        print(rec)
        # Second line only on request, so a caller needing the number for its log does not
        # pay for a second pass over the clip - which is now the WHOLE clip, making the
        # saving larger than when this was written against a 400-frame cap. Same shape as
        # grade.py --both.
        if len(sys.argv) > 3 and sys.argv[3] == "--explain":
            print(f"block motion p95: {100*m:.2f}% of width, "
                  f"threshold {100*MOTION_THRESHOLD:.1f}%")
    elif cmd == "multiplier":
        print(multiplier(sys.argv[2]))
    elif cmd == "interpolate":
        if len(sys.argv) < 4:
            raise SystemExit("usage: rife.py interpolate <in> <out> [multi] [scale]")
        interpolate(sys.argv[2], sys.argv[3],
                    int(sys.argv[4]) if len(sys.argv) > 4 else 4,
                    float(sys.argv[5]) if len(sys.argv) > 5 else 1.0)
    else:
        raise SystemExit(f"unknown command '{cmd}'")


if __name__ == "__main__":
    main()
