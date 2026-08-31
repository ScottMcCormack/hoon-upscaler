#!/bin/bash
# Regression suite for the restoration pipeline.
#
#   bash tests/run.sh            # everything
#   bash tests/run.sh timing     # only tests whose name contains "timing"
#
# What belongs here: anything with an objective definition — frame counts, timestamps,
# boundary alignment, guards firing. What does NOT belong here: any assertion about
# whether the output *looks* right. Six perceptual metrics were built during development
# and all six failed or actively misled; see docs/findings.md. Judge appearance by eye,
# against a visual comparison.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILTER="${1:-}"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
# shellcheck source=tests/lib.sh
source "$REPO/tests/lib.sh"

want() { [ -z "$FILTER" ] || [[ "$1" == *"$FILTER"* ]]; }

echo "restoration pipeline tests"
echo

# ---------------------------------------------------------------------------
# Acceptance tests for the open timing issues. These define "done" for #2 and #3
# and are expected to fail until those are fixed.
# ---------------------------------------------------------------------------
echo "timing fidelity (issues #2, #3)"

if want timing; then
  SRC="$W/src.mp4"; RAW="$W/raw.mp4"; OUT="$W/out"
  mk_vfr_source "$SRC" 40 5 8 20 24    # two stalls, so state carried between them is tested
  N="$(frame_count "$SRC")"
  mk_upscaled "$RAW" "$N"
  mkdir -p "$OUT"
  bash "$REPO/pipeline/finish.sh" "$RAW" T "$SRC" "$OUT" >"$W/finish.log" 2>&1
  RENDER="$OUT/T_lumafix_14fps.mp4"
  K5="$OUT/T_lumafix_K5.mp4"

  if [ ! -f "$RENDER" ]; then
    bad "timing: finish.sh produced a source-cadence render" "$(tail -1 "$W/finish.log")"
  else
    # The render is CFR with held frames repeated, so it has MORE frames than the
    # source. What must hold is that every source moment exists in it, exactly.
    MISSING="$(python - "$W" <<'PY'
import subprocess, sys
def pts(f):
    out = subprocess.run(["ffprobe","-v","error","-select_streams","v:0",
                          "-show_entries","frame=pts_time","-of","csv=p=0",f],
                         capture_output=True, text=True).stdout
    return [float(x.rstrip(",")) for x in out.split() if x.strip()]
src, ren = pts(sys.argv[1] + "/src.mp4"), pts(sys.argv[1] + "/out/T_lumafix_14fps.mp4")
worst = max(min(abs(s - r) for r in ren) for s in src)
print(f"{worst:.6f}")
PY
)"
    # 1ms is 1.5% of a frame period at 15fps — comfortably "exact", and 13x tighter
    # than the 13.3ms error the 25fps concat grid used to produce.
    assert_under "timing: every source timestamp exists in the render (#2)" 0.001 "$MISSING"

    # Every stall must actually be held. A single-stall clip cannot catch state that
    # goes wrong after the first one — which is exactly how a reader-position bug
    # survived a green suite once already.
    HELD="$(grep 'interpolated (' "$W/finish.log" | grep -oE '[0-9]+ held' | grep -oE '^[0-9]+' || echo 0)"
    EXPECT_HELD="$(python - "$W" <<'PY'
import subprocess, sys
out = subprocess.run(["ffprobe","-v","error","-select_streams","v:0","-show_entries",
                      "frame=pts_time","-of","csv=p=0", sys.argv[1]+"/src.mp4"],
                     capture_output=True, text=True).stdout
p = [float(x.rstrip(",")) for x in out.split() if x.strip()]
g = [p[i+1]-p[i] for i in range(len(p)-1)]
print(round(sum(d for d in g if d > 0.150) * 60 * 0.5))   # half the stall span, a floor
PY
)"
    if [ "$HELD" -ge "$EXPECT_HELD" ]; then ok "timing: held frames cover both stalls ($HELD >= $EXPECT_HELD)"
    else bad "timing: held frames cover both stalls" "only $HELD held, expected at least $EXPECT_HELD"; fi

    # Issue #3 — the deliverable must not end before the source does.
    if [ -f "$K5" ]; then
      SD="$(duration_of "$SRC")"; KD="$(duration_of "$K5")"
      SHORT="$(python -c "print('yes' if $SD - $KD > 1.0/60 else 'no')")"
      assert_eq "timing: 60fps output covers the full source span (#3)" "no" "$SHORT"
    else
      bad "timing: finish.sh produced a 60fps output" "$(tail -1 "$W/finish.log")"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Guards. Each of these fired a real defect on the founding PR; they are here so
