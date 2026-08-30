# hoon-upscaler

AI restoration pipeline for degraded handheld video — stabilisation, SeedVR2 upscaling,
frame-timing repair and selective interpolation.

Built for a 2007 Nokia N90 clip (352×288, 15fps VFR, mpeg4 @ 509kbps) of a burnout at a
Perth speedway. Output is 1080p60. The recipe generalises to other low-resolution phone
and camcorder footage.

## Before / after

https://github.com/user-attachments/assets/96040f7b-cb6d-46a3-b7f1-a49a5599fa9e

Top: the 312×176 source, nearest-neighbour scaled — no smoothing, so nothing is
flattered. Bottom: the restored 1080p60 output. Thirty seconds from 0:24.

The lower panel is **reconstructed, not recovered**. See
[A note on what this produces](#a-note-on-what-this-produces).

## The pipeline

```
source (352×288, VFR, heavily compressed)
  │
  ├─ 1. stabilise          vidstab, translation only (maxangle=0), no crop
  ├─ 2. crop               remove fine mesh / clutter; fixes framing to 16:9
  ├─ 3. (no pre-filter)    deliberately — see CLAUDE.md
  ├─ 4. SeedVR2 upscale    3B fp16, resolution 1080, batch 33, overlap 5
  ├─ 5. luma stabilise     removes the camera's auto-exposure hunting
  ├─ 6. restore VFR timing rebuild with each frame's true duration
  ├─ 7. grade              contrast 1.20 / saturation 1.28 / gamma 0.96, no unsharp
  └─ 8. selective 60fps    interpolate normal gaps, hold through camera stalls
```

Steps 5-8 are automated by `pipeline/finish.sh`.

## Setup

```bash
git clone https://github.com/ScottMcCormack/hoon-upscaler.git
cd hoon-upscaler
python3 -m venv .venv && source .venv/bin/activate
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu130
pip install opencv-contrib-python-headless numpy ultralytics
```

The cu130 index matters on Blackwell cards (RTX 50-series) — stock builds have no
`sm_120` kernels. On Ampere/Ada, any recent build works.

`ffmpeg` and `ffprobe` must also be on PATH, and **the ffmpeg build must include the
vidstab filters** — the stabilise step uses `vidstabdetect` and `vidstabtransform`, which
require `--enable-libvidstab`. Not every distribution build has them. Check with:

```bash
ffmpeg -filters | grep vidstab      # expect vidstabdetect and vidstabtransform
```

SeedVR2 is a separate project and is not installed by the above. Clone it beside this
repository:

```bash
cd ..
git clone https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler.git SeedVR2
cd SeedVR2

# Its requirements.txt lists bare "torch" and "torchvision", which would replace the
# CUDA-matched build installed above with a generic one. Strip them out.
grep -vE '^(torch|torchvision)([=<>].*)?$' requirements.txt > /tmp/req_noTorch.txt
pip install -r /tmp/req_noTorch.txt
```

Model weights download automatically from HuggingFace on first run — nothing to fetch by
hand. They come from [numz/SeedVR2_comfyUI](https://huggingface.co/numz/SeedVR2_comfyUI).

## Usage

**Prepare the source** — stabilise, then crop out whatever clutters the frame:

```bash
ffmpeg -i in.mp4 -vf vidstabdetect=shakiness=8:accuracy=15:result=t.trf -f null -
ffmpeg -i in.mp4 \
  -vf "vidstabtransform=input=t.trf:smoothing=20:maxangle=0:optzoom=0:zoom=0:crop=black" \
  -c:v libx264 -preset slow -crf 10 -an stabilised.mp4
ffmpeg -i stabilised.mp4 -vf "crop=312:176:0:0" -crf 0 cropped.mp4
```

**Upscale** with SeedVR2 (locally, or on a rented GPU — see `cloud/`). `inference_cli.py`
lives in the SeedVR2 checkout, so run it from there:

```bash
cd ../SeedVR2
python inference_cli.py ../hoon-upscaler/cropped.mp4 \
  --output ../hoon-upscaler/raw_upscaled.mp4 \
  --dit_model seedvr2_ema_3b_fp16.safetensors \
  --resolution 1080 --batch_size 33 --temporal_overlap 5 \
  --chunk_size 370 --color_correction wavelet --video_backend ffmpeg
```

**Finish** — timing, grade and interpolation in one step:

```bash
bash pipeline/finish.sh raw_upscaled.mp4 MyClip in.mp4
```

Produces `MyClip_lumafix_14fps.mp4`, `_14fps_ungraded.mp4` and `_lumafix_K5.mp4` (60fps).

## Scripts

| File | Purpose |
|---|---|
| `pipeline/finish.sh` | Luma fix → true timing → grade → selective 60fps |
| `pipeline/luma_stabilise.py` | Removes auto-exposure hunting (global level correction) |
| `pipeline/selective_interp.py` | Interpolates normal gaps, holds through camera stalls |
| `pipeline/reframe_src.py` | Solves a deadzone virtual camera from YOLO detections |
| `pipeline/detect_car.py` | Per-frame subject detection (for tracked reframing) |
| `cloud/run_on_pod.sh` | Provision-and-run on a rented GPU |

## Renting a GPU

A 16GB card hits a hard wall above ~1021×576 output — throughput drops roughly 19× as
model blocks swap to system RAM. An **A40 48GB** on RunPod at $0.44/hr removes it: a
720p render went from an impractical 10 hours to 22 minutes, and 1080p became possible
at all. Three full renders plus two model comparisons cost about $1.

Pick **Ampere or Ada** (A40, A100, L40S), not Blackwell — see `CLAUDE.md`.

See `cloud/run_on_pod.sh` and `docs/findings.md`.

## A note on what this produces

The source captured 352×288. Everything above that is **reconstructed, not recovered** —
the model infers plausible detail rather than revealing hidden detail. It is consistent
and convincing, but it is not evidence. During development the model rendered a phone
number on a sign cleanly and incorrectly. Good for watching; not for reading.

## Licence

Apache-2.0 — see [LICENSE](LICENSE).

One caveat worth reading before reuse: `pipeline/detect_car.py` imports `ultralytics`,
which is AGPL-3.0, so the permissive licence here does not extend to that file's
dependency chain. [NOTICE](NOTICE) has the detail. No code licence covers the footage.

Contribution terms and the standard for adding to `docs/findings.md` are in
[CONTRIBUTING.md](CONTRIBUTING.md).
