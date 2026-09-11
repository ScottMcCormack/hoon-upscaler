# The pipeline

Eight steps. The first four you run by hand — steps 1-2 depend on what is in your frame,
and step 4 (the upscale) needs a GPU that may not be the machine running the rest; the
last four are automated by `pipeline/finish.sh`.

```
source (352×288, VFR, heavily compressed)
  │
  ├─ 1. stabilise          vidstab, translation only (maxangle=0), no crop
  ├─ 2. crop               remove fine mesh / clutter; fixes framing to 16:9
  ├─ 3. (no pre-filter)    deliberately — see "Why there is no denoise step"
  ├─ 4. SeedVR2 upscale    3B fp16, resolution 1080, batch 33, overlap 5
  ├─ 5. luma stabilise     removes the camera's auto-exposure hunting
  ├─ 6. restore cadence    rebuild the source's real per-frame timing
  ├─ 7. grade              preset picked from the clip's own luma, then verified
  └─ 8. selective 60fps    interpolate normal gaps, hold through camera stalls
```

## Running it

### Prepare the source (steps 1-2)

Stabilise, then crop out whatever clutters the frame:

```bash
ffmpeg -i in.mp4 -vf vidstabdetect=shakiness=8:accuracy=15:result=t.trf -f null -
ffmpeg -i in.mp4 \
  -vf "vidstabtransform=input=t.trf:smoothing=20:maxangle=0:optzoom=0:zoom=0:crop=black" \
  -c:v libx264 -preset slow -crf 10 -an stabilised.mp4
ffmpeg -i stabilised.mp4 -vf "crop=312:176:0:0" -crf 0 cropped.mp4
```

The crop is specific to the reference clip. Pick your own — the point is what you remove,
not these numbers.

`smoothing=20` is tuned for the reference clip, which is near-static handheld footage —
**match it to the camera's actual motion before reusing it.** A second source that pans
1365px across a 320px frame needed `smoothing=10` instead: measured directly on a segment
first, `smoothing=20` already cost 24px of border intrusion for no shake reduction over 10,
and 30 pulled black borders 61px into the picture while removing no more shake either.
Both border intrusion and residual shake are measurable on a ten-second segment before you
commit to a value, or rent anything — see [findings.md](findings.md).

### Upscale (step 4)

Run SeedVR2 locally, or on a rented GPU (see [cloud-gpu.md](cloud-gpu.md)).
`inference_cli.py` lives in the SeedVR2 checkout, so run it from there:

```bash
cd ../SeedVR2
python inference_cli.py ../hoon-upscaler/cropped.mp4 \
  --output ../hoon-upscaler/raw_upscaled.mp4 \
  --dit_model seedvr2_ema_3b_fp16.safetensors \
  --resolution 1080 --batch_size 33 --temporal_overlap 5 \
  --chunk_size 370 --color_correction wavelet --video_backend ffmpeg
```

**Always check the frame count of what comes back.** A crashed run produces a plausible,
shorter file that nothing but its duration gives away. `finish.sh` refuses to continue on
a mismatch, which is the check that caught it.

### Finish (steps 5-8)

```bash
bash pipeline/finish.sh raw_upscaled.mp4 MyClip in.mp4
```

The original camera file is the third argument because two things are only available
there: the real per-frame timestamps, and the audio.

Three files land in `out/`:

| Output | What it is |
|---|---|
| `MyClip_lumafix_14fps.mp4` | Source cadence, graded — the faithful-timing version |
| `MyClip_lumafix_14fps_ungraded.mp4` | The same render without the grade, as a reference |
| `MyClip_lumafix_K5.mp4` | 60fps, selective interpolation — the watchable one |

The ungraded render is not a leftover. It is the baseline the grade is verified against,
and the thing to compare with when a grade looks wrong.

### Overriding the grade

The grade is chosen from the clip rather than fixed. Set `GRADE` to override it:

```bash
GRADE="curves=all='0/0 0.5/0.49 1/0.99'" bash pipeline/finish.sh raw.mp4 MyClip in.mp4
```

The clipping check still runs on your override. It is not a suggestion the pipeline makes
and then ignores.

### Overriding the interpolator

Step 8 picks its interpolator by measurement, not by clip length or a guess. On a fast
pan, newly revealed content has no correspondence in the previous frame, so
`minterpolate`'s block compensation stretches neighbours into it and the picture flows
rather than moves — fine on near-static footage (3.36% of frame width, windowed block
motion, measured on the actual render `finish.sh` thresholds), visibly wrong on a clip
that pans (9.95%). RIFE synthesises those regions instead of stretching into them.
`INTERP=minterpolate|rife|auto` overrides the automatic choice; RIFE needs a one-off setup
described in `pipeline/rife.py`.

