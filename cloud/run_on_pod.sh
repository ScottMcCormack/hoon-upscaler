#!/bin/bash
# ============================================================================
# SeedVR2 upscale - RunPod / cloud GPU
#
# Input : with no CLIP argument, the original N90 clip -
#           full_169.mp4  312x176, 1480 frames  (~104s, the whole clip)
#           test_15s.mp4  312x176, 214 frames   (~15s, for a cheap first run)
#         with a CLIP argument, <CLIP>_full.mp4 and <CLIP>_test.mp4.
#         All are already stabilised and cropped to 16:9, with no pre-filter.
#         None are in the repo - they are media. Make them from the stabilised
#         source (see README "Prepare the source"), then upload to this
#         directory on the pod:
#           ffmpeg -i stabilised.mp4 -vf "crop=312:176:0:0" -crf 0 full_169.mp4
#           ffmpeg -i full_169.mp4 -frames:v 214 -c copy   test_15s.mp4
#
# Output: with no CLIP, sr_test_<res>.mp4 (test mode) or sr_out_<res>.mp4 (full mode) -
#         the two differ, so the test-first invocation below writes sr_test_<res>.mp4,
#         not sr_out_<res>.mp4. With a CLIP argument, sr_<CLIP>_<mode>_<res>.mp4 either
#         way. All of these are upscaled only - timing restore, grade and the selective
#         60fps pass are done locally afterwards.
#
# Usage:  bash run_on_pod.sh 720                    # full clip at 720
#         bash run_on_pod.sh 720 test               # 15s test first - DO THIS ONE FIRST
#         bash run_on_pod.sh 1080                   # if 720 looks good and you're curious
#         bash run_on_pod.sh 720 test mvi0081       # a second source, namespaced
# ============================================================================
set -euo pipefail
case "${1:-}" in
  -h|--help)
    # Selected through the closing "# ====" separator rather than a hardcoded line
    # number, so the range moves on its own when the docstring above it grows or shrinks.
    # A fixed endpoint has already cut usage lines off twice before (it stopped at 20,
    # then at 23, each time one edit behind the docstring above it) - review caught both,
    # but a range that cannot go stale is better than one re-verified by hand each time.
    sed -n '2,/^# ====/{/^# ====/!p}' "$0" | sed 's/^# \{0,1\}//'
    exit 0 ;;
esac
# Reject extra arguments rather than ignoring them: a mistyped invocation should say so,
# not quietly run something adjacent to what was meant. The ceiling is 3 because CLIP is
# a real third argument; it was 2 before CLIP existed, and git merged the two changes
# without noticing they contradict - the guard would have refused every clip invocation.
[ "$#" -le 3 ] || { echo "!! unexpected extra argument(s): ${*:4}"; exit 1; }
# Omitting the resolution means 720. An explicitly EMPTY one is a wrapper passing through
# a variable it never set, and ${1:-720} cannot tell the two apart — the same hole the
# mode guard below closes. Left open it is worse than the mode case, because a lone empty
# argument also leaves $2 unset, so the run silently becomes the chargeable full render at
# a resolution nobody chose, and the manifest records it as though it were deliberate.
if [ "$#" -ge 1 ] && [ -z "${1:-}" ]; then
  echo "!! resolution was given but empty. Pass a resolution explicitly, e.g. 720."; exit 1
fi
RES="${1:-720}"
# Same reasoning as the VRAM guard below: a non-integer here makes `[ "$RES" -ge 720 ]`
# error inside an `if`, which set -e does not catch, so the low-VRAM OOM warning would
# silently never fire. It would then die much later in the manifest, after inference.
[[ "$RES" =~ ^[0-9]+$ ]] && [ "$RES" -gt 0 ] || {
  echo "!! resolution must be a positive integer, got: '$RES'"; exit 1; }
# Omitting the mode means "full", as the header documents. An explicitly EMPTY mode is
# different: that is a wrapper passing through an unset variable, and ${2:-full} would
# silently hand it the chargeable full render. Refuse rather than guess, same as an
# unknown mode below.
if [ "$#" -ge 2 ] && [ -z "$2" ]; then
  echo "!! mode was given but empty. Pass 'test' or 'full' explicitly."; exit 1
fi
MODE="${2:-full}"
# Same hole as RES and MODE above, on the third positional: omitting CLIP means the
# legacy, unnamespaced clip (documented below), but an explicitly EMPTY one is a wrapper
# passing through a variable it never set - and the unguarded `${3:-}` could not tell the
# two apart. Left open, that silently takes the legacy branch: a second source's render
# and manifest overwrite the first's, which is exactly what naming a clip exists to
# prevent - the "standard applied once is not applied" case CLAUDE.md warns about,
# happening here because CLIP was added as a third positional after this guard shape was
# already established for the other two and never carried over to it.
if [ "$#" -ge 3 ] && [ -z "$3" ]; then
  echo "!! clip was given but empty. Pass a clip name explicitly, or omit the argument entirely."; exit 1
