#!/bin/bash
# ============================================================================
# SeedVR2 upscale - RunPod / cloud GPU
#
# Input : full_169.mp4  312x176, 1480 frames  (~104s, the whole clip)
#         test_15s.mp4  312x176, 214 frames   (~15s, for a cheap first run)
#         Both are already stabilised and cropped to 16:9, with no pre-filter.
#
# Output: sr_out_<res>.mp4 - upscaled only. Timing restore, grade and the
#         selective 60fps pass are done locally afterwards.
#
# Usage:  bash run_on_pod.sh 720            # full clip at 720
#         bash run_on_pod.sh 720 test       # 15s test first - DO THIS ONE FIRST
#         bash run_on_pod.sh 1080           # if 720 looks good and you're curious
# ============================================================================
set -uo pipefail
RES="${1:-720}"
MODE="${2:-full}"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [ "$MODE" = "test" ]; then
  IN="$HERE/test_15s.mp4";  OUT="$HERE/sr_test_${RES}.mp4";  EXPECT=200
else
  IN="$HERE/full_169.mp4";  OUT="$HERE/sr_out_${RES}.mp4";   EXPECT=1400
fi
[ -f "$IN" ] || { echo "ERROR: $IN not found - upload it to this directory first"; exit 1; }

echo "### GPU ###"
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader
VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)

echo "### system deps ###"
apt-get update -qq >/dev/null 2>&1 || true
apt-get install -y -qq ffmpeg git >/dev/null 2>&1 || true

echo "### SeedVR2 ###"
cd /workspace
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
grep -vE '^(torch|torchvision)([=<>].*)?$' requirements.txt > /tmp/req_noTorch.txt
pip install -q -r /tmp/req_noTorch.txt
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
  echo "### ${VRAM}MB VRAM -> fp8 with offloading (same as the local run) ###"
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
N=$(ffprobe -v error -select_streams v:0 -show_entries stream=nb_frames -of csv=p=0 "$OUT")
if [ "${N:-0}" -lt "$EXPECT" ]; then
  echo "!! WARNING: only $N frames (expected >=$EXPECT). Inference did not complete."
  exit 1
fi
echo "frame check OK: $N frames"
ls -lh "$OUT"
echo
echo "Download $(basename "$OUT") — then TERMINATE the pod (not just stop it)."
