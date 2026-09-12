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

# --- preflight ---------------------------------------------------------------
# Without this, a checkout that has not installed the requirements produces roughly
# fifteen ModuleNotFoundError tracebacks and no explanation. That is not a hypothetical:
# it is what a git worktree gives you, because the venv lives in the main checkout and
# does not come along, and two review agents each lost time to it - one reporting a red
# baseline that had nothing to do with the code under review.
#
# This refuses rather than skipping. A suite that quietly runs a subset is how coverage
# disappears without anyone deciding to drop it.
missing=""
# `timeout` is GNU coreutils and the cloud group depends on it. macOS ships no `timeout`
# at all, so without this the preflight passes and the cloud suite reports a bare exit 127
# - the generic message this preflight exists to replace.
for c in ffmpeg ffprobe python timeout; do
  command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
done
if [ -z "$missing" ]; then
  for m in numpy cv2; do
    python -c "import $m" >/dev/null 2>&1 || missing="$missing python:$m"
  done
fi
if [ -n "$missing" ]; then
  echo "!! cannot run the suite - missing:$missing" >&2
  echo >&2
  case "$missing" in
    *ffmpeg*|*ffprobe*)
      echo "   ffmpeg and ffprobe are not pip-installable:" >&2
      echo "     apt install ffmpeg     # or brew install ffmpeg" >&2
      echo >&2 ;;
  esac
  case "$missing" in
    *timeout*)
      echo "   \`timeout\` is GNU coreutils. macOS does not ship it:" >&2
      echo "     brew install coreutils" >&2
      echo "     PATH=\"\$(brew --prefix coreutils)/libexec/gnubin:\$PATH\"   # exposes it as \`timeout\`" >&2
      echo >&2 ;;
  esac
  case "$missing" in
    *python*)
      # Covers both a missing interpreter and a missing module. The interpreter case is
      # the commonest and the least obvious: the suite calls `python`, and plenty of
      # systems ship only `python3`.
      command -v python >/dev/null 2>&1 || {
        echo "   The suite calls \`python\`, not \`python3\`. If you only have python3:" >&2
        echo "     ln -s \"\$(command -v python3)\" ~/.local/bin/python   # or use a venv" >&2
        echo >&2
      }
      echo "   Python packages come from the core requirements:" >&2
      echo "     python -m pip install -r requirements.txt" >&2
      echo >&2
      echo "   If this repo has a venv, activate it or run the suite through it:" >&2
      echo "     PATH=\"$REPO/.venv/bin:\$PATH\" bash tests/run.sh" >&2
      echo "   (a git worktree does NOT inherit the main checkout's .venv)" >&2 ;;
  esac
  exit 1
fi

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
# Luma stabilisation. This module runs in every render and had no assertion of any
# kind - it was exercised end-to-end by the timing group, which would pass just as
# happily if it were a no-op or if it made the flicker worse. What it does has an
# objective definition (frame-to-frame mean luma should vary less afterwards), so it
# belongs here; whether the result LOOKS better does not.
# ---------------------------------------------------------------------------
echo
echo "luma stabilisation"

if want stabilise; then
  HUNT="$W/hunt.mp4"; STAB="$W/hunt_stab.mkv"
  # Injected auto-exposure hunting: the whole frame's brightness oscillates, which is
  # what the N90 did with nothing stable to meter on.
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=s=96x64:r=15:d=6" -frames:v 90 \
    -vf "geq=lum='clip(lum(X,Y)+14*sin(N*1.1),0,255)':cb='cb(X,Y)':cr='cr(X,Y)'" \
    -c:v libx264 -crf 18 -pix_fmt yuv420p "$HUNT"
  python "$REPO/pipeline/luma_stabilise.py" "$HUNT" "$STAB" 31 1.0 >/dev/null 2>&1
  STAB_RC=$?
  # Separate from the checks below, and not implied by them. The writer releases the
  # output file before its final reporting block, so a failure after that point leaves a
  # complete, correct video whose frame count and flicker both pass - while the real
  # pipeline, running under `set -euo pipefail`, aborts. A test that passes where
  # production fails is worse than no test.
  assert_eq "stabilise: exits 0" "0" "$STAB_RC"

  if [ ! -f "$STAB" ]; then
    bad "stabilise: produces an output" "no $STAB"
  else
    ok "stabilise: produces an output"
    # Frame count first. A stabiliser that drops frames would shift every timestamp
    # downstream, and this project has shipped a truncated render before.
    assert_eq "stabilise: frame count is preserved" \
      "$(frame_count "$HUNT")" "$(frame_count "$STAB")"

    RES="$(python - "$HUNT" "$STAB" <<'PY'
import sys
import cv2, numpy as np
def flicker(path):
    cap = cv2.VideoCapture(path); m = []
    while True:
        ok, f = cap.read()
        if not ok: break
        m.append(cv2.cvtColor(f, cv2.COLOR_BGR2GRAY).mean())
    cap.release()
    if len(m) < 3: raise SystemExit("too few frames")
    return float(np.std(np.diff(m)))
b, a = flicker(sys.argv[1]), flicker(sys.argv[2])
# Ratio, not absolute: the fixture's amplitude is arbitrary, the reduction is not.
print(f"{b:.3f} {a:.3f} {(b / a if a else 999):.1f}")
PY
)"
    BEFORE="${RES%% *}"; AFTER="$(echo "$RES" | cut -d" " -f2)"; RATIO="${RES##* }"
    # Measured 16x on this fixture. 4x is a floor that a working stabiliser clears
    # comfortably and a no-op (ratio 1.0) or an inverted correction cannot.
    if python -c "import sys; sys.exit(0 if $RATIO >= 4.0 else 1)" 2>/dev/null; then
      ok "stabilise: frame-to-frame luma flicker falls ($BEFORE -> $AFTER, ${RATIO}x)"
    else
      bad "stabilise: frame-to-frame luma flicker falls" \
          "only ${RATIO}x reduction ($BEFORE -> $AFTER), expected at least 4x"
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

  # The discontinuity tool must keep running and must refuse a clip with no stalls,
  # rather than dividing by an empty baseline.
  NOSTALL="$W/nostall.mp4"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=s=64x36:r=15:d=2" \
    -frames:v 30 -c:v libx264 -crf 20 -pix_fmt yuv420p "$NOSTALL"
  assert_stderr_matches "guards: stall_discontinuity refuses a clip with no stalls" "no gaps over" \
    python "$REPO/tools/stall_discontinuity.py" "$NOSTALL" "$NOSTALL"

  # A variant shorter than the source cannot have its exits scored - and a truncated
  # render is exactly what someone would reach for when comparing against the old output.
  TSRC="$W/tsrc.mp4"; mk_vfr_source "$TSRC" 40 5 8 20 24
  TFULL="$W/tfull.mp4"; mk_upscaled "$TFULL" 200
  TSHORT="$W/tshort.mp4"; mk_upscaled "$TSHORT" 30
  assert_stderr_matches "guards: stall_discontinuity refuses a truncated variant" "shorter than the source" \
    python "$REPO/tools/stall_discontinuity.py" "$TSRC" "$TSHORT"
fi

# ---------------------------------------------------------------------------
# Frame-rate derivation. Unit-tested rather than exercised through the pipeline,
# because the failure it guards is drift: it is invisible over a short fixture and
# only showed up after a 55-minute full-length render.
# ---------------------------------------------------------------------------
echo
echo "timing unit"

if want timing; then
  RATE_OUT="$(python - "$REPO" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/pipeline")
