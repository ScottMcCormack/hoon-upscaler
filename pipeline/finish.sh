#!/bin/bash
# Finishing pipeline: luma fix -> source-cadence timing -> grade -> selective 60fps.
#
# "Source cadence" not "true timing": the concat demuxer snaps each frame's duration to a
# 40ms grid, so stalls survive and the total span is preserved, but individual durations
# are within ~13ms rather than exact. See issue #2.
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
WORKDIR="$W" python - <<'PY'
import os
from pathlib import Path
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
out, durs = [], []
for i in range(n - 1):
    d = pts[i + 1] - pts[i]
    if d <= 0:
        raise SystemExit(
            f"!! non-monotonic source timestamps at frame {i}: "
            f"{pts[i]:.6f} -> {pts[i+1]:.6f}. Clamping this would produce a plausible "
            f"but wrong result, so it is an error."
        )
    durs.append(d)
    out.append(f"file '{fr[i].name}'\nduration {d:.6f}")

# The final frame has no following timestamp, so its duration is chosen rather than
# derived. The median of the real gaps is the modal frame period and, unlike the last
# gap, cannot accidentally inherit a stall.
term = sorted(durs)[len(durs) // 2] if durs else 1 / 15
out.append(f"file '{fr[n-1].name}'\nduration {term:.6f}")
# Deliberately NO repeated final entry. The old idiom - repeat the last file so it gets
# a duration - was correct while the loop wrote only n-1 entries. Now that all n are
# written with explicit durations, repeating emits an n+1th frame: N in, N+1 out.
w.joinpath("concat.txt").write_text("\n".join(out) + "\n")
print(f"    concat {n} frames spanning {sum(durs)+term:.2f}s")
PY

echo "### [3/5] source-cadence renders"
ffmpeg -y -v error -f concat -safe 0 -i "$W/concat.txt" -i "$SRC_ORIG" \
  -map 0:v:0 -map 1:a:0? -vsync vfr -video_track_timescale 15000 \
  -vf "$GRADE" -c:v libx264 -preset medium -crf 17 -pix_fmt yuv420p \
  -c:a aac -b:a 128k -movflags +faststart "$OUT_DIR/${TAG}_lumafix_14fps.mp4"
ffmpeg -y -v error -f concat -safe 0 -i "$W/concat.txt" -i "$SRC_ORIG" \
  -map 0:v:0 -map 1:a:0? -vsync vfr -video_track_timescale 15000 \
  -c:v libx264 -preset medium -crf 17 -pix_fmt yuv420p \
  -c:a aac -b:a 128k -movflags +faststart "$OUT_DIR/${TAG}_lumafix_14fps_ungraded.mp4"

echo "### [4/5] 60fps interpolation"
# minterpolate ends before its last input frame - it has nothing to interpolate into -
# and drops roughly a fifth of a second off the tail. This is not VFR-specific: a
# perfectly CFR 15fps input loses the same frames, with or without motion estimation.
# Clone a few frames onto the end so the filter has somewhere to run to, then trim back
# to the length the SOURCE says we should have. Deriving the target from the source
# rather than from the render keeps this independent of the concat timebase (issue #2).
SRC_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$SRC_ORIG")
EXPECT60=$(python -c "print(round($SRC_DUR * 60))")
echo "    target $EXPECT60 frames (source spans ${SRC_DUR}s)"

# Interpolate from the GRADED render — the selective pass pulls held frames from it, and
# mixing graded with ungraded puts a ~10-17 luma step at every hold boundary.
ffmpeg -y -v error -i "$OUT_DIR/${TAG}_lumafix_14fps.mp4" \
  -vf "tpad=stop=8:stop_mode=clone,minterpolate=fps=60:mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1:scd=none,trim=end_frame=$EXPECT60,setpts=PTS-STARTPTS" \
  -c:v libx264 -preset fast -crf 12 -an "$W/i60.mp4"
I60_N=$(ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 "$W/i60.mp4")
echo "    interpolated $I60_N frames"

echo "### [5/5] selective pass (hold gaps >150ms, ease 3)"
python "$HERE/selective_interp.py" "$W/i60.mp4" "$OUT_DIR/${TAG}_lumafix_14fps.mp4" \
  "$W/pts.txt" "$W/sel.mkv" 150 3 2>&1 | tail -2
ffmpeg -y -v error -i "$W/sel.mkv" -i "$SRC_ORIG" -map 0:v:0 -map 1:a:0? \
  -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p -c:a aac -b:a 128k \
  -movflags +faststart "$OUT_DIR/${TAG}_lumafix_K5.mp4"

rm -rf "$W"
echo "### done $(date +%T)"
ls -la "$OUT_DIR/${TAG}"_*.mp4
