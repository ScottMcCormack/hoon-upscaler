#!/bin/bash
# Finishing pipeline: luma fix -> source-cadence timing -> grade -> selective 60fps.
#
# Timing is exact. Each source frame is placed at its own timestamp, by expressing the
# cadence as a constant rate with held frames repeated rather than as concat `duration`
# directives - those get snapped to the demuxer's 40ms grid, which used to leave every
# frame within ~13ms of where it belonged. Verified at zero error across all 1480 frames
# of the reference clip.
#
# Takes the raw output of a SeedVR2 upscale and produces watchable deliverables.
# The ORIGINAL source is needed for two things: its real per-frame timestamps, and
# its audio track.
#
# usage: finish.sh <raw_upscaled.mp4> <TAG> <original_source.mp4> [output_dir]
#
#   raw_upscaled.mp4   model output, constant frame rate, no audio
#   TAG                basename for the outputs, e.g. MyClip
#   original_source    the untouched camera file
#   output_dir         defaults to ./out
#
# Produces:
#   <TAG>_lumafix_14fps.mp4           source cadence, graded
#   <TAG>_lumafix_14fps_ungraded.mp4  reference
#   <TAG>_lumafix_K5.mp4              60fps, selective interpolation
set -euo pipefail

RAW="${1:?raw upscaled mp4 required}"
TAG="${2:?tag required}"
# TAG is interpolated into the work directory below, which is later rm -rf'd. Reject
# anything that could escape OUT_DIR.
case "$TAG" in
  */*|*\\*|.|..|*..*|"") echo "!! invalid tag '$TAG': no path separators or .. allowed"; exit 1 ;;
esac
SRC_ORIG="${3:?original source mp4 required}"
OUT_DIR="${4:-$PWD/out}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
GRADE="eq=contrast=1.20:saturation=1.28:gamma=0.96"
W="$OUT_DIR/.work_$TAG"

for f in "$RAW" "$SRC_ORIG"; do
  [ -f "$f" ] || { echo "!! not found: $f" >&2; exit 1; }
done
mkdir -p "$W" "$OUT_DIR"

# Prefer the repo venv if present, so python deps resolve predictably.
if [ -f "$REPO/.venv/bin/activate" ]; then
  # shellcheck disable=SC1091
  source "$REPO/.venv/bin/activate"
fi

echo "### $TAG  <- $(basename "$RAW")  $(date +%T)"
ffprobe -v error -select_streams v:0 -show_entries stream=width,height,nb_frames \
  -of csv=p=0 "$RAW"

echo "### [1/5] temporal luma stabilisation"
python "$HERE/luma_stabilise.py" "$RAW" "$W/stab.mkv" 61 1.0 2>&1 | tail -4

echo "### [2/5] frames + source timings"
ffprobe -v error -select_streams v:0 -show_entries frame=pts_time -of csv=p=0 "$SRC_ORIG" \
  | tr -d ',' | grep -v '^$' > "$W/pts.txt"
rm -f "$W"/f_*.png
ffmpeg -y -v error -i "$W/stab.mkv" "$W/f_%06d.png"
echo "    $(ls "$W"/f_*.png | wc -l) frames"
WORKDIR="$W" REPO="$REPO" python - <<'PY'
import os
import sys
from fractions import Fraction
from pathlib import Path

sys.path.insert(0, os.path.join(os.environ["REPO"], "pipeline"))
import timing

w = Path(os.environ["WORKDIR"])
pts = [float(x) for x in w.joinpath("pts.txt").read_text().split() if x.strip()]
fr = sorted(w.glob("f_*.png"))

# A crashed inference run produces a plausible, shorter file. Taking min() here would
# quietly turn that into a shorter deliverable, which is exactly the failure this
# pipeline is supposed to catch.
if len(fr) != len(pts):
    raise SystemExit(
        f"!! frame/timestamp mismatch: {len(fr)} restored frames vs {len(pts)} source "
        f"timestamps. Check the upscale completed before finishing."
    )

n = len(fr)
durs = []
for i in range(n - 1):
    d = pts[i + 1] - pts[i]
    if d <= 0:
        raise SystemExit(
            f"!! non-monotonic source timestamps at frame {i}: "
            f"{pts[i]:.6f} -> {pts[i+1]:.6f}. Clamping this would produce a plausible "
            f"but wrong result, so it is an error."
        )
    durs.append(d)

# The final frame has no following timestamp, so its duration is chosen rather than
# derived. The median of the real gaps is the modal frame period and, unlike the last
# gap, cannot accidentally inherit a stall.
term = sorted(durs)[len(durs) // 2] if durs else 1 / 15

# Timing is expressed as a CONSTANT rate with held frames repeated, not as per-frame
# `duration` directives. The concat demuxer takes its timebase from the image demuxer,
# which defaults to 1/25, and silently rounds every duration to that grid - a steady
# 66.7ms cadence comes out as 80/40/80/40. Repeats have no such problem: this camera
# only ever stalls for whole multiples of a frame period, so the same playback is
# exactly representable at the base rate.
base = timing.base_rate(durs) if durs else Fraction(15)
reps, worst = timing.repeats(durs, term, base)
if worst > 0.02:
    raise SystemExit(
        f"!! source gaps are not whole multiples of {1000/float(base):.1f}ms (worst "
        f"offender is {worst:.3f} of a frame out). This footage cannot be expressed "
        f"exactly at a constant rate, and the concat-duration alternative would quantise "
        f"it to 40ms. Handle this source explicitly rather than approximating it."
    )

lines = []
for f, r in zip(fr, reps):
    lines += [f"file '{f.name}'"] * r
w.joinpath("concat.txt").write_text("\n".join(lines) + "\n")
# An exact rational, not a decimal. 1/0.066666 is 15.000150002, and ffmpeg's -r takes
# that literally: the error accumulates to about a millisecond over a full clip.
w.joinpath("base_fps.txt").write_text(f"{base.numerator}/{base.denominator}\n")
# The span the VIDEO actually covers, from timestamps already checked for monotonicity
# and representability. Not the container duration: that is max(video, audio), so a
# source whose audio runs past its video would inflate the interpolation target and
# produce a frozen tail.
w.joinpath("span.txt").write_text(f"{sum(durs) + term:.9f}\n")
held = sum(r - 1 for r in reps)
print(f"    concat {n} source frames -> {len(lines)} at {base}fps "
      f"({held} held), spanning {sum(durs)+term:.2f}s")
PY

echo "### [3/5] source-cadence renders"
BASE_FPS=$(cat "$W/base_fps.txt")
ffmpeg -y -v error -r "$BASE_FPS" -f concat -safe 0 -i "$W/concat.txt" -i "$SRC_ORIG" \
  -map 0:v:0 -map 1:a:0? -r "$BASE_FPS" \
  -vf "$GRADE" -c:v libx264 -preset medium -crf 17 -pix_fmt yuv420p \
  -c:a aac -b:a 128k -movflags +faststart "$OUT_DIR/${TAG}_lumafix_14fps.mp4"
ffmpeg -y -v error -r "$BASE_FPS" -f concat -safe 0 -i "$W/concat.txt" -i "$SRC_ORIG" \
  -map 0:v:0 -map 1:a:0? -r "$BASE_FPS" \
  -c:v libx264 -preset medium -crf 17 -pix_fmt yuv420p \
  -c:a aac -b:a 128k -movflags +faststart "$OUT_DIR/${TAG}_lumafix_14fps_ungraded.mp4"

echo "### [4/5] 60fps interpolation"
# minterpolate ends before its last input frame - it has nothing to interpolate into -
# and drops roughly a fifth of a second off the tail. This is not VFR-specific: a
# perfectly CFR 15fps input loses the same frames, with or without motion estimation.
# Clone a few frames onto the end so the filter has somewhere to run to, then trim back
# to the length the SOURCE says we should have. Deriving the target from the source
# rather than from the render keeps this independent of the concat timebase (issue #2).
SRC_SPAN=$(cat "$W/span.txt")
EXPECT60=$(python -c "print(round($SRC_SPAN * 60))")
echo "    target $EXPECT60 frames (video spans ${SRC_SPAN}s)"

# Interpolate from the GRADED render — the selective pass pulls held frames from it, and
# mixing graded with ungraded puts a ~10-17 luma step at every hold boundary.
ffmpeg -y -v error -i "$OUT_DIR/${TAG}_lumafix_14fps.mp4" \
  -vf "tpad=stop=8:stop_mode=clone,minterpolate=fps=60:mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1:scd=none,trim=end_frame=$EXPECT60,setpts=PTS-STARTPTS" \
  -c:v libx264 -preset fast -crf 12 -an "$W/i60.mp4"
I60_N=$(ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 "$W/i60.mp4")
echo "    interpolated $I60_N frames"
if [ "$I60_N" -ne "$EXPECT60" ]; then
  echo "!! interpolation produced $I60_N frames, expected $EXPECT60. Publishing this would"
  echo "   be the truncated deliverable this step exists to prevent. If tpad is too small"
  echo "   for the tail, raise stop=8."
  exit 1
fi

# Ease stays at 3, unchanged. Whether to keep the cross-dissolve is an open question
# that belongs to its own change, not to a timing fix: it blends two frames separated by
# the largest gap in the clip, which costs 5-8% edge energy on exactly those frames, but
# the alternative is a visible cut. docs/findings.md carries the measurements; the call
# is one for the eye. Pass 0 here to disable it.
echo "### [5/5] selective pass (hold gaps >150ms, ease 3)"
python "$HERE/selective_interp.py" "$W/i60.mp4" "$OUT_DIR/${TAG}_lumafix_14fps.mp4" \
  "$W/pts.txt" "$W/sel.mkv" 150 3 2>&1 | tail -2
ffmpeg -y -v error -i "$W/sel.mkv" -i "$SRC_ORIG" -map 0:v:0 -map 1:a:0? \
  -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p -c:a aac -b:a 128k \
  -movflags +faststart "$OUT_DIR/${TAG}_lumafix_K5.mp4"

rm -rf "$W"
echo "### done $(date +%T)"
ls -la "$OUT_DIR/${TAG}"_*.mp4
