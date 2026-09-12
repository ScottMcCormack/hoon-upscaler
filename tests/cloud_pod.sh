#!/bin/bash
# Exercise cloud/run_on_pod.sh without a GPU.
#
# The script it tests only ever runs on a rented pod, which makes every mistake in it
# cost money and an hour of setup before it surfaces. Everything except the actual
# SeedVR2 inference is ordinary shell logic, so it can be driven here against stubs:
# nvidia-smi reports whatever VRAM the case wants, and the inference step writes a file
# with whatever frame count the case wants.
#
# What this canNOT tell you: anything about the environment the script lands in. The
# stub pip is a no-op, so it sailed past the PEP 668 failure that killed the first real
# pod run before inference even started (docs/findings.md). It proves the script's own
# logic — branch selection, guards, the frame check — and nothing beyond that.
#
#   bash tests/cloud_pod.sh
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/tests/lib.sh"

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
STUB="$W/stub"; mkdir -p "$STUB"

# --- stubs ------------------------------------------------------------------
cat > "$STUB/nvidia-smi" <<'EOF'
#!/bin/bash
# STUB_VRAM controls the reported total; STUB_GPU the name.
case "$*" in
  *nounits*)                    echo "${STUB_VRAM:-49140}" ;;
  *--query-gpu=name\ *|*--query-gpu=name) echo "${STUB_GPU:-NVIDIA A40}" ;;
  *)                            echo "${STUB_GPU:-NVIDIA A40}, ${STUB_VRAM:-49140} MiB" ;;
esac
EOF

cat > "$STUB/python" <<'EOF'
#!/bin/bash
# Three call shapes matter: the CUDA probe, the version banner, and inference.
if [ "${1:-}" = "-c" ]; then
  case "$2" in
    *sys.exit*cuda.is_available*) exit "${STUB_NO_CUDA:-0}" ;;
    *print\(torch.__version__\)*) echo "2.4.0"; exit 0 ;;           # the manifest reads this
    *EXTERNALLY-MANAGED*)         exit 1 ;;                        # not a PEP 668 env
    *)                            echo "  torch 2.4.0  cuda=True  ${STUB_GPU:-NVIDIA A40}"; exit 0 ;;
  esac
fi
if [ "${1:-}" = "inference_cli.py" ]; then
  # find --output
  out=""; prev=""
  for a in "$@"; do [ "$prev" = "--output" ] && out="$a"; prev="$a"; done
  echo "  [stub] would upscale $2 -> $out"
  echo "  [stub] argv: $*"
  [ "${STUB_NO_OUTPUT:-0}" = "1" ] && exit 0          # ran, produced nothing
  # A different pattern and size from the input fixture, deliberately. Generating both
  # from the same testsrc2 made them byte-identical, so input and output shared a sha256
  # and a bug that recorded the input's hash for the output would have been invisible.
  # A real upscale changes both content and dimensions; the fixture should too.
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "smptebars=s=128x72:r=15:d=30" \
    -frames:v "${STUB_OUT_FRAMES:-214}" -c:v libx264 -crf 30 -pix_fmt yuv420p "$out"
  exit 0
fi
exec /usr/bin/env python3 "$@"
EOF

for noop in pip apt-get; do
  printf '#!/bin/bash\nexit 0\n' > "$STUB/$noop"
done
# git must answer rev-parse with something commit-shaped. A blanket `exit 0` returns an
# empty string AND exits 0, so the script's `|| echo unknown` fallback never fires and
# the manifest silently records seedvr2_commit="" — which the test then accepted.
cat > "$STUB/git" <<'EOF'
#!/bin/bash
case "$*" in
  *rev-parse*) echo "4490bd1f482e026674543386bb2a4d176da245b9" ;;
  *)           exit 0 ;;