import timing
cases = [
    ("exact-15",  [1/15] * 5,             "15"),
    ("ffprobe6dp",[0.066666] * 5,         "15"),      # 1/0.066666 = 15.000150002
    ("ntsc",      [1001/15000] * 5,       "15000/1001"),
    ("with-stall",[0.066666, 0.266666],   "15"),
]
for name, gaps, want in cases:
    got = str(timing.base_rate(gaps))
    print(f"{name} {'OK' if got == want else 'BAD'} {got} {want}")
# drift over a full clip length must vanish
r = float(timing.base_rate([0.066666] * 5))
drift_ms = 1556 * abs(1 / r - 1 / 15) * 1000
print(f"drift {'OK' if drift_ms < 0.001 else 'BAD'} {drift_ms:.6f} 0")

# Timing that no constant rate can express must be refused, not rounded. The
# pipeline's whole approach rests on gaps being whole multiples of one frame period.
for nm, gaps, should_refuse in [
    ("accepts-nokia",   [0.066666, 0.133333, 0.266666, 0.066666], False),
    ("refuses-50/70",   [0.050, 0.070, 0.050, 0.070],             True),
    ("refuses-40/65/90",[0.040, 0.065, 0.090],                    True),
    ("accepts-ntsc",    [2 * 1001 / 30000] * 4,                   False),
]:
    _, worst = timing.repeats(gaps, gaps[0], timing.base_rate(gaps))
    refused = worst > 0.02
    print(f"{nm} {'OK' if refused == should_refuse else 'BAD'} "
          f"{'refused' if refused else 'accepted'} "
          f"{'refused' if should_refuse else 'accepted'}")
PY
)"
  while read -r name verdict got want; do
    [ -z "$name" ] && continue
    if [ "$verdict" = "OK" ]; then ok "timing unit: $name -> $got"
    else bad "timing unit: $name" "got $got, wanted $want"; fi
  done <<< "$RATE_OUT"
fi

# ---------------------------------------------------------------------------
# Repository invariants that have silently broken before.
# ---------------------------------------------------------------------------
echo
echo "repository"

if want repository; then

  # An index that has to be maintained by hand goes stale the first time someone appends
  # a section - which it did, within one PR of being added. Asserting it is the only way
  # a docs convenience stays true; otherwise it quietly becomes a lie about the document
  # it sits at the top of.
  IDX="$(python - "$REPO" <<'PY'
import pathlib, re, sys
s = pathlib.Path(sys.argv[1] + "/docs/findings.md").read_text()
if "## Contents" not in s:
    print("bad: findings.md has no Contents index"); raise SystemExit
block = s[s.index("## Contents"):s.index("## Pre-filters")]
listed = set(re.findall(r"^- \[(.+?)\]", block, flags=re.M))
heads = [h for h in re.findall(r"^## (.+)$", s, flags=re.M) if h != "Contents"]
missing = [h for h in heads if h not in listed]
extra = [h for h in listed if h not in heads]
out = []
if missing: out.append("not in the index: " + "; ".join(missing[:3]))
if extra:   out.append("in the index but not the document: " + "; ".join(extra[:3]))
print("ok" if not out else "bad: " + " | ".join(out))
PY
)"
  assert_eq "repository: the findings index lists every section" "ok" "$IDX"
  # A directory exclusion cannot be undone by a ! negation, and this went unnoticed
  # through the whole founding PR — both READMEs were ignored and never committed.
  for f in masters/README.md experiments/README.md; do
    if git -C "$REPO" check-ignore -q "$f" 2>/dev/null; then
      bad "repository: $f is not ignored" "gitignore negation is not taking effect"
    else
      ok "repository: $f is not ignored"
    fi
  done
  # The core requirements must not drag in the AGPL detection stack. NOTICE tells
  # readers that Apache-2.0 does not cover detect_car.py's dependency chain; that
  # promise breaks if a plain `pip install -r requirements.txt` installs ultralytics.
  if grep -qiE '^(ultralytics|torch)' "$REPO/requirements.txt" 2>/dev/null; then
    bad "repository: core requirements stay free of the AGPL stack" \
        "requirements.txt pulls in torch/ultralytics"
  else
    ok "repository: core requirements stay free of the AGPL stack"
  fi
  if grep -q 'requirements.txt' "$REPO/requirements-reframe.txt" 2>/dev/null; then
    ok "repository: reframe requirements build on the core file"
  else
    bad "repository: reframe requirements build on the core file" "missing -r requirements.txt"
  fi

  # ...while the media itself must stay ignored.
  for f in masters/sr_out_1080.mp4 out/x.mp4 input/y.mp4 experiments/z.mp4; do
    if git -C "$REPO" check-ignore -q "$f" 2>/dev/null; then
      ok "repository: $f stays ignored"
    else
      bad "repository: $f stays ignored" "media would be committable"
    fi
  done
fi

# ---------------------------------------------------------------------------
# Grading. The old fixed grade clipped 51.8% of a bright clip to white and crushed
# 3.5% of a dark one to black, because eq's contrast pivot is fixed at 128 and the
# footage is not. Only clipping is asserted here - it has an objective definition.
# Whether a grade LOOKS right stays an eye call, per the header of this file.
# ---------------------------------------------------------------------------
echo
echo "grading"

if want grade; then
  G="$REPO/pipeline/grade.py"
  # A bright clip pinned to white, a dark one pinned to black, and one that is neither.
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=white:s=64x36:r=15:d=2" \
    -vf "geq=lum='240+15*sin(X/3)':cb=128:cr=128" -frames:v 30 -pix_fmt yuv420p "$W/bright.mp4"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=black:s=64x36:r=15:d=2" \
    -vf "geq=lum='max(0,8*sin(X/3))':cb=128:cr=128" -frames:v 30 -pix_fmt yuv420p "$W/dark.mp4"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=gray:s=64x36:r=15:d=2" \
    -frames:v 30 -pix_fmt yuv420p "$W/mid.mp4"

  assert_eq "grade: a clip pinned to white picks the bright preset" \
    "bright" "$(python "$G" pick "$W/bright.mp4" --name 2>/dev/null)"
  # The opt-in is needed because 'dark' is unreviewed and no longer auto-selected. What
  # is asserted here is the MEASUREMENT - black footage measures as needing the dark
  # curve - which stays true and testable independently of whether it is approved to run.
  assert_eq "grade: a clip pinned to black measures as needing the dark preset" \
    "dark" "$(GRADE_ALLOW_UNREVIEWED=1 python "$G" pick "$W/dark.mp4" --name 2>/dev/null)"
  assert_eq "grade: a clip on neither rail picks neutral" \
    "neutral" "$(python "$G" pick "$W/mid.mp4" --name 2>/dev/null)"

  # The guard is the point of the whole change: it must reject the grade that shipped.
  ffmpeg -hide_banner -loglevel error -y -i "$W/bright.mp4" \
    -vf "eq=contrast=1.20:saturation=1.28:gamma=0.96" -pix_fmt yuv420p "$W/bad.mp4"
  assert_stderr_matches "grade: the guard rejects a grade that clips" "destroying picture" \
    python "$G" verify "$W/bright.mp4" "$W/bad.mp4"

  ffmpeg -hide_banner -loglevel error -y -i "$W/bright.mp4" \
    -vf "$(python "$G" pick "$W/bright.mp4")" -pix_fmt yuv420p "$W/good.mp4"
  if python "$G" verify "$W/bright.mp4" "$W/good.mp4" >/dev/null 2>&1
  then ok "grade: the guard passes the chosen preset"
  else bad "grade: the guard passes the chosen preset" "chosen preset failed its own check"; fi

  # An explicit GRADE must win over the derived one...
  SRC="$W/gsrc.mp4"; RAW="$W/graw.mp4"; GOUT="$W/gout"; mkdir -p "$GOUT"
  mk_vfr_source "$SRC" 40 5 8
  mk_upscaled "$RAW" "$(frame_count "$SRC")"
  # Capture, then match. Piping into `grep -q` looks equivalent and is not: grep exits
  # on the first match, finish.sh takes SIGPIPE, and `pipefail` reports the pipeline as
  # failed even though the assertion held.
  # saturation=0, not saturation=1.0. The identity filter this used to pass proved only
  # that finish.sh PRINTED "grade: explicit" before ffmpeg ran - a mutation that announced
  # the override and then silently discarded it passed the test. The effect has to be
  # measurable in the render, and the run has to succeed.
  out="$(GRADE="eq=saturation=0" bash "$REPO/pipeline/finish.sh" "$RAW" G "$SRC" "$GOUT" 2>&1)"; st=$?
  GRADED="$GOUT/G_lumafix_14fps.mp4"
  if [ "$st" -ne 0 ]; then
    bad "grade: finish.sh honours an explicit GRADE" "exit $st: $(printf '%s' "$out" | tail -1)"
  elif [ ! -f "$GRADED" ]; then
    bad "grade: finish.sh honours an explicit GRADE" "no $GRADED"
  else
    # SATAVG collapses to ~1 when saturation is zeroed, and sits well above it otherwise.
    SAT="$(ffprobe -v error -f lavfi "movie=$GRADED,signalstats" \
            -show_entries frame_tags=lavfi.signalstats.SATAVG -of csv=p=0 2>/dev/null \
            | head -1 | tr -d ',')"      # csv=p=0 still emits a trailing comma
    if [ -n "$SAT" ] && python -c "import sys; sys.exit(0 if float('$SAT') < 5 else 1)" 2>/dev/null; then
      ok "grade: finish.sh honours an explicit GRADE (SATAVG $SAT)"
    else
      bad "grade: finish.sh honours an explicit GRADE" "GRADE was announced but not applied (SATAVG ${SAT:-unreadable}, expected < 5)"
    fi
  fi

  # The rail boundaries themselves. Both off-by-ones (254->255, 1->0) passed every other
  # test in this group, because pick() and verify() only need gross classification and
  # never care exactly where the rail starts.
  RAILS="$(python - "$REPO" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/pipeline")