fi
CLIP="${3:-}"
case "$MODE" in
  test|full) ;;
  *) echo "!! unknown mode '$MODE' - expected 'test' or 'full'. Refusing to guess, since"
     echo "   the wrong guess is the chargeable full render."; exit 1 ;;
esac
# CLIP is interpolated into the filenames below. Empty is the legacy default and fine;
# anything that could escape this directory is not.
case "$CLIP" in
  */*|*\\*|.|..|*..*) echo "!! invalid clip '$CLIP': no path separators or .. allowed"; exit 1 ;;
esac
HERE="$(cd "$(dirname "$0")" && pwd)"

# Omitting CLIP reproduces the original invocation byte-for-byte, so the recorded 720p
# master still replays. Naming a clip namespaces input AND output: without that, a second
# source silently overwrites the first's master and its manifest, and the manifest is the
# only record of how that master was made.
if [ -z "$CLIP" ]; then
  if [ "$MODE" = "test" ]; then
    IN="$HERE/test_15s.mp4";  OUT="$HERE/sr_test_${RES}.mp4"
  else
    IN="$HERE/full_169.mp4";  OUT="$HERE/sr_out_${RES}.mp4"
  fi
else
  IN="$HERE/${CLIP}_${MODE}.mp4";  OUT="$HERE/sr_${CLIP}_${MODE}_${RES}.mp4"
fi
[ -f "$IN" ] || { echo "ERROR: $IN not found - upload it to this directory first"; exit 1; }

echo "### GPU ###"
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)
# A non-integer here (nvidia-smi emits [N/A] on some virtualised GPUs) would make the
# comparisons below error inside an `if`, which set -e does not catch, silently
# selecting the fp8 CPU-offload path on a card that does not need it.
[[ "$VRAM" =~ ^[0-9]+$ ]] || { echo "!! could not read VRAM, got: '$VRAM'"; exit 1; }

echo "### system deps ###"
apt-get update -qq >/dev/null 2>&1 || true
apt-get install -y -qq ffmpeg git >/dev/null 2>&1 || true

echo "### SeedVR2 ###"
# /workspace is the RunPod pod convention; overridable so the script can be exercised
# off-pod against stubs, which is where its guards get tested without paying for a GPU.
WORKSPACE="${WORKSPACE:-/workspace}"
[ -d "$WORKSPACE" ] || { echo "!! workspace '$WORKSPACE' does not exist"; exit 1; }
cd "$WORKSPACE"
[ -d SeedVR2 ] || git clone --depth 1 https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler.git SeedVR2
cd SeedVR2

# IMPORTANT: SeedVR2's requirements.txt lists bare "torch" and "torchvision".
# Installing those on a RunPod PyTorch image can replace the pod's CUDA-matched
# build with a generic one and silently break GPU support. Strip them out and
# keep whatever torch the image already ships.
python -c "import torch, sys; sys.exit(0 if torch.cuda.is_available() else 1)" 2>/dev/null || {
  echo "!! no working CUDA torch found - install one matching this pod's CUDA before continuing"
  echo "   e.g. pip install torch torchvision --index-url https://download.pytorch.org/whl/cu124"
  exit 1
}
[ -f requirements.txt ] || { echo "!! requirements.txt missing in $(pwd)"; exit 1; }
# grep -v exits 1 when it selects nothing, which set -e would treat as fatal
grep -vE '^(torch|torchvision)([=<>].*)?$' requirements.txt > /tmp/req_noTorch.txt || true

# Ubuntu 24.04 images (runpod-torch-v280 is one) mark the system Python as externally
# managed, and PEP 668 makes pip refuse to install into it. A venv is the usual answer
# and the wrong one here: the whole point is to install ALONGSIDE the CUDA-matched torch
# the image already ships, and the pod is disposable anyway. Detect the marker rather
# than passing the flag unconditionally, since older pips reject it.
PIP_FLAGS=""
if python -c "import os, sysconfig, sys; sys.exit(0 if os.path.exists(os.path.join(sysconfig.get_paths()['stdlib'], 'EXTERNALLY-MANAGED')) else 1)"; then
  PIP_FLAGS="--break-system-packages"
  echo "  (PEP 668 environment - installing with --break-system-packages)"
fi
pip install -q $PIP_FLAGS -r /tmp/req_noTorch.txt
python -c "import torch; print(f'  torch {torch.__version__}  cuda={torch.cuda.is_available()}  {torch.cuda.get_device_name(0)}')"

# With plenty of VRAM there is no need to offload to CPU, which is exactly what
# made this slow on a 16GB card. Use fp16 weights and a wider temporal window.
if [ "$VRAM" -ge 40000 ]; then
  MODEL="seedvr2_ema_3b_fp16.safetensors"
  EXTRA="--batch_size 33 --temporal_overlap 5"
  echo "### ${VRAM}MB VRAM -> fp16, batch 33, no offloading ###"
elif [ "$VRAM" -ge 22000 ]; then
  MODEL="seedvr2_ema_3b_fp16.safetensors"
  EXTRA="--batch_size 17 --temporal_overlap 3"
  echo "### ${VRAM}MB VRAM -> fp16, batch 17, no offloading ###"
else
  MODEL="seedvr2_ema_3b_fp8_e4m3fn.safetensors"
  EXTRA="--batch_size 17 --temporal_overlap 3 --blocks_to_swap 16 --dit_offload_device cpu --vae_offload_device cpu"
  echo "### ${VRAM}MB VRAM -> fp8 with offloading ###"
  # Measured 2026-09-04 on an RTX A4000 (16376MB): resolution 720 dies with
  # torch.OutOfMemoryError inside the VAE, not the DiT, so blocks_to_swap and the CPU
  # offload flags above do not save it. 540 completed at 1.01 fps on the same card.
  # This is the cliff CLAUDE.md describes, and it is a warning rather than a refusal
  # because the exact limit depends on the card and this branch covers 16-22GB.
  if [ "$RES" -ge 720 ]; then
    echo "!! WARNING: ${VRAM}MB at resolution $RES is likely to run out of memory."
    echo "   A 16GB card OOMs in the VAE at 720. 540 works. Continuing anyway - if it"
    echo "   dies with OutOfMemoryError, lower the resolution rather than the batch size."
  fi
fi

# Replaying a recorded master. The branch above picks settings from VRAM, which is right
# for a fresh render and wrong for reproducing one: the 720p master was made at batch 65
# and no card selects that today. SeedVR2 is deterministic given identical parameters -
# verified twice, including a byte-for-byte recreation of the 1080p master seven days after
# it was made - so a manifest plus these overrides recreates a master exactly.
if [ -n "${BATCH_SIZE:-}" ] || [ -n "${TEMPORAL_OVERLAP:-}" ]; then
  # Fall back to what the VRAM branch just chose, NOT to the 48GB defaults. Otherwise
  # setting one override silently rewrites the other: TEMPORAL_OVERLAP=5 on a 24GB card
  # would move batch 17 to 33, quietly changing the render the caller did not ask about.
  # Refuse anything that is not a plain positive integer. These values are spliced into
  # the inference command line, so "17 --debug_leak" would smuggle in an extra flag and
  # the manifest would record it as though it were legitimate. The same standard MODE is
  # held to a few lines up, and for the same reason: this override exists to reproduce a
  # paid render, so a wrong value costs a pod.
  for v in BATCH_SIZE TEMPORAL_OVERLAP; do
    val="${!v:-}"
    [ -z "$val" ] && continue
    [[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -gt 0 ] || {
      echo "!! $v must be a positive integer, got: '$val'"; exit 1; }
  done
  # grep exits 1 when it matches nothing, and under pipefail+set -e that kills the script
  # with no output at all. No current branch omits either flag, but a future one might.
  CUR_B="$(printf '%s' "$EXTRA" | grep -oE -- '--batch_size [0-9]+' | grep -oE '[0-9]+' || true)"
  CUR_T="$(printf '%s' "$EXTRA" | grep -oE -- '--temporal_overlap [0-9]+' | grep -oE '[0-9]+' || true)"
  [ -n "${BATCH_SIZE:-}" ] || [ -n "$CUR_B" ] || { echo "!! no --batch_size in EXTRA to override"; exit 1; }
  [ -n "${TEMPORAL_OVERLAP:-}" ] || [ -n "$CUR_T" ] || { echo "!! no --temporal_overlap in EXTRA to override"; exit 1; }
  B="${BATCH_SIZE:-$CUR_B}"; T="${TEMPORAL_OVERLAP:-$CUR_T}"
  # The OOM warning above keys on resolution, but batch width drives VRAM too. Overriding
  # upward past what this card's branch chose walks toward the same cliff from the other
  # side — e.g. the 720p master's batch 65 on a 24GB card, which derived 17.
  if [ -n "$CUR_B" ] && [ "$B" -gt "$CUR_B" ]; then
    echo "!! WARNING: batch $B is above the $CUR_B this card's VRAM selected."
    echo "   Overriding upward is how you reproduce a master made on a bigger card; it is"
    echo "   also how you run out of memory. If it dies with OutOfMemoryError, that is why."
  fi
  EXTRA="$(echo "$EXTRA" | sed -E "s/--batch_size [0-9]+/--batch_size $B/; s/--temporal_overlap [0-9]+/--temporal_overlap $T/")"
  echo "### OVERRIDE: batch $B, overlap $T (reproducing a recorded render) ###"
fi

echo "### running: $MODE at resolution $RES ###"
time python inference_cli.py "$IN" \
  --output "$OUT" \
  --dit_model "$MODEL" \
  --resolution "$RES" \
  --chunk_size 370 \
  --cache_dit --cache_vae \
  --color_correction wavelet \
  --video_backend ffmpeg \
  $EXTRA

echo "### result ###"
if [ ! -f "$OUT" ]; then echo "!! no output produced - inference failed"; exit 1; fi
ffprobe -v error -select_streams v:0 -show_entries stream=width,height,nb_frames -of csv=p=0 "$OUT"
# Compare against the input exactly. A slack threshold hid the very failure this
# check exists for: a run short by 80 frames (>5s) still passed.
count_frames() {
  local n
  n=$(ffprobe -v error -select_streams v:0 -show_entries stream=nb_frames -of csv=p=0 "$1")
  if ! [ "$n" -eq "$n" ] 2>/dev/null; then
    n=$(ffprobe -v error -select_streams v:0 -count_packets \
        -show_entries stream=nb_read_packets -of csv=p=0 "$1")
  fi
  if ! [ "${n:-0}" -gt 0 ] 2>/dev/null; then
    echo "!! could not determine frame count for $1" >&2
    return 1
  fi
  echo "$n"
}
IN_N=$(count_frames "$IN")
OUT_N=$(count_frames "$OUT")
if [ "$OUT_N" -ne "$IN_N" ]; then
  echo "!! frame count mismatch: input $IN_N, output $OUT_N. Inference did not complete."
  exit 1
fi
echo "frame check OK: $OUT_N frames, matching input"

# A manifest beside every master. SeedVR2 IS reproducible given identical parameters -
# the 1080p master was recreated byte-for-byte seven days later - which is exactly why the
# parameters must be recorded: they are the whole of what makes a render repeatable.
# Without them you cannot even tell whether two renders differ because of the model or
# because they were asked for different things. That question cost a wasted comparison
# once already.
MANIFEST="${OUT%.mp4}.json"
SEEDVR2_COMMIT="$(git -C "$WORKSPACE/SeedVR2" rev-parse HEAD 2>/dev/null || echo unknown)"
TORCH_VER="$(python -c 'import torch; print(torch.__version__)' 2>/dev/null || echo unknown)"
GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
MANIFEST="$MANIFEST" IN="$IN" OUT="$OUT" IN_N="$IN_N" OUT_N="$OUT_N" RES="$RES" \
MODEL="$MODEL" EXTRA="$EXTRA" VRAM="$VRAM" GPU_NAME="$GPU_NAME" \
SEEDVR2_COMMIT="$SEEDVR2_COMMIT" TORCH_VER="$TORCH_VER" MODE="$MODE" python - <<'PY'
import hashlib, json, os, subprocess, datetime

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def dims(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0",
                          "-show_entries", "stream=width,height", "-of", "csv=p=0", path],
                         capture_output=True, text=True).stdout.strip()
    w, _, h = out.partition(",")
    return {"width": int(w), "height": int(h)}

e = os.environ
m = {
    "created_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    "mode": e["MODE"],
    "resolution": int(e["RES"]),
    "model": e["MODEL"],
    "extra_args": e["EXTRA"].split(),
    "fixed_args": ["--chunk_size", "370", "--cache_dit", "--cache_vae",
                   "--color_correction", "wavelet", "--video_backend", "ffmpeg"],
    "gpu": {"name": e["GPU_NAME"], "vram_mb": int(e["VRAM"])},
    "torch": e["TORCH_VER"],
    "seedvr2_commit": e["SEEDVR2_COMMIT"],
    "input": {"file": os.path.basename(e["IN"]), "frames": int(e["IN_N"]),
              **dims(e["IN"]), "sha256": sha256(e["IN"])},
    "output": {"file": os.path.basename(e["OUT"]), "frames": int(e["OUT_N"]),
               **dims(e["OUT"]), "sha256": sha256(e["OUT"])},
}
with open(e["MANIFEST"], "w") as f:
    json.dump(m, f, indent=2)
    f.write("\n")
print(f"    manifest: {os.path.basename(e['MANIFEST'])}"
      f"  (seedvr2 {m['seedvr2_commit'][:8]}, torch {m['torch']})")
PY

ls -lh "$OUT"
echo
echo "Download $(basename "$OUT") — then TERMINATE the pod (not just stop it)."
echo
echo "Before terminating, check nobody else is using it — a pod is not necessarily yours"
echo "alone, and teardown destroys the local disk:"
echo "  nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv"
echo "  ls -lh $(dirname "$OUT")/*.mp4    # is every output actually downloaded?"
