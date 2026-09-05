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
  *nounits*) echo "${STUB_VRAM:-49140}" ;;
  *)         echo "${STUB_GPU:-NVIDIA A40}, ${STUB_VRAM:-49140} MiB" ;;
esac
EOF

cat > "$STUB/python" <<'EOF'
#!/bin/bash
# Three call shapes matter: the CUDA probe, the version banner, and inference.
if [ "${1:-}" = "-c" ]; then
  case "$2" in
    *sys.exit*cuda.is_available*) exit "${STUB_NO_CUDA:-0}" ;;
    *)                            echo "  torch 2.4.0  cuda=True  ${STUB_GPU:-NVIDIA A40}"; exit 0 ;;
  esac
fi
if [ "${1:-}" = "inference_cli.py" ]; then
  # find --output
  out=""; prev=""
  for a in "$@"; do [ "$prev" = "--output" ] && out="$a"; prev="$a"; done
  echo "  [stub] would upscale $2 -> $out"
  [ "${STUB_NO_OUTPUT:-0}" = "1" ] && exit 0          # ran, produced nothing
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=s=64x36:r=15:d=30" \
    -frames:v "${STUB_OUT_FRAMES:-214}" -c:v libx264 -crf 30 -pix_fmt yuv420p "$out"
  exit 0
fi
exec /usr/bin/env python3 "$@"
EOF

for noop in pip apt-get git; do
  printf '#!/bin/bash\nexit 0\n' > "$STUB/$noop"
done
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
clean() { rm -f "$CLOUD"/sr_*.mp4; }

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

echo
if [ "$FAIL" -eq 0 ]; then printf '\033[32m%d passed\033[0m\n' "$PASS"
else printf '\033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n' "$PASS" "$FAIL"
     for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done; fi
[ "$FAIL" -eq 0 ]