import numpy as np, grade
bad = []
for lv, want_c, want_x in ((0,0,1), (1,0,1), (2,0,0), (253,0,0), (254,1,0), (255,1,0)):
    c = np.zeros(256, dtype=np.int64); c[lv] = 1000
    st = grade.summarise(c)
    if round(st["clipped"]) != want_c: bad.append(f"luma {lv}: clipped {st['clipped']}")
    if round(st["crushed"]) != want_x: bad.append(f"luma {lv}: crushed {st['crushed']}")
print("ok" if not bad else "bad: " + "; ".join(bad))
PY
)"
  assert_eq "grade: the rails are exactly 254-255 and 0-1" "ok" "$RAILS"

  # Percentiles must interpolate the way numpy does, not snap to a bin edge. Snapping is
  # the obvious thing to do with a histogram and it is wrong: the two disagreed by up to
  # 9 luma levels, enough to cross pick()'s `p99 >= 250` and silently change the preset.
  # The fixture is the exact case that exposed it.
  PCT="$(python - "$REPO" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/pipeline")
import numpy as np, grade
bad = []
a = np.array([151] * 603 + [250] * 7, dtype=np.uint8)
counts = np.bincount(a, minlength=256).astype(np.int64)
got, want = grade._percentile(counts, int(counts.sum()), 99), float(np.percentile(a, 99))
if abs(got - want) > 1e-6:
    bad.append(f"p99 {got:.4f}, numpy says {want:.4f}")
rng = np.random.default_rng(0)
for _ in range(40):
    v = rng.integers(0, 256, size=int(rng.integers(10, 900))).astype(np.uint8)
    c = np.bincount(v, minlength=256).astype(np.int64)
    for q in (1, 50, 99):
        g, w = grade._percentile(c, int(c.sum()), q), float(np.percentile(v, q))
        if abs(g - w) > 1e-6:
            bad.append(f"p{q} {g:.4f} vs numpy {w:.4f}"); break
print("ok" if not bad else "bad: " + "; ".join(bad[:3]))
PY
)"
  assert_eq "grade: percentiles match numpy, not a bin edge" "ok" "$PCT"

  # A clip-wide average dilutes a short destroyed run to nothing. Seven fully clipped
  # frames in 1480 raise the whole-clip figure by 0.473 points, under the 0.5 tolerance,
  # while being seven frames with no picture left in them. Scanning every frame fixed the
  # SAMPLING gap and not this one; they are different holes.
  LUNG="$W/glong_ung.mp4"; LGRD="$W/glong_grd.mp4"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=gray:s=64x36:r=15:d=99" -frames:v 1480 \
    -vf "geq=lum='128':cb=128:cr=128" -c:v libx264 -qp 0 -pix_fmt yuv420p "$LUNG"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=gray:s=64x36:r=15:d=99" -frames:v 1480 \
    -vf "geq=lum='if(between(N,700,706),255,128)':cb=128:cr=128" -c:v libx264 -qp 0 -pix_fmt yuv420p "$LGRD"
  assert_stderr_matches "grade: a short destroyed run is caught despite the clip-wide average" \
    "frame 700" python "$G" verify "$LUNG" "$LGRD"

  # Renders of different length or geometry are not comparable, and percentages computed
  # across different footage are not evidence. An explicit GRADE carrying a `trim` would
  # otherwise be scored against a longer ungraded render.
  SHORTG="$W/gshort.mp4"
  ffmpeg -hide_banner -loglevel error -y -i "$LGRD" -frames:v 40 -c:v libx264 -qp 0 -pix_fmt yuv420p "$SHORTG"
  assert_stderr_matches "grade: renders of different length are refused, not compared" \
    "cannot compare" python "$G" verify "$LUNG" "$SHORTG"

  # A VFR clip must measure the frames it has, not the frames ffmpeg pads it to. Without
  # -fps_mode passthrough the default sync duplicates frames to force a constant rate —
  # rawvideo carries no timestamps to prevent it — so a 59-frame clip decoded 61. That
  # both rejected a good file and weighted the histogram by ffmpeg's padding. The source
  # this project exists for is VFR, so this is the normal case here.
  mk_vfr_source "$W/gvfr.mp4" 40 5 8
  VFRN="$(python - "$REPO" "$W/gvfr.mp4" <<'PY'
