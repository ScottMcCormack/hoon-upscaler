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
_, decoded = grade.histogram(sys.argv[2], 1)
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