esac
EOF
chmod +x "$STUB"/*

# --- fixtures ---------------------------------------------------------------
WS="$W/workspace"; mkdir -p "$WS/SeedVR2"
printf 'torch\ntorchvision\nsafetensors\nomegaconf\n' > "$WS/SeedVR2/requirements.txt"

CLOUD="$W/cloud"; mkdir -p "$CLOUD"
cp "$REPO/cloud/run_on_pod.sh" "$CLOUD/"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=s=64x36:r=15:d=30" \
  -frames:v 214 -c:v libx264 -crf 30 -pix_fmt yuv420p "$CLOUD/test_15s.mp4"
# A second source, to prove a named clip does not read or write the first one's files.
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=s=64x36:r=15:d=30" \
  -frames:v 214 -c:v libx264 -crf 30 -pix_fmt yuv420p "$CLOUD/demo_test.mp4"

# Each case must start clean: an output left by a previous case would satisfy the
# "did inference produce a file?" check and mask a real failure.
# Manifests too, not just videos: the override case writes sr_test_720.json before the
# happy-path manifest check runs, so a stale one would satisfy that check even if the
# happy path stopped producing it.
clean() { rm -f "$CLOUD"/sr_*.mp4 "$CLOUD"/sr_*.json; }

run_pod() {  # env... -- args...
  clean
  env PATH="$STUB:$PATH" WORKSPACE="$WS" "$@" 2>&1
}

echo "cloud pod runner"
echo

# --- VRAM branch selection --------------------------------------------------
# Picking the wrong branch is not an error, it is a slow expensive success: the
# offload path was 19x slower on a card that never needed it.
# Card names are the ones actually measured at these VRAM figures (docs/findings.md),
# so a reader chasing a branch can find the run that justified it.
for case in "49140:batch 33:A40 48GB" "24564:batch 17:RTX 4090 24GB" "16376:fp8 with offloading:RTX A4000 16GB"; do
  vram="${case%%:*}"; rest="${case#*:}"; want="${rest%%:*}"; label="${rest#*:}"
  out="$(STUB_VRAM="$vram" run_pod bash "$CLOUD/run_on_pod.sh" 720 test)"
  case "$out" in
    *"$want"*) ok "vram: $label selects '$want'" ;;
    *) bad "vram: $label selects '$want'" "got: $(printf '%s' "$out" | grep '###' | tail -1)" ;;
  esac
done

# Selecting the right branch is not the same as invoking it correctly. Only the top
# branch's real arguments were ever checked (via the happy-path manifest); the other two
# were confirmed only by their banner text, so changing the fp8 branch's EXTRA to
# "--batch_size 999 --temporal_overlap 999" passed the whole suite. The bottom branch is
# the least checked and the most complex - it carries the offload flags and covers the
# widest VRAM range - so it is the one most worth pinning.
for case in "24564:720:seedvr2_ema_3b_fp16.safetensors:17:3" \
            "16376:540:seedvr2_ema_3b_fp8_e4m3fn.safetensors:17:3"; do
  IFS=: read -r vram res model wb wt <<< "$case"
  clean
  STUB_VRAM="$vram" run_pod bash "$CLOUD/run_on_pod.sh" "$res" test >/dev/null 2>&1 || true
  BMAN="$CLOUD/sr_test_${res}.json"
  if [ ! -f "$BMAN" ]; then
    bad "vram ${vram}MB: manifest records the branch it actually ran" "no $BMAN"
  else
    BV="$(python - "$BMAN" "$model" "$wb" "$wt" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
want_model, want_b, want_t = sys.argv[2:5]
bad = []
if m.get("model") != want_model:
    bad.append(f"model {m.get('model')!r}, want {want_model!r}")
ex = m.get("extra_args", [])
for flag, want in (("--batch_size", want_b), ("--temporal_overlap", want_t)):
    if flag not in ex or ex[ex.index(flag) + 1] != want:
        bad.append(f"{flag} not {want} in {ex!r}")
print("ok" if not bad else "bad: " + "; ".join(bad))
PY
)"
    [ "$BV" = "ok" ] && ok "vram ${vram}MB: manifest records the branch it actually ran" \
                     || bad "vram ${vram}MB: manifest records the branch it actually ran" "$BV"
  fi
done

# The low-VRAM branch must warn before a resolution that is known to OOM there.
out="$(STUB_VRAM=16376 run_pod bash "$CLOUD/run_on_pod.sh" 720 test)"
case "$out" in *"likely to run out of memory"*) ok "vram: 16GB at 720 warns about OOM" ;;
  *) bad "vram: 16GB at 720 warns about OOM" "no warning emitted" ;; esac
out="$(STUB_VRAM=16376 run_pod bash "$CLOUD/run_on_pod.sh" 540 test)"
case "$out" in *"likely to run out of memory"*) bad "vram: 16GB at 540 does not warn" "warned unnecessarily" ;;
  *) ok "vram: 16GB at 540 does not warn" ;; esac

# Reproducing a recorded master means replaying its parameters, not re-deriving them
# from whatever card you happened to rent.
out="$(clean; env PATH="$STUB:$PATH" WORKSPACE="$WS" STUB_VRAM=49140 BATCH_SIZE=65 TEMPORAL_OVERLAP=5 \
  bash "$CLOUD/run_on_pod.sh" 720 test 2>&1)"
case "$out" in *"OVERRIDE: batch 65"*) ok "override: BATCH_SIZE replaces the VRAM-derived batch" ;;
  *) bad "override: BATCH_SIZE replaces the VRAM-derived batch" "no override line" ;; esac
case "$out" in
  *"[stub] argv:"*"--batch_size 65"*) ok "override: inference is actually invoked with batch 65" ;;
  *) bad "override: inference is actually invoked with batch 65" \
       "$(printf '%s' "$out" | grep -o '\-\-batch_size [0-9]*' | tail -1)" ;;
esac

# Setting one override must not disturb the other. This silently rewrote batch 17 to 33
# on a 24GB card when only TEMPORAL_OVERLAP was given.
out="$(clean; env PATH="$STUB:$PATH" WORKSPACE="$WS" STUB_VRAM=24564 TEMPORAL_OVERLAP=7 \
  bash "$CLOUD/run_on_pod.sh" 720 test 2>&1)"
case "$out" in
  *"[stub] argv:"*"--batch_size 17"*"--temporal_overlap 7"*)
    ok "override: a lone TEMPORAL_OVERLAP keeps the card-derived batch 17" ;;
  *) bad "override: a lone TEMPORAL_OVERLAP keeps the card-derived batch 17" \
       "$(printf '%s' "$out" | grep -o '\-\-batch_size [0-9]*' | tail -1)" ;;
esac

# Values spliced into the inference command line must be plain integers. "17 --debug_leak"
# would otherwise smuggle in a flag AND be recorded in the manifest as legitimate.
for badval in abc -5 "17 --debug_leak" ""; do
  label="${badval:-empty}"
  clean
  out="$(env PATH="$STUB:$PATH" WORKSPACE="$WS" BATCH_SIZE="$badval" \
    bash "$CLOUD/run_on_pod.sh" 720 test 2>&1)"; st=$?
  if [ -z "$badval" ]; then
    # empty means "not set" — must run normally, not be refused
    case "$out" in *"frame check OK"*) ok "override: an empty BATCH_SIZE is ignored, not refused" ;;
      *) bad "override: an empty BATCH_SIZE is ignored, not refused" "exit $st" ;; esac
  elif [ "$st" -ne 0 ] && [[ "$out" == *"must be a positive integer"* ]]; then
    ok "override: BATCH_SIZE='$label' is refused"
  else
    bad "override: BATCH_SIZE='$label' is refused" "exit $st: $(printf '%s' "$out" | tail -1)"
  fi
done

# RES reaches `[ "$RES" -ge 720 ]`, which errors inside an `if` on a non-integer and so
# escapes set -e — the same trap the VRAM guard exists to close.
clean; assert_stderr_matches "guard: a non-integer resolution is refused" "resolution must be a positive integer" \
  env PATH="$STUB:$PATH" WORKSPACE="$WS" bash "$CLOUD/run_on_pod.sh" 1080p test

# 0 matched ^[0-9]+$ and sailed through a check whose own message said "positive", while
# the override validation twenty lines away already required > 0. The manifest then
# recorded "resolution": 0 as though it were a real render setting.
clean; assert_stderr_matches "guard: a zero resolution is refused" "resolution must be a positive integer" \
  env PATH="$STUB:$PATH" WORKSPACE="$WS" bash "$CLOUD/run_on_pod.sh" 0 test

# Omitting the mode means "full" and is documented that way. Passing an EMPTY mode is a
# wrapper leaking an unset variable, and ${2:-full} silently gave it the chargeable
# render — the one default whose cost makes guessing unacceptable.
clean; assert_stderr_matches "guard: an explicitly empty mode is refused" "mode was given but empty" \
  env PATH="$STUB:$PATH" WORKSPACE="$WS" bash "$CLOUD/run_on_pod.sh" 720 ""

# The same hole on the other positional. ${1:-720} substitutes on empty exactly as
# ${2:-full} did, so a wrapper leaking an unset resolution got 720 AND, with no second
# argument, the chargeable full render — and a manifest reading "resolution": 720 as
# though someone had chosen it. Guarding the mode and not the resolution was the same
# asymmetry that let RES=0 through: the standard has to be applied to every argument,
# not to the one the bug report happened to name.
clean; assert_stderr_matches "guard: an explicitly empty resolution is refused" "resolution was given but empty" \
  env PATH="$STUB:$PATH" WORKSPACE="$WS" bash "$CLOUD/run_on_pod.sh" ""

clean; assert_stderr_matches "guard: an empty resolution is refused even with a mode" "resolution was given but empty" \
  env PATH="$STUB:$PATH" WORKSPACE="$WS" bash "$CLOUD/run_on_pod.sh" "" test

# The same hole again, on the third positional this time. CLIP was added after the RES
# and MODE guards above already existed, and the guard shape was never carried over to
# it - an explicitly empty CLIP silently took the legacy (unnamespaced) branch, which is
# exactly the "second source overwrites the first's master and manifest" failure naming
# a clip exists to prevent. Reproduced directly before fixing: this exact invocation used
# to exit 0 into the legacy IN/OUT paths with no complaint at all.
clean; assert_stderr_matches "guard: an explicitly empty clip is refused" "clip was given but empty" \
  env PATH="$STUB:$PATH" WORKSPACE="$WS" bash "$CLOUD/run_on_pod.sh" 720 test ""

# Extra arguments used to be ignored, so a typo'd flag ran the default render instead.
# The ceiling moved from 2 to 3 when CLIP became a real argument, so this now tests a
# FOURTH argument. With three legal positions, `720 test --dry-run` is no longer an extra
# argument at all - it is a clip named "--dry-run", refused later for a missing input.
clean; assert_stderr_matches "guard: extra arguments are refused" "unexpected extra argument" \
  env PATH="$STUB:$PATH" WORKSPACE="$WS" bash "$CLOUD/run_on_pod.sh" 720 test demo --dry-run

# --help hit the resolution guard and answered "must be a positive integer", which reads
# as though the script were broken rather than as usage.
clean
HELP="$(env PATH="$STUB:$PATH" WORKSPACE="$WS" bash "$CLOUD/run_on_pod.sh" --help 2>&1)"; HST=$?
if [ "$HST" -eq 0 ] && [[ "$HELP" == *"test_15s.mp4"* ]] && [[ "$HELP" != *"positive integer"* ]]; then
  ok "--help prints usage and exits 0"
else
  bad "--help prints usage and exits 0" "exit $HST: $(printf '%s' "$HELP" | tail -1)"
fi

# The no-CLIP output section named only sr_out_<res>.mp4, omitting that test mode (the
# invocation --help itself recommends running first) writes sr_test_<res>.mp4 instead -
# a caller following that advice would not know which file to download. Also checks for
# the LAST usage line (the named-clip example), which a truncated range - this exact
# script's docstring has been cut short twice before - would drop even though
# "test_15s.mp4" alone would not notice.
if [[ "$HELP" == *"sr_test_"* ]] && [[ "$HELP" == *"mvi0081"* ]]; then
  ok "--help documents the test-mode output name and is not truncated"
else
  bad "--help documents the test-mode output name and is not truncated" \
      "sr_test_ present: $([[ "$HELP" == *sr_test_* ]] && echo yes || echo no), mvi0081 present: $([[ "$HELP" == *mvi0081* ]] && echo yes || echo no)"
fi

# --help's range is now selected through the closing "# ====" separator rather than a
# hardcoded line number, precisely so a future docstring edit cannot repeat the last two
# incidents. Proved directly: a patched copy of the script with an extra usage line
# inserted just before that separator (standing in for a real future edit, without
# waiting for one) must still show that line in --help, with no line-count fix needed
# alongside it.
GROWNCOPY="$W/run_on_pod_grown.sh"; cp "$CLOUD/run_on_pod.sh" "$GROWNCOPY"
python - "$GROWNCOPY" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = '#         bash run_on_pod.sh 720 test mvi0081       # a second source, namespaced\n'
new = old + '#         bash run_on_pod.sh 720 test mvi0081 --dry-run  # a hypothetical future option\n'
assert s.count(old) == 1, f"anchor matched {s.count(old)} times"
open(p, "w").write(s.replace(old, new))
PY
GROWNHELP="$(bash "$GROWNCOPY" --help 2>&1)"
case "$GROWNHELP" in
  *"a hypothetical future option"*)
    ok "--help's range adapts when the docstring grows, with no line-count fix needed" ;;
  *) bad "--help's range adapts when the docstring grows, with no line-count fix needed" \
         "new usage line missing: $(printf '%s' "$GROWNHELP" | tail -3)" ;;
esac

# Overriding batch upward is legitimate — it is how the 720p master gets reproduced on a
# smaller card — but it walks toward the VRAM cliff, so it must say so.
clean
UP="$(env PATH="$STUB:$PATH" WORKSPACE="$WS" BATCH_SIZE=65 \
  bash "$CLOUD/run_on_pod.sh" 720 test 2>&1)" || true
case "$UP" in
  *"is above the"*) ok "override: raising batch past the card's own choice warns" ;;
  *) bad "override: raising batch past the card's own choice warns" "no warning: $(printf '%s' "$UP" | tail -1)" ;;
esac

# --- guards -----------------------------------------------------------------
clean; assert_stderr_matches "guard: non-integer VRAM is refused" "could not read VRAM" \
  env PATH="$STUB:$PATH" WORKSPACE="$WS" STUB_VRAM="[N/A]" bash "$CLOUD/run_on_pod.sh" 720 test

clean; assert_stderr_matches "guard: unknown mode is refused" "unknown mode" \
  env PATH="$STUB:$PATH" WORKSPACE="$WS" bash "$CLOUD/run_on_pod.sh" 720 tset

clean; assert_stderr_matches "guard: missing input is refused" "not found" \
  env PATH="$STUB:$PATH" WORKSPACE="$WS" bash "$CLOUD/run_on_pod.sh" 720 full

clean; assert_stderr_matches "guard: a missing workspace is refused" "does not exist" \
  env PATH="$STUB:$PATH" WORKSPACE="$W/nope" bash "$CLOUD/run_on_pod.sh" 720 test

clean; assert_stderr_matches "guard: no CUDA torch is refused" "no working CUDA torch" \
  env PATH="$STUB:$PATH" WORKSPACE="$WS" STUB_NO_CUDA=1 bash "$CLOUD/run_on_pod.sh" 720 test

clean; assert_stderr_matches "guard: inference producing no file is refused" "no output produced" \
  env PATH="$STUB:$PATH" WORKSPACE="$WS" STUB_NO_OUTPUT=1 bash "$CLOUD/run_on_pod.sh" 720 test

# The check the whole script exists for: a crashed run leaves a plausible short file.
clean; assert_stderr_matches "guard: a short render is refused" "frame count mismatch" \
  env PATH="$STUB:$PATH" WORKSPACE="$WS" STUB_OUT_FRAMES=200 bash "$CLOUD/run_on_pod.sh" 720 test

# --- defaults ---------------------------------------------------------------
# Every other case passes both positional arguments, so the values used when they are
# OMITTED were never executed by a test. Flipping MODE's default between the free test
# render and the chargeable full one passed the whole suite. The header documents
# `run_on_pod.sh 720` as the full clip, which makes the default an interface worth
# pinning rather than an accident.
clean
# 214 frames, matching what the stub inference emits: this case is about which
# resolution and mode get chosen, and a frame-count mismatch would mask that.
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=s=64x36:r=15:d=20" \
  -frames:v 214 -c:v libx264 -crf 30 -pix_fmt yuv420p "$CLOUD/full_169.mp4"

out="$(run_pod bash "$CLOUD/run_on_pod.sh")"; status=$?
DEF="$CLOUD/sr_out_720.json"   # full mode renders to sr_out_<res>, as the masters are named
if [ "$status" -ne 0 ]; then
  bad "defaults: no arguments means 720 and full" "exit $status: $(printf '%s' "$out" | tail -1)"
elif [ ! -f "$DEF" ]; then
  bad "defaults: no arguments means 720 and full" "expected manifest $DEF, got: $(ls "$CLOUD"/sr_*.json 2>/dev/null | tr '\n' ' ')"
else
  V="$(python - "$DEF" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
b = []
if m.get("resolution") != 720: b.append(f"resolution {m.get('resolution')!r}, want 720")
if m.get("mode") != "full":    b.append(f"mode {m.get('mode')!r}, want 'full'")
if m.get("input", {}).get("file") != "full_169.mp4":
    b.append(f"input {m.get('input', {}).get('file')!r}, want 'full_169.mp4'")
print("ok" if not b else "bad: " + "; ".join(b))
PY
)"
  [ "$V" = "ok" ] && ok "defaults: no arguments means 720 and full" \
                  || bad "defaults: no arguments means 720 and full" "$V"
fi

# The mode default alone, without depending on the render succeeding.
clean; rm -f "$CLOUD/full_169.mp4"
assert_stderr_matches "defaults: with no mode it looks for the full clip, not the test one" \
  "full_169.mp4" env PATH="$STUB:$PATH" WORKSPACE="$WS" bash "$CLOUD/run_on_pod.sh" 720

# --- a second clip ----------------------------------------------------------
# Two sources sharing one output name is the failure this argument exists to prevent:
# the second render overwrites the first's master AND its manifest, and the manifest is
# the only record of how that master was made.
out="$(run_pod bash "$CLOUD/run_on_pod.sh" 720 test demo)"
case "$out" in
  *"[stub] would upscale"*"demo_test.mp4"*) ok "clip: a named clip reads <clip>_<mode>.mp4" ;;
  *) bad "clip: a named clip reads <clip>_<mode>.mp4" "$(printf '%s' "$out" | grep 'would upscale')" ;;
esac
if [ -f "$CLOUD/sr_demo_test_720.mp4" ]; then ok "clip: writes sr_<clip>_<mode>_<res>.mp4"
else bad "clip: writes sr_<clip>_<mode>_<res>.mp4" "no sr_demo_test_720.mp4"; fi
if [ -f "$CLOUD/sr_test_720.mp4" ]; then
  bad "clip: does not write the legacy output name" "sr_test_720.mp4 was created too"
else ok "clip: does not write the legacy output name"; fi

# The manifest is namespaced the same way the video is - MANIFEST is derived from OUT,
# not re-derived from CLIP independently, so a regression that broke that derivation
# (or hardcoded the manifest path elsewhere) would write sr_demo_test_720.mp4 correctly
# and still silently overwrite the legacy sr_test_720.json. Only the video was checked
# above; the manifest is the record that makes a namespaced master reproducible.
if [ -f "$CLOUD/sr_demo_test_720.json" ]; then ok "clip: writes the namespaced manifest"
else bad "clip: writes the namespaced manifest" "no sr_demo_test_720.json"; fi
if [ -f "$CLOUD/sr_test_720.json" ]; then
  bad "clip: does not write the legacy manifest name" "sr_test_720.json was created too"
else ok "clip: does not write the legacy manifest name"; fi

# Omitting the argument must still reproduce the original invocation, or the recorded
# 720p master stops being replayable.
out="$(run_pod bash "$CLOUD/run_on_pod.sh" 720 test)"
case "$out" in
  *"[stub] would upscale"*"test_15s.mp4"*) ok "clip: no clip argument keeps the legacy input" ;;
  *) bad "clip: no clip argument keeps the legacy input" "$(printf '%s' "$out" | grep 'would upscale')" ;;
esac

clean; assert_stderr_matches "clip: a path separator in the clip name is refused" "invalid clip" \
  env PATH="$STUB:$PATH" WORKSPACE="$WS" bash "$CLOUD/run_on_pod.sh" 720 test ../etc

clean; assert_stderr_matches "clip: an unknown clip's missing input is refused" "not found" \
  env PATH="$STUB:$PATH" WORKSPACE="$WS" bash "$CLOUD/run_on_pod.sh" 720 test nosuchclip

# --- the happy path ---------------------------------------------------------
out="$(run_pod bash "$CLOUD/run_on_pod.sh" 720 test)"; status=$?
if [ "$status" -eq 0 ]; then ok "happy path: exits 0"
else bad "happy path: exits 0" "exit $status: $(printf '%s' "$out" | tail -1)"; fi
case "$out" in
  *"frame check OK: 214 frames"*) ok "happy path: frame check passes on a matching render" ;;
  *) bad "happy path: frame check passes" "$(printf '%s' "$out" | tail -2 | head -1)" ;;
esac

# A master without its parameters cannot be compared against anything later.
MAN="$CLOUD/sr_test_720.json"
if [ ! -f "$MAN" ]; then
  bad "manifest: written beside the render" "no $MAN"
else
  ok "manifest: written beside the render"
  # Assert, do not merely print. An empty object used to pass this.
  # Expected values come from the invocation itself (720, test, VRAM 49140 -> batch 33),
  # not from the manifest. Reading the manifest to decide what the manifest should say
  # is the mismatched-baseline trap in miniature.
  VERDICT="$(python - "$MAN" 720 test 33 5 seedvr2_ema_3b_fp16.safetensors \
    "NVIDIA A40" 2.4.0 4490bd1f482e026674543386bb2a4d176da245b9 \
    "$CLOUD/test_15s.mp4" "$CLOUD/sr_test_720.mp4" <<'PY'
import hashlib, json, sys
try:
    m = json.load(open(sys.argv[1]))
except Exception as e:
    print(f"unreadable: {e}"); raise SystemExit
need = ["resolution", "model", "extra_args", "fixed_args", "gpu", "torch",
        "seedvr2_commit", "input", "output"]
bad = [k for k in need if k not in m]
for side in ("input", "output"):
    for f in ("sha256", "frames"):
        if not m.get(side, {}).get(f):
            bad.append(f"{side}.{f}")
# Key presence is not enough: an empty or polluted value passed this before. These are
# the fields that make a render reproducible, so check they look like themselves.
import re
if not re.fullmatch(r"[0-9a-f]{40}", str(m.get("seedvr2_commit", ""))):
    bad.append(f"seedvr2_commit not a sha ({m.get('seedvr2_commit')!r})")
if not re.fullmatch(r"[0-9][\w.+]*", str(m.get("torch", ""))):
    bad.append(f"torch not a version ({m.get('torch')!r})")
if "," in str(m.get("gpu", {}).get("name", "")):
    bad.append(f"gpu.name polluted ({m['gpu']['name']!r})")
if not isinstance(m.get("resolution"), int):
    bad.append("resolution not an int")

# Shape checks are not content checks. A manifest hardcoded to "resolution": 999 with the
# wrong model passed everything above: every field was present, an int, and well-formed.
# The manifest exists so two renders can be told apart, so it has to be checked against
# what was actually run.
want_res, want_mode, want_b, want_t, want_model = sys.argv[2:7]
if m.get("resolution") != int(want_res):
    bad.append(f"resolution {m.get('resolution')!r}, invoked with {want_res}")
if m.get("mode") != want_mode:
    bad.append(f"mode {m.get('mode')!r}, invoked with {want_mode!r}")
if m.get("model") != want_model:
    bad.append(f"model {m.get('model')!r}, expected {want_model!r}")
ex = m.get("extra_args", [])
for flag, want in (("--batch_size", want_b), ("--temporal_overlap", want_t)):
    if flag not in ex or ex[ex.index(flag) + 1] != want:
        bad.append(f"{flag} not {want} in extra_args {ex!r}")

# A format check is not a content check either. Tightening these to a 64-hex regex still
# accepted a sha256() replaced by one returning "ab"*32 — the same fixed, content-blind
# value for two different files. Recompute both from the files on disk instead.
want_gpu, want_torch, want_commit, in_path, out_path = sys.argv[7:12]

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

for side, path in (("input", in_path), ("output", out_path)):
    got = str(m.get(side, {}).get("sha256", ""))
    real = sha256(path)
    if got != real:
        bad.append(f"{side}.sha256 {got[:16]}... but the file hashes {real[:16]}...")
if m.get("input", {}).get("sha256") == m.get("output", {}).get("sha256"):
    bad.append("input and output sha256 are identical - a content-blind hash")

# These three were regex-checked only, so a well-formed fabrication passed: a GPU named
# "Definitely Not A40", torch 9.9.9 against a stub reporting 2.4.0, a fake-but-valid sha.
if m.get("gpu", {}).get("name") != want_gpu:
    bad.append(f"gpu.name {m.get('gpu', {}).get('name')!r}, stub reports {want_gpu!r}")
if m.get("torch") != want_torch:
    bad.append(f"torch {m.get('torch')!r}, stub reports {want_torch!r}")
if m.get("seedvr2_commit") != want_commit:
    bad.append(f"seedvr2_commit {m.get('seedvr2_commit')!r}, stub reports {want_commit!r}")

print("ok" if not bad else "bad: " + "; ".join(bad))
PY
)"
  if [ "$VERDICT" = "ok" ]; then
    ok "manifest: carries the full invocation and both checksums"
  else
    bad "manifest: carries the full invocation and both checksums" "$VERDICT"
  fi
fi

echo
if [ "$FAIL" -eq 0 ]; then printf '\033[32m%d passed\033[0m\n' "$PASS"
else printf '\033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n' "$PASS" "$FAIL"
     for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done; fi
[ "$FAIL" -eq 0 ]