## Why the steps are in this order

Most of the bugs in this project's history were a sensible step in the wrong place. These
are the orderings that cost something to learn.

**Stabilise before upscaling.** Shake moves content *inside* the model's temporal batch,
and the model reconciles that by inventing doubled detail — ghost text, most visibly.
Stabilising first gives it a coherent window to work with.

**Disable rotation while stabilising** (`maxangle=0`). Handheld shake is almost entirely
translation. Fitting rotation as well makes the solver chase noise, and the result swims.

**Crop the problem out rather than filtering around it.** Fine chain-link mesh sitting at
the source's resolution limit made the model speckle. Roughly twenty filters were tried
against it and none worked; cropping the fence out of frame solved it completely — and
removed the need for any pre-filter at all.

**Never denoise before the restoration model.** `hqdn3d` helped Real-ESRGAN and badly hurt
SeedVR2, which is trained on degraded input and wants the artifacts left in. This is why
step 3 is deliberately empty.

**Never flatten variable frame timing.** Extracting frames at a constant rate throws away
the camera's real per-frame durations, and a 267ms stall then plays in 70ms — the subject
appears to leap. Step 6 rebuilds the true cadence from the source's own timestamps, as a
constant rate with held frames repeated. That representation is exact for this camera,
which only ever stalls for whole multiples of a frame period; `finish.sh` refuses the clip
rather than approximating if that does not hold.

**Interpolate from the same grade the held frames come from.** The selective pass pulls
held frames from the graded render. Feeding it the ungraded one put a 10.5-mean,
16.9-max luma step at every hold boundary, against 0.25 between ordinary frames.

**Never grade with a fixed contrast pivot.** `eq=contrast` expands around 128, so what it
does depends on where the clip already sits. One hardcoded grade clipped **51.8%** of a
daylight clip (mean luma 208) to flat white while crushing 3.5% of a night clip to black.
Turning it down does not rescue it — `contrast=1.06` still clipped 39.4%.
`pipeline/grade.py` picks a preset from the clip and `finish.sh` verifies the result
against the ungraded render.

**No `unsharp` in the grade.** It rings on high-contrast lettering.

## Scripts

| File | Purpose |
|---|---|
| `pipeline/finish.sh` | Luma fix → source cadence → grade → selective 60fps |
| `pipeline/luma_stabilise.py` | Removes auto-exposure hunting (global level correction) |
| `pipeline/timing.py` | Derives a constant rate that represents the camera's real cadence |
| `pipeline/grade.py` | Picks a grade preset from the clip, and verifies it did not clip |
| `pipeline/selective_interp.py` | Interpolates normal gaps, holds through camera stalls |
| `pipeline/reframe_src.py` | Solves a deadzone virtual camera from YOLO detections |
| `pipeline/detect_car.py` | Per-frame subject detection (for tracked reframing) |
| `cloud/launch_pod.sh` | Rents a GPU, runs `run_on_pod.sh` on it, downloads the result, terminates it |
| `cloud/run_on_pod.sh` | Runs *on* the rented pod: installs, infers, verifies |
| `tests/run.sh` | The regression suite — no GPU, no footage needed |
| `tests/launch_pod.sh` | Exercises the pod launcher against stubs, no GPU needed |
| `tests/cloud_pod.sh` | Exercises the on-pod runner against stubs, no GPU needed |
| `tools/stall_discontinuity.py` | Scores how abrupt each stall exit is, against the clip's own motion |

## The experimental reframing path

`reframe_src.py` and `detect_car.py` are **not part of the pipeline above, and are not
runnable as shipped.**

Both operate in "STABFIRST" space — a 1408×1152 intermediate (4× the source, then a
centred 1.12× crop) that no step in this repository produces. The constants in
`reframe_src.py` are hardcoded to that geometry. `detect_car.py` records the space it
detected in, so a mismatch fails loudly rather than silently solving in the wrong
coordinates. Producing the STABFIRST intermediate is left undocumented.

`detect_car.py` imports `ultralytics` (**AGPL-3.0**) — see [NOTICE](../NOTICE). The
solver reads detections as JSON and does not import it, so a different detector can be
substituted at that boundary.

## Going deeper

[findings.md](findings.md) is the full engineering log: what was tried, what was ruled
out, and what the numbers were. The twenty failed pre-filters and the six failed
perceptual metrics are in there, which is the point — the dead ends are the most useful
part.