# the next change cannot quietly remove them.
# ---------------------------------------------------------------------------
echo
echo "guards"

if want guards; then
  # finish.sh must refuse a tag that could escape the output directory via rm -rf.
  assert_stderr_matches "guards: finish.sh rejects a traversing tag" "invalid tag" \
    bash "$REPO/pipeline/finish.sh" /dev/null "../escape" /dev/null "$W/x"

  # A truncated model run must not become a shortened deliverable.
  SRC2="$W/s2.mp4"; RAW2="$W/r2.mp4"
  mk_vfr_source "$SRC2" 14 4 5
  mk_upscaled "$RAW2" "$(( $(frame_count "$SRC2") - 1 ))"
  assert_stderr_matches "guards: finish.sh rejects a frame/timestamp mismatch" "mismatch" \
    bash "$REPO/pipeline/finish.sh" "$RAW2" M "$SRC2" "$W/o2"

  # run_on_pod.sh must not guess a mode, because the wrong guess is the paid render.
  assert_stderr_matches "guards: run_on_pod rejects an unknown mode" "unknown mode" \
    bash "$REPO/cloud/run_on_pod.sh" 720 tset

  # selective_interp.py must reject timestamp files it cannot trust.
  printf '0.000\n0.067\nNOPE\n0.200\n' > "$W/bad.txt"
  printf '0.000\n0.067\n0.067\n0.200\n' > "$W/dup.txt"
  printf '0.000\n0.067\n0.050\n0.200\n' > "$W/back.txt"
  V="$W/v.mp4"; mk_upscaled "$V" 4
  for case in bad:"cannot read" dup:"not strictly increasing" back:"not strictly increasing"; do
    f="${case%%:*}"; pat="${case#*:}"
    assert_stderr_matches "guards: selective_interp rejects $f timestamps" "$pat" \
      python "$REPO/pipeline/selective_interp.py" "$V" "$V" "$W/$f.txt" "$W/o.mkv" 150 3
  done

  # reframe_src.py must refuse detections from the wrong coordinate space, and must
  # not crash when the detector found nothing.
  python - "$W" <<'PY'
import json, sys
w = sys.argv[1]
json.dump({**{str(i): [{"cls":"car","conf":.9,"cx":100.,"cy":80.,"w":40,"h":30}] for i in range(4)},
           "_meta": {"width": 352, "height": 288}}, open(f"{w}/wrong_space.json", "w"))
json.dump({"_meta": {"width": 1408, "height": 1152}}, open(f"{w}/empty.json", "w"))
PY
  SRC3="$W/s3.mp4"; mk_upscaled "$SRC3" 4
  assert_stderr_matches "guards: reframe_src rejects a coordinate-space mismatch" "352x288 space" \
    env DETECTIONS="$W/wrong_space.json" python "$REPO/pipeline/reframe_src.py" 860 t "$SRC3"
  assert_stderr_matches "guards: reframe_src rejects an unusable source geometry" "inverse transform assumes" \
    env DETECTIONS="$W/empty.json" python "$REPO/pipeline/reframe_src.py" 860 t "$SRC3"
fi

# ---------------------------------------------------------------------------
# Repository invariants that have silently broken before.
# ---------------------------------------------------------------------------
echo
echo "repository"

if want repository; then
  # A directory exclusion cannot be undone by a ! negation, and this went unnoticed
  # through the whole founding PR — both READMEs were ignored and never committed.
  for f in masters/README.md experiments/README.md; do
    if git -C "$REPO" check-ignore -q "$f" 2>/dev/null; then
      bad "repository: $f is not ignored" "gitignore negation is not taking effect"
    else
      ok "repository: $f is not ignored"
    fi
  done
  # ...while the media itself must stay ignored.
  for f in masters/sr_out_1080.mp4 out/x.mp4 input/y.mp4 experiments/z.mp4; do
    if git -C "$REPO" check-ignore -q "$f" 2>/dev/null; then
      ok "repository: $f stays ignored"
    else
      bad "repository: $f stays ignored" "media would be committable"
    fi
  done
fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m%d passed\033[0m\n' "$PASS"
else
  printf '\033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n' "$PASS" "$FAIL"
  for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
fi
[ "$FAIL" -eq 0 ]