import subprocess, sys
sys.path.insert(0, sys.argv[1] + "/pipeline")
import grade
declared = grade.frame_count(sys.argv[2])
_, decoded, _ = grade.histogram(sys.argv[2], 1)
print(f"{declared} {decoded}")
PY
)"
  # Compare against the DECLARED count, not against the other half of the same string.
  # The first version of this asserted "${VFRN%% *}" = "${VFRN##* }", and when the helper
  # died both halves were the empty string and the test passed — a mutation removing
  # passthrough left it green while breaking five other tests. A test whose two sides can
  # both be empty is not comparing anything.
  case "$VFRN" in
    [0-9]*" "[0-9]*)
      assert_eq "grade: a VFR clip measures its own frames, not ffmpeg's padding" \
        "${VFRN%% *}" "${VFRN##* }" ;;
    *)
      bad "grade: a VFR clip measures its own frames, not ffmpeg's padding" \
          "measurement failed: ${VFRN:-<no output>}" ;;
  esac

  # ffprobe failing must produce the written diagnostic, not a CalledProcessError
  # traceback. The message existed before this test and was unreachable, because
  # check=True raised first.
  printf 'not a video\n' > "$W/gnotvideo.txt"
  assert_stderr_matches "grade: a non-video is refused with a message, not a traceback" \
    "could not read dimensions" python "$G" measure "$W/gnotvideo.txt"

  # A truncated render measures clean on whatever survived, and ffmpeg exits 0 after
  # dropping what it could not decode. CLAUDE.md records this trap for inference output;
  # the guard needs it too, or it reports "verified" on half a clip.
  TRU="$W/gtrunc.mp4"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=gray:s=64x36:r=15:d=4" -frames:v 60 \
    -vf "geq=lum='if(gte(N,30),255,128)':cb=128:cr=128" -movflags +faststart \
    -c:v libx264 -qp 0 -pix_fmt yuv420p "$TRU"
  truncate -s -600 "$TRU"
  assert_stderr_matches "grade: a truncated file is refused, not measured" "decoded" \
    python "$G" measure "$TRU"

  # An unreviewed preset must not be chosen for you. pick() still reports 'dark' as the
  # measurement's answer - that is a fact about the footage - but the CLI that finish.sh
  # calls refuses to hand back an unapproved look without an explicit opt-in.
  DARKSRC="$W/gdark.mp4"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=black:s=64x36:r=15:d=2" \
    -frames:v 20 -c:v libx264 -crf 20 -pix_fmt yuv420p "$DARKSRC"
  out="$(python "$G" pick "$DARKSRC" --name 2>&1)"
  case "$out" in
    *"not been checked by eye"*neutral) ok "grade: an unreviewed preset is not auto-selected" ;;
    *) bad "grade: an unreviewed preset is not auto-selected" "got: $(printf '%s' "$out" | tr '\n' ' ')" ;;
  esac
  out="$(GRADE_ALLOW_UNREVIEWED=1 python "$G" pick "$DARKSRC" --name 2>/dev/null)"
  assert_eq "grade: an unreviewed preset can be opted into" "dark" "$out"

  # A sampled guard steps over damage shorter than its stride. Frames 1-9 are blown to
  # white while frames 0 and 20 - the only ones a stride of 20 looks at - stay grey, so
  # the old check reported 0.00% clipped on a clip 22.5% destroyed and called it verified.
  UNG="$W/gap_ungraded.mp4"; GRD="$W/gap_graded.mp4"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=gray:s=64x36:r=15:d=3" -frames:v 40 \
    -vf "geq=lum='128':cb='128':cr='128'" -c:v libx264 -qp 0 -pix_fmt yuv420p "$UNG"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=gray:s=64x36:r=15:d=3" -frames:v 40 \
    -vf "geq=lum='if(between(N,1,9),255,128)':cb='128':cr='128'" -c:v libx264 -qp 0 -pix_fmt yuv420p "$GRD"
  assert_stderr_matches "grade: the guard sees damage between sampled frames" "destroying picture" \
    python "$G" verify "$UNG" "$GRD"

  # ...and must still be checked. Setting GRADE is not a licence to destroy the picture.
  rm -rf "$GOUT"; mkdir -p "$GOUT"
  out="$(GRADE="eq=contrast=4.0" bash "$REPO/pipeline/finish.sh" "$RAW" G "$SRC" "$GOUT" 2>&1)"
  case "$out" in
    *"destroying picture"*) ok "grade: an explicit GRADE is still checked" ;;
    *) bad "grade: an explicit GRADE is still checked" "a 4x contrast grade was accepted" ;;
  esac

  # Failing loudly is not enough: the encode used to be written straight to OUT_DIR and
  # verified afterwards, so a refusal left the destroyed render sitting where a
  # deliverable belongs, having already overwritten the previous good one. Render a good
  # one, then attempt a destructive grade over the top of it.
  rm -rf "$GOUT"; mkdir -p "$GOUT"
  bash "$REPO/pipeline/finish.sh" "$RAW" G "$SRC" "$GOUT" >/dev/null 2>&1
  GOOD="$GOUT/G_lumafix_14fps.mp4"
  if [ ! -f "$GOOD" ]; then
    bad "grade: a rejected grade does not replace a good render" "no baseline render produced"
  else
    BEFORE="$(sha256sum "$GOOD" | cut -d" " -f1)"
    GRADE="eq=contrast=4.0" bash "$REPO/pipeline/finish.sh" "$RAW" G "$SRC" "$GOUT" >/dev/null 2>&1
    AFTER="$(sha256sum "$GOOD" | cut -d" " -f1)"
    if [ "$BEFORE" = "$AFTER" ]; then
      ok "grade: a rejected grade does not replace a good render"
    else
      bad "grade: a rejected grade does not replace a good render" \
          "the deliverable changed after a grade that was refused"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Interpolator selection. On a fast pan, minterpolate stretches blocks into newly revealed
# content that has no correspondence to warp from; the 32px search window is a ruled-out
# hypothesis rather than the cause, and block motion is selected on as a proxy. The
# choice between it and RIFE is made from a measurement. Only the
# selection and the guards are tested - running RIFE needs a CUDA torch and model
# weights that this repo does not vendor, so the model itself is out of scope here.
# ---------------------------------------------------------------------------
echo
echo "interpolation"

