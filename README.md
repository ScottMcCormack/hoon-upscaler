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
  ├─ 6. restore cadence    rebuild per-frame durations (±13ms, see #2)
  ├─ 7. grade              contrast 1.20 / saturation 1.28 / gamma 0.96, no unsharp
  └─ 8. selective 60fps    interpolate normal gaps, hold through camera stalls
```

Steps 5-8 are automated by `pipeline/finish.sh`.

## Setup

```bash
git clone https://github.com/ScottMcCormack/hoon-upscaler.git
cd hoon-upscaler
python3.12 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

Python 3.12, not 3.14 — neither numpy nor opencv ships a cp314 wheel yet.

`requirements.txt` is the core pipeline only. The experimental reframing path needs
`requirements-reframe.txt`, which pulls in `ultralytics` (**AGPL-3.0** — see
[NOTICE](NOTICE)) and torch. On Blackwell cards install torch from the cu130 index first,
since stock builds carry no `sm_120` kernels:

```bash
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu130
pip install -r requirements-reframe.txt
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
| `pipeline/finish.sh` | Luma fix → source cadence → grade → selective 60fps |
| `pipeline/luma_stabilise.py` | Removes auto-exposure hunting (global level correction) |
| `pipeline/selective_interp.py` | Interpolates normal gaps, holds through camera stalls |
| `pipeline/reframe_src.py` | Solves a deadzone virtual camera from YOLO detections |
| `pipeline/detect_car.py` | Per-frame subject detection (for tracked reframing) |
| `cloud/run_on_pod.sh` | Provision-and-run on a rented GPU |
| `tests/cloud_pod.sh` | Exercises the cloud runner against stubs, no GPU needed |
| `tools/stall_discontinuity.py` | Scores how abrupt each stall exit is, against the clip's own motion |

`reframe_src.py` and `detect_car.py` are an **experimental tracked-reframing path, not part
of the pipeline above**
and not runnable as shipped. Both operate in "STABFIRST" space — a 1408×1152 intermediate
(4× the source, then a centred 1.12× crop) that no step in this repository produces. The
constants in `reframe_src.py` are hardcoded to that geometry, and `detect_car.py` now
records the space it detected in so a mismatch fails loudly rather than silently solving
in the wrong coordinates. Producing the STABFIRST intermediate is left undocumented.

## Renting a GPU

A 16GB card hits a hard wall above ~1021×576 output — throughput drops roughly 19× as
model blocks swap to system RAM. An **A40 48GB** on RunPod removes it, and 1080p becomes
possible at all.

Measured on 2026-09-04, end to end via `cloud/run_on_pod.sh`:

| | frames | wall clock | throughput |
|---|---|---|---|
| 15s test at 720 | 214 | 5m24s | 0.68 fps |
| full clip at 720 | 1480 | 25m11s | 0.98 fps |

**$0.34 total** at $0.49/hr, including pod setup, the SeedVR2 checkout and the first-run
model download. The test render is worth doing first regardless — it costs about $0.15 and
catches a broken setup in five minutes rather than forty.

Pick **Ampere or Ada** (A40, A100, L40S), not Blackwell — see `CLAUDE.md`.

The runner needs two inputs beside it, neither of which is in the repo since both are
media. Build them from the stabilised source, then upload both to the pod:

```bash
ffmpeg -i stabilised.mp4 -vf "crop=312:176:0:0" -crf 0 cloud/full_169.mp4
ffmpeg -i cloud/full_169.mp4 -frames:v 214 -c copy    cloud/test_15s.mp4
```

Run the 15-second one first — `bash run_on_pod.sh 720 test`. It costs about $0.15 and
catches a broken setup in five minutes instead of forty.

`bash tests/cloud_pod.sh` exercises the runner against stubs before you rent anything.
It proves the script's own logic; it cannot tell you anything about the pod image.

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
