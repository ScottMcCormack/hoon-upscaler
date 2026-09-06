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
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=s=64x36:r=15:d=30" \
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
for case in "49140:batch 33:A40 48GB" "24564:batch 17:RTX 3090 24GB" "16376:fp8 with offloading:RTX 4080 16GB"; do
  vram="${case%%:*}"; rest="${case#*:}"; want="${rest%%:*}"; label="${rest#*:}"
  out="$(STUB_VRAM="$vram" run_pod bash "$CLOUD/run_on_pod.sh" 720 test)"
  case "$out" in
    *"$want"*) ok "vram: $label selects '$want'" ;;
    *) bad "vram: $label selects '$want'" "got: $(printf '%s' "$out" | grep '###' | tail -1)" ;;
  esac
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

# A third argument used to be ignored, so a typo'd flag ran the default render instead.
clean; assert_stderr_matches "guard: extra arguments are refused" "unexpected extra argument" \
  env PATH="$STUB:$PATH" WORKSPACE="$WS" bash "$CLOUD/run_on_pod.sh" 720 test --dry-run

# --help hit the resolution guard and answered "must be a positive integer", which reads
# as though the script were broken rather than as usage.
clean
HELP="$(env PATH="$STUB:$PATH" WORKSPACE="$WS" bash "$CLOUD/run_on_pod.sh" --help 2>&1)"; HST=$?
if [ "$HST" -eq 0 ] && [[ "$HELP" == *"test_15s.mp4"* ]] && [[ "$HELP" != *"positive integer"* ]]; then
  ok "--help prints usage and exits 0"
else
  bad "--help prints usage and exits 0" "exit $HST: $(printf '%s' "$HELP" | tail -1)"
fi

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
  VERDICT="$(python - "$MAN" <<'PY'
import json, sys
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