if want interp; then
  R="$REPO/pipeline/rife.py"; G_RIFE="$R"

  # Five cases below vary only which fake RIFE_HOME is passed; sharing the probe itself
  # means what is actually under test - which directory - is the only thing left at each
  # call site, instead of being buried in four lines of boilerplate repeated five times.
  rife_available() {  # rife_available <RIFE_HOME>   -> "yes" or "no"
    RIFE_HOME="$1" python -c "
import sys
sys.path.insert(0, '$REPO/pipeline')
import rife
print('yes' if rife.available() else 'no')"
  }

  # The padding multiple is derived from scale, not from the network stride. Getting it
  # wrong fails deep inside the flow blocks, so it is worth pinning.
  assert_eq "interp: pad multiple at scale 1.0"  "128" "$(python -c "import sys;sys.path.insert(0,'$REPO/pipeline');import rife;print(rife.pad_to(1.0))")"
  assert_eq "interp: pad multiple at scale 0.5"  "256" "$(python -c "import sys;sys.path.insert(0,'$REPO/pipeline');import rife;print(rife.pad_to(0.5))")"
  assert_stderr_matches "interp: an unsupported scale is refused" "scale must be one of" \
    python -c "import sys;sys.path.insert(0,'$REPO/pipeline');import rife;rife.pad_to(0.7)"

  # A near-static clip must not pull in a GPU dependency it does not need; a fast-panning
  # one must not silently get the interpolator that warps it.
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=s=256x144:r=15:d=3" \
    -frames:v 40 -c:v libx264 -crf 20 -pix_fmt yuv420p "$W/static.mp4"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=s=1024x576:r=15:d=3" \
    -vf "crop=256:144:'min(iw-256,n*90)':100" -frames:v 40 -fps_mode passthrough \
    -c:v libx264 -crf 20 -pix_fmt yuv420p "$W/panning.mp4"
  assert_eq "interp: a near-static clip picks minterpolate" \
    "minterpolate" "$(python "$R" recommend "$W/static.mp4" 2>/dev/null)"
  assert_eq "interp: a fast-panning clip picks rife" \
    "rife" "$(python "$R" recommend "$W/panning.mp4" 2>/dev/null)"

  # Extra CLI arguments must be refused, not silently ignored - the same convention
  # cloud/run_on_pod.sh already enforces. Without this, a typo'd --explain ran to
  # completion with no explanation and no complaint, and a stray extra argument to
  # interpolate would still launch the model.
  assert_stderr_matches "interp: a mistyped --explain is refused, not silently ignored" \
    "unknown option '--explan'" \
    python "$R" recommend "$W/static.mp4" --explan
  # The option check must run BEFORE block_motion() scans the clip, not after - otherwise
  # an unreadable video path reports "could not measure motion" for what is actually a
  # mistyped flag, and a readable one prints a partial recommendation before refusing.
  # A nonexistent path makes this the only possible error if the option is checked first.
  assert_stderr_matches "interp: a mistyped --explain is refused before the clip is scanned" \
    "unknown option '--explan'" \
    python "$R" recommend "$W/does_not_exist.mp4" --explan
  assert_stderr_matches "interp: an extra argument to 'why' is refused" \
    "unexpected extra argument" \
    python "$R" why extra_garbage
  assert_stderr_matches "interp: an extra argument to 'measure' is refused" \
    "unexpected extra argument" \
    python "$R" measure "$W/static.mp4" extra_garbage
  # The rationale above names 'interpolate' specifically - an extra argument there was
  # the case that used to reach the (expensive) model instead of stopping at the arity
  # check. The guard runs before any model import, so this needs no real input file to
  # stay CUDA-independent: it never gets far enough to open one.
  assert_stderr_matches "interp: an extra argument to 'interpolate' is refused" \
    "unexpected extra argument" \
    python "$R" interpolate nonexistent_src.mp4 nonexistent_dst.mp4 60 1.0 extra_garbage

  # An unknown INTERP must not fall through to a default the caller did not ask for.
  SRC="$W/isrc.mp4"; RAW="$W/iraw.mp4"; IOUT="$W/iout"; mkdir -p "$IOUT"
  mk_vfr_source "$SRC" 40 5 8
  mk_upscaled "$RAW" "$(frame_count "$SRC")"
  clean_iout() { rm -rf "$IOUT"; mkdir -p "$IOUT"; }
  clean_iout; assert_stderr_matches "interp: an unknown INTERP is refused" "unknown INTERP" \
    env INTERP=bogus bash "$REPO/pipeline/finish.sh" "$RAW" I "$SRC" "$IOUT"

  # Refused before any work runs, not after it - a typo'd INTERP must not pay for luma-fix,
  # cadence-restore and grading first. Reproduced the old behaviour before fixing it: with
  # validation left at its original spot (after grading, before interpolation), this same
  # scenario left I_lumafix_14fps.mp4 sitting in IOUT despite the nonzero exit.
  if [ -f "$IOUT/I_lumafix_14fps.mp4" ]; then
    bad "interp: an unknown INTERP is refused before any stage runs" \
        "I_lumafix_14fps.mp4 exists - grading (and everything before it) ran first"
  else
    ok "interp: an unknown INTERP is refused before any stage runs"
  fi

  # Forcing rife when it is not installed must refuse, not quietly produce the output the
  # caller explicitly asked not to have.
  clean_iout; assert_stderr_matches "interp: forced rife without a setup is refused" \
    "RIFE cannot run here" \
    env INTERP=rife RIFE_HOME="$W/no-such-rife" bash "$REPO/pipeline/finish.sh" "$RAW" I "$SRC" "$IOUT"

  # Same property, forced-RIFE side: a re-run of an existing TAG with a bad RIFE_HOME must
  # not leave a stale 60fps deliverable beside freshly-replaced 14fps ones. Reproduced: with
  # the availability probe left at its original spot, this refusal happened AFTER both
  # 14fps files were already moved into IOUT.
  if [ -f "$IOUT/I_lumafix_14fps.mp4" ]; then
    bad "interp: forced rife without a setup is refused before any stage runs" \
        "I_lumafix_14fps.mp4 exists - grading (and everything before it) ran first"
  else
    ok "interp: forced rife without a setup is refused before any stage runs"
  fi

  # The recommendation must not depend on output size. Block motion in pixels scales with
  # resolution, so a 60px threshold judged the SAME footage "minterpolate" at width 440 and
  # "rife" at width 520 — decided by the render size rather than by the motion, and this
  # pipeline renders at both 720p and 1080p. The measure is a fraction of width for that
  # reason; this pins it.
  # Rendered NATIVELY at both sizes, not one derived by upscaling the other. An earlier
  # version of this fixture bicubic-upscaled the 1x render 4x before re-measuring it, and
  # that upscale step itself introduced a resolution-dependent optical-flow artifact
  # (verified: the OLD un-windowed statistic already showed a 6.2x spread between the two
  # from this cause alone, just landing both sides of the old 3% threshold so the test
  # passed by coincidence). Two independent native renders of the same pan speed - the
  # comparison real 720p/1080p footage actually is - avoid that confound entirely.
  # Pan speed chosen for a WIDE margin from MOTION_THRESHOLD (6%), not just any speed
  # that lands on one side. A first version measured 5.06%/5.65% - only ~1pt below
  # threshold - and passed locally but failed in CI: a different ffmpeg/OpenCV build
  # measures optical flow on the exact same synthetic pan slightly differently, and a
  # ~1pt margin was not enough to survive that. This version measures ~3.1%/3.2%, roughly
  # half the threshold, which cross-platform floating-point noise in flow estimation is
  # not expected to close.
  RSRC="$W/ires.mp4"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=s=320x240:r=15:d=4" -frames:v 40 \
    -vf "crop=280:210:min(iw-280\,n*1):15" -c:v libx264 -crf 18 -pix_fmt yuv420p "$RSRC"
  RSMALL="$(python "$REPO/pipeline/rife.py" recommend "$RSRC" 2>/dev/null)"
  RBIGSRC="$W/ires_big_native.mp4"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=s=1280x960:r=15:d=4" -frames:v 40 \
    -vf "crop=1120:840:min(iw-1120\,n*4):60" -c:v libx264 -crf 18 -pix_fmt yuv420p "$RBIGSRC"
  RBIG="$(python "$REPO/pipeline/rife.py" recommend "$RBIGSRC" 2>/dev/null)"
  if [ -n "$RSMALL" ] && [ "$RSMALL" = "$RBIG" ]; then
    ok "interp: the same footage picks the same interpolator at 1x and 4x ($RSMALL)"
  else
    bad "interp: the same footage picks the same interpolator at 1x and 4x" \
        "1x said '${RSMALL:-<none>}', 4x said '${RBIG:-<none>}'"
  fi

  # available() must ask the same question the caller asks. finish.sh runs the venv
  # interpreter directly, so a python that EXISTS but is not executable used to pass the
  # availability check and then fall through to the system python — no torch, or the wrong
  # torch, and a failure reported from deep inside the model instead of here.
  FAKE="$W/fake_rife"
  mkdir -p "$FAKE/venv/bin" "$FAKE/Practical-RIFE/train_log"
  printf '#!/bin/sh\nexit 0\n' > "$FAKE/venv/bin/python"
  : > "$FAKE/Practical-RIFE/train_log/flownet.pkl"
  : > "$FAKE/Practical-RIFE/train_log/RIFE_HDv3.py"
  : > "$FAKE/Practical-RIFE/train_log/IFNet_HDv3.py"
  chmod -x "$FAKE/venv/bin/python"
  AV="$(rife_available "$FAKE")"
  assert_eq "interp: a non-executable venv python counts as unavailable" "no" "$AV"
  chmod +x "$FAKE/venv/bin/python"
  AV2="$(rife_available "$FAKE")"
  assert_eq "interp: an executable venv python counts as available" "yes" "$AV2"

  # The output clock must be evenly spaced at every source rate. This is the property
  # "no judder" actually means, and it is asserted on the SCHEDULE rather than on rendered
  # frames: RIFE's output on synthetic footage is not a reliable cadence measurement,
  # because a textureless test pattern gives it nothing to estimate flow from. The
  # schedule is the part this repository decides.
  #
  # The defect it replaces: interpolating to a whole-number multiple and resampling to 60
  # afterwards. 24fps x3 is 72fps, and `fps=60` on that advanced the picture in a mix of
  # 1/72 and 2/72 steps and repeated some frames outright — measured 0/1/2-frame steps
  # across one second — while frame count, rate and duration all looked correct.
  # 48 frames divides evenly against every rate below; 46 does not, and that is the point
  # of including it - round()-based rounding can land BELOW the true target for a
  # non-aligned count, so a suite that only ever tries 48 never exercises the case where
  # the schedule falls short.
  #
  # The target itself is the clip's FULL playback duration (n_src/src_fps seconds), not
  # the position of the last frame's START ((n_src-1)/src_fps) - n_src frames each occupy
  # 1/src_fps seconds, so stopping at the last frame's start is one frame-duration short of
  # the clip actually ending. Reproduced: 15 frames of real 15fps source (1.0s) used to
  # schedule only 57 output frames at 60fps (0.95s), not 60 - a real 50ms short for the
  # documented standalone `interpolate` CLI, which has no padding step of its own;
  # finish.sh's tpad/trim masks it for the one caller that has one, by padding to a
  # duration computed independently from the real source's timestamps.
  SCHED="$(python - "$REPO" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/pipeline")
import rife
bad = []
for n_src in (46, 48):
    for src, tgt in ((15, 60), (24, 60), (25, 60), (30, 60), (14.75, 60), (60, 60)):
        sched = rife.output_schedule(n_src, src, tgt)
        pos = [i + f for i, f in sched]
        steps = [b - a for a, b in zip(pos, pos[1:])]
        if not steps:
            bad.append(f"{n_src}@{src}->{tgt}: no steps"); continue
        ideal = src / tgt
        worst = max(abs(s - ideal) for s in steps)
        if worst > 1e-9:
            bad.append(f"{n_src}@{src}->{tgt}: step deviates by {worst:.3e} (ideal {ideal:.4f})")
        if any(i > n_src - 1 or i < 0 for i, _ in sched):
            bad.append(f"{n_src}@{src}->{tgt}: source index out of range")
        covered = len(sched) / tgt
        true_duration = n_src / src
        if covered < true_duration - 1e-6:
            bad.append(f"{n_src}@{src}->{tgt}: schedule covers {covered:.4f}s, short of the true {true_duration:.4f}s")
print("ok" if not bad else "bad: " + "; ".join(bad[:3]))
PY
)"
  assert_eq "interp: the 60fps output clock is evenly spaced and covers the clip's full duration at every source rate" "ok" "$SCHED"

  # Downsampling must be refused, not scheduled. A lower target means the schedule can
  # skip source frames entirely - interpolate()'s decoder is never asked to produce them,
  # and closing its stdout before it finishes writing the rest of the file makes ffmpeg
  # exit on a broken pipe, which interpolate() would then report as "unreadable input"
  # for a decode that was actually fine. Reproduced directly (outside this suite, since it
  # needs a real ffmpeg subprocess, not the schedule alone): closing a decoder's stdout
  # after reading only 8 of its 10 written frames makes it exit nonzero on a broken pipe.
  assert_stderr_matches "interp: downsampling (a lower target than source rate) is refused" \
    "only interpolates UP" \
    python -c "import sys;sys.path.insert(0,'$REPO/pipeline');import rife;rife.output_schedule(10, 60, 30)"
  # The equal-rate case is not downsampling and must still be accepted - a caller asking
  # for the rate it already has is a (harmless) no-op, not a rate reduction.
  assert_eq "interp: an equal source and target rate is still accepted" \
    "10" "$(python -c "import sys;sys.path.insert(0,'$REPO/pipeline');import rife;print(len(rife.output_schedule(10, 15, 15)))")"

  # Motion after the first 400 frames must still count. The old default measured only the
  # opening, so a clip that is static early and pans later was recommended minterpolate -
  # exactly the footage this tool exists to catch.
  LATE="$W/ilate.mp4"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=gray:s=160x120:r=15:d=30" \
    -f lavfi -i "testsrc2=s=320x240:r=15:d=8" \
    -filter_complex "[0:v]trim=end_frame=420,setpts=PTS-STARTPTS[a];\
[1:v]trim=end_frame=60,setpts=PTS-STARTPTS,crop=160:120:min(iw-160\,n*16):40[b];[a][b]concat=n=2:v=1[v]" \
    -map "[v]" -frames:v 480 -c:v libx264 -crf 18 -pix_fmt yuv420p "$LATE"
  LATE_ALL="$(python "$G_RIFE" recommend "$LATE" 2>/dev/null)"
  LATE_400="$(python - "$REPO" "$LATE" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/pipeline")
import rife
m = rife.block_motion(sys.argv[2], sample=400)
print("rife" if m > rife.MOTION_THRESHOLD else "minterpolate")
PY
)"
  if [ "$LATE_ALL" = "rife" ] && [ "$LATE_400" = "minterpolate" ]; then
    ok "interp: a pan after frame 400 still selects rife (opening-only said $LATE_400)"
  else
    bad "interp: a pan after frame 400 still selects rife" \
        "whole clip said '${LATE_ALL:-<none>}', first 400 said '${LATE_400:-<none>}'"
  fi

  # A severe pan under 5% of the clip's total length must still select rife. p95 over
  # the whole clip discards its top 5% by definition, so a single clip-wide percentile
  # cannot see a real, severe pan shorter than that share - reproduced: 40 fast-panning
  # frames in a 990-frame clip (4.0%, same pan speed the 12.5% fixture above correctly
  # catches) measured 0.00% and picked minterpolate before block_motion was windowed.
  SHORTPAN="$W/ishortpan.mp4"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=gray:s=160x120:r=15:d=70" \
    -f lavfi -i "testsrc2=s=320x240:r=15:d=6" \
    -filter_complex "[0:v]trim=end_frame=950,setpts=PTS-STARTPTS[a];\
[1:v]trim=end_frame=40,setpts=PTS-STARTPTS,crop=160:120:min(iw-160\,n*20):40[b];[a][b]concat=n=2:v=1[v]" \
    -map "[v]" -frames:v 990 -c:v libx264 -crf 18 -pix_fmt yuv420p "$SHORTPAN"
  SHORTPAN_REC="$(python "$REPO/pipeline/rife.py" recommend "$SHORTPAN" 2>/dev/null)"
  assert_eq "interp: a severe pan under 5% of the clip still selects rife" "rife" "$SHORTPAN_REC"

  # A severe pan confined to the clip's closing ~1s must still select rife, even when it
  # does not align with the stride grid. The grid's starts are 0, stride, 2*stride, ... and
  # stop at the last multiple <= (len(arr) - win); when (len(arr) - win) is not itself a
  # multiple of stride, the true final window is never tried on its own, only ever
  # diluted alongside earlier, calmer frames inside the nearest window the grid does reach.
  # 70 calm frames + a 15-frame pan (chosen so the gap is present, verified by direct
  # computation rather than assumed) reproduced it: 4.70% with only the grid's windows
  # (picks minterpolate) against 8.64% once the true final window is included (picks rife).
  TAILPAN="$W/itailpan.mp4"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "color=c=gray:s=160x120:r=15:d=10" \
    -f lavfi -i "testsrc2=s=320x240:r=15:d=2" \
    -filter_complex "[0:v]trim=end_frame=70,setpts=PTS-STARTPTS[a];\
[1:v]trim=end_frame=15,setpts=PTS-STARTPTS,crop=160:120:min(iw-160\,n*7):40[b];[a][b]concat=n=2:v=1[v]" \
    -map "[v]" -frames:v 85 -c:v libx264 -crf 18 -pix_fmt yuv420p "$TAILPAN"
  TAILPAN_REC="$(python "$REPO/pipeline/rife.py" recommend "$TAILPAN" 2>/dev/null)"
  assert_eq "interp: a severe pan confined to the clip's closing second still selects rife" \
    "rife" "$TAILPAN_REC"

  # A partial setup must not pass. interpolate() does `from train_log.RIFE_HDv3 import
  # Model`, so weights alone are not enough: the old check looked only for flownet.pkl and
  # let a half-installed model through to fail with ModuleNotFoundError from inside the
  # import — the exact failure this guard exists to pre-empt.
  rm -f "$FAKE/Practical-RIFE/train_log/IFNet_HDv3.py"
  AV4="$(rife_available "$FAKE")"
  assert_eq "interp: a model missing IFNet_HDv3.py counts as unavailable" "no" "$AV4"
  : > "$FAKE/Practical-RIFE/train_log/IFNet_HDv3.py"

  rm -f "$FAKE/Practical-RIFE/train_log/RIFE_HDv3.py"
  AV3="$(rife_available "$FAKE")"
  assert_eq "interp: weights without the model code count as unavailable" "no" "$AV3"
  : > "$FAKE/Practical-RIFE/train_log/RIFE_HDv3.py"

  # Files present is not the same as importable. A venv without torch — or with one built
  # for a different CUDA line — passes every file check and then fails deep inside the
  # model, after auto-selection has already committed to RIFE. available() asks the
  # interpreter that will actually run it; this fixture has every file and an interpreter
  # that cannot import.
  BROKEN="$W/broken_rife"
  mkdir -p "$BROKEN/venv/bin" "$BROKEN/Practical-RIFE/train_log"
  printf '#!/bin/sh\nexit 1\n' > "$BROKEN/venv/bin/python"
  chmod +x "$BROKEN/venv/bin/python"
  for fpart in flownet.pkl RIFE_HDv3.py IFNet_HDv3.py; do
    : > "$BROKEN/Practical-RIFE/train_log/$fpart"
  done
  AV5="$(rife_available "$BROKEN")"
  assert_eq "interp: a venv that cannot import the model counts as unavailable" "no" "$AV5"

  # The two asserts INSIDE the probe (torch.cuda.is_available(), then an actual kernel
  # launch) were not pinned by anything above: every fixture's "venv/bin/python" is a
  # shell script that exits 0 or 1 unconditionally, ignoring the probe source it is
  # handed, so deleting either assert from unavailable_reason() would still leave every
  # test above green. Both fixtures below use a REAL python interpreter with a fake
  # `torch` and `train_log.RIFE_HDv3` on PYTHONPATH, so the probe's own source actually
  # runs - one where cuda.is_available() is False, one where it is True but the kernel
  # launch itself raises (the shape of the Blackwell-no-kernels case CLAUDE.md records).
  mkfake_rife_probe() {  # mkfake_rife_probe <dir> <torch.py contents via stdin>
    local dir="$1"
    mkdir -p "$dir/venv/bin" "$dir/Practical-RIFE/train_log" "$dir/fakemods"
    for fpart in flownet.pkl IFNet_HDv3.py; do
      : > "$dir/Practical-RIFE/train_log/$fpart"
    done
    printf 'class Model:\n    pass\n' > "$dir/Practical-RIFE/train_log/RIFE_HDv3.py"
    cat > "$dir/fakemods/torch.py"
    printf '#!/bin/sh\nexec env PYTHONPATH="%s" python3 "$@"\n' "$dir/fakemods" \
      > "$dir/venv/bin/python"
    chmod +x "$dir/venv/bin/python"
  }

  NOCUDA="$W/nocuda_rife"
  mkfake_rife_probe "$NOCUDA" <<'PY'
class _Cuda:
    @staticmethod
    def is_available():
        return False
cuda = _Cuda()
def ones(*a, **k):
    raise AssertionError("should not be reached: is_available() already returned False")
PY
  AV6="$(rife_available "$NOCUDA")"
  assert_eq "interp: a venv that imports fine but reports no CUDA device counts as unavailable" \
    "no" "$AV6"

  NOKERNEL="$W/nokernel_rife"
  mkfake_rife_probe "$NOKERNEL" <<'PY'
class _Cuda:
    @staticmethod
    def is_available():
        return True
cuda = _Cuda()
class _NoKernelTensor:
    def sum(self):
        raise RuntimeError("no kernel image is available for execution on the device")
def ones(*a, **k):
    return _NoKernelTensor()
PY
  AV7="$(rife_available "$NOKERNEL")"
  assert_eq "interp: a venv that reports CUDA but cannot launch a kernel counts as unavailable" \
    "no" "$AV7"

  # RIFE_HOME="" must resolve the same way rife.py's own bash caller resolves it.
  # finish.sh reads it as `${RIFE_HOME:-default}`, which treats an explicitly empty value
  # as unset. `os.environ.get("RIFE_HOME", default)` does not - it only substitutes the
  # default when the key is ABSENT, so an empty string used to resolve to abspath(""),
  # the cwd at import time, while finish.sh kept using the real default path. The two
  # halves of the pipeline would then probe and run two different installations.
  EMPTYHOME="$(RIFE_HOME="" python -c "
import sys
sys.path.insert(0, '$REPO/pipeline')
import rife
print(rife.RIFE_HOME)")"
  assert_eq "interp: an explicitly empty RIFE_HOME resolves to the same default as unset" \
    "$REPO/work/rife" "$EMPTYHOME"

  # --explain must actually explain. finish.sh reads the recommendation from line 1 and the
  # measurement from line 2 of ONE call; if the second line goes missing the log silently
  # loses the number that justified the choice.
  EXPL="$(python "$REPO/pipeline/rife.py" recommend "$W/ires.mp4" --explain 2>/dev/null)"
  case "$(printf '%s\n' "$EXPL" | sed -n 2p)" in
    *"block motion"*"% of width"*) ok "interp: recommend --explain reports the measurement" ;;
    *) bad "interp: recommend --explain reports the measurement" \
           "second line was: $(printf '%s\n' "$EXPL" | sed -n 2p)" ;;
  esac

  clean_iout
  out="$(env INTERP=minterpolate bash "$REPO/pipeline/finish.sh" "$RAW" I "$SRC" "$IOUT" 2>&1)"
  if [ -f "$IOUT/I_lumafix_K5.mp4" ]; then ok "interp: explicit minterpolate still completes"
  else bad "interp: explicit minterpolate still completes" "$(printf '%s' "$out" | tail -1)"; fi

  # ...and auto must fall BACK rather than fail, since minterpolate still produces
  # something watchable for most footage. The comment above used to sit on the test
  # immediately preceding it, which runs INTERP=minterpolate explicitly and therefore
  # never went near the fallback: auto was not exercised, and neither was its warning.
  # RIFE_HOME points somewhere empty, so `available()` is false and the branch is forced.
  # The fallback only exists on the rife branch, so the fixture has to actually recommend
  # rife and the assertion has to say so. Matching any "auto -> " line accepted a run that
  # chose minterpolate and never entered the fallback at all — and the previous fixture sat
  # at 3.80% against a 3.0% threshold, close enough to drift across it silently.
  clean_iout
  PANSRC="$W/ipan.mp4"
  mk_vfr_source "$PANSRC" 40 5 8
  PANRAW="$W/ipanraw.mp4"
  # A hard horizontal pan: unambiguously above the threshold, not marginally so.
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=s=320x240:r=15:d=6" \
    -frames:v "$(frame_count "$PANSRC")" \
    -vf "crop=160:120:min(iw-160\,n*14):40,scale=64:36" \
    -c:v libx264 -crf 18 -pix_fmt yuv420p "$PANRAW"
  PANREC="$(python "$REPO/pipeline/rife.py" recommend "$PANRAW" --explain 2>/dev/null)"
  case "$(printf '%s\n' "$PANREC" | sed -n 1p)" in
    rife) ok "interp: the fallback fixture does recommend rife ($(printf '%s\n' "$PANREC" | sed -n 2p))" ;;
    *) bad "interp: the fallback fixture does recommend rife" \
           "fixture recommends '$(printf '%s\n' "$PANREC" | sed -n 1p)' — it cannot exercise the fallback" ;;
  esac

  out="$(env INTERP=auto RIFE_HOME="$W/no_rife_here" bash "$REPO/pipeline/finish.sh" \
    "$PANRAW" I "$PANSRC" "$IOUT" 2>&1)"
  if [ ! -f "$IOUT/I_lumafix_K5.mp4" ]; then
    bad "interp: auto falls back to minterpolate when RIFE is absent" \
        "no deliverable: $(printf '%s' "$out" | tail -1)"
  else
    case "$out" in
      *"auto -> rife"*"cannot run here"*) ok "interp: auto falls back to minterpolate when RIFE is absent" ;;
      *"auto -> rife"*) bad "interp: auto falls back to minterpolate when RIFE is absent" \
             "chose rife but printed no fallback warning" ;;
      *) bad "interp: auto falls back to minterpolate when RIFE is absent" \
             "never reached the rife branch: $(printf '%s' "$out" | grep -- '-> ' | head -1)" ;;
    esac
  fi

  # An unmeasurable render during auto-select must not abort finish.sh. This is the
  # defect a bare `RECO="$(rife.py recommend ...)"` produced under set -e: motion
  # measurement failing killed the pipeline AFTER luma-fix, cadence-restore and grading
  # had already run, instead of falling back to minterpolate. Verified by forcing
  # `recommend` to fail in a patched COPY of the pipeline directory (rife.py's own guards
  # already refuse a too-short render cleanly, so triggering the failure through a real
  # clip would test THOSE guards, not this one) and running the real finish.sh against it
  # end to end.
  # Mirrors <repo>/pipeline/, not a flat copy: finish.sh derives REPO from its own
  # location as "$HERE/.." and then imports timing.py as "$REPO/pipeline/timing" - a flat
  # copy breaks that assumption and fails before ever reaching the code under test here.
  PIPECOPY="$W/pipecopy"; rm -rf "$PIPECOPY"; mkdir -p "$PIPECOPY/pipeline"
  cp "$REPO/pipeline/finish.sh" "$REPO/pipeline/luma_stabilise.py" \
     "$REPO/pipeline/timing.py" "$REPO/pipeline/grade.py" "$REPO/pipeline/rife.py" \
     "$REPO/pipeline/selective_interp.py" "$PIPECOPY/pipeline/"
  python - "$PIPECOPY/pipeline/rife.py" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '    elif cmd == "recommend":\n'
new = '    elif cmd == "recommend":\n        sys.exit(1)  # TEST INJECTION: force auto-select to see a failure\n'
assert s.count(old) == 1, f"anchor matched {s.count(old)} times"
open(p, "w").write(s.replace(old, new))
PY
  FSRC="$W/ifail_src.mp4"; FRAW="$W/ifail_raw.mp4"; FOUT="$W/ifail_out"
  mk_vfr_source "$FSRC" 20 5 8
  mk_upscaled "$FRAW" "$(frame_count "$FSRC")"
  rm -rf "$FOUT"; mkdir -p "$FOUT"
  FOUT_LOG="$(bash "$PIPECOPY/pipeline/finish.sh" "$FRAW" IFAIL "$FSRC" "$FOUT" 2>&1)"; FRC=$?
  if [ "$FRC" -ne 0 ] || [ ! -f "$FOUT/IFAIL_lumafix_K5.mp4" ]; then
    bad "interp: an unmeasurable render during auto-select falls back, not aborts" \
        "exit $FRC: $(printf '%s' "$FOUT_LOG" | tail -2 | head -1)"
  else
    case "$FOUT_LOG" in
      *"could not measure motion"*"Falling back to minterpolate"*)
        ok "interp: an unmeasurable render during auto-select falls back, not aborts" ;;
      *) bad "interp: an unmeasurable render during auto-select falls back, not aborts" \
             "deliverable produced but no fallback message: $(printf '%s' "$FOUT_LOG" | tail -1)" ;;
    esac
  fi
fi

# ---------------------------------------------------------------------------
# The cloud runner, driven against stubs. Separate file because it fakes an entire
# environment; run from here so it is not forgotten.
# ---------------------------------------------------------------------------
if want cloud; then
  echo
  # Bounded, because nothing else here is. The suite is meant to finish in seconds with
  # no network and no GPU; if a stub is ever missed and a real command goes looking for
  # one, the symptom should be a named timeout rather than a terminal that never returns.
  # `timeout` reports 124 when it fires, whatever --signal it used: the signal number
  # only reaches the status with --preserve-status, which is not passed. An earlier
  # version of this comment asserted 137 and the branch below never ran.
  CLOUD_TIMEOUT="${CLOUD_TIMEOUT:-300}"
  CLOUD_OUT="$(timeout --signal=KILL "$CLOUD_TIMEOUT" bash "$REPO/tests/cloud_pod.sh" 2>&1)"; CLOUD_STATUS=$?
  printf '%s\n' "$CLOUD_OUT" | sed -n '2,$p' | grep -E 'PASS|FAIL|^$' || true
  # Fold its tally into ours. Strip ANSI first: the colour codes put a word character
  # immediately before PASS, so a \b anchor never matches.
  CLOUD_PLAIN="$(printf '%s' "$CLOUD_OUT" | sed 's/\x1b\[[0-9;]*m//g')"
  CP="$(printf '%s' "$CLOUD_PLAIN" | grep -cE '^  PASS ' || true)"
  CF="$(printf '%s' "$CLOUD_PLAIN" | grep -cE '^  FAIL ' || true)"
  PASS=$((PASS + CP)); FAIL=$((FAIL + CF))
  # A child that crashes before printing any FAIL line reports nothing, so counting only
  # its FAIL lines would let a nonzero exit pass as success. Charge one failure for the
  # exit status itself when it did not account for one.
  if [ "$CLOUD_STATUS" -ne 0 ]; then
    if [ "$CLOUD_STATUS" -eq 124 ]; then
      FAILED_NAMES+=("cloud pod runner: killed at the ${CLOUD_TIMEOUT}s timeout — it should take seconds, so suspect a missing stub letting a real command block")
    else
      FAILED_NAMES+=("cloud pod runner (exit $CLOUD_STATUS) — see bash tests/cloud_pod.sh")
    fi
    [ "$CF" -eq 0 ] && FAIL=$((FAIL + 1))
  fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m%d passed\033[0m\n' "$PASS"
else
  printf '\033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n' "$PASS" "$FAIL"
  for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
fi
[ "$FAIL" -eq 0 ]
