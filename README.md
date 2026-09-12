# hoon-upscaler

[![tests](https://github.com/ScottMcCormack/hoon-upscaler/actions/workflows/tests.yml/badge.svg)](https://github.com/ScottMcCormack/hoon-upscaler/actions/workflows/tests.yml)

**Bring a 2007 phone video back to life.** This is an AI restoration pipeline for degraded
handheld footage — stabilisation, SeedVR2 upscaling, frame-timing repair and selective
interpolation.

It was built for one clip: a burnout at a Perth speedway, shot on a Nokia N90 at 352×288,
15fps, in heavily compressed mpeg4. It comes out at 1080p60. The recipe generalises to
other low-resolution phone and camcorder footage.

## See it

https://github.com/user-attachments/assets/96040f7b-cb6d-46a3-b7f1-a49a5599fa9e

Top: the 312×176 source, nearest-neighbour scaled — no smoothing, so nothing is flattered.
Bottom: the restored 1080p60 output. Thirty seconds from 0:24.

## What makes this different

Most upscaling is one model call. Almost all of the work here is in the four steps around
it, and each one exists because something was visibly wrong without it:

- **Timing is restored, not resampled.** The camera shot variable frame rate. Extract at a
  constant rate and a 267ms stall replays in 70ms — the car appears to teleport. The
  pipeline rebuilds the real per-frame cadence from the source's own timestamps.
- **Interpolation knows about the stalls.** Going to 60fps naively invents motion across
  gaps where the camera simply stopped. The selective pass interpolates ordinary gaps and
  *holds* through the stalls.
- **The grade is measured, not hardcoded.** A fixed grade is only right for footage that
  sits where it was tuned — one clipped **51.8%** of a daylight clip to flat white. The
  grade is picked from the clip and then verified against the ungraded render.
- **No pre-filter, deliberately.** Denoising before the model helped Real-ESRGAN and badly
  hurt SeedVR2, which is trained on degraded input and wants the artifacts left in.

The reasoning behind each, and the things that did not work, are in
[docs/findings.md](docs/findings.md).

## How it works

```
source (352×288, VFR, heavily compressed)
  │
  ├─ 1. stabilise          vidstab, translation only (maxangle=0), no crop
  ├─ 2. crop               remove fine mesh / clutter; fixes framing to 16:9
  ├─ 3. (no pre-filter)    deliberately
  ├─ 4. SeedVR2 upscale    3B fp16, resolution 1080, batch 33, overlap 5
  ├─ 5. luma stabilise     removes the camera's auto-exposure hunting
  ├─ 6. restore cadence    rebuild the source's real per-frame timing
  ├─ 7. grade              preset picked from the clip's own luma, then verified
  └─ 8. selective 60fps    interpolator picked from measured motion; holds through stalls
```

Steps 5-8 run as one command. [docs/pipeline.md](docs/pipeline.md) walks through all eight.

## Quick start

```bash
git clone https://github.com/ScottMcCormack/hoon-upscaler.git
cd hoon-upscaler
python3.12 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

You also need `ffmpeg` **built with vidstab**, and a SeedVR2 checkout beside this one —
[docs/setup.md](docs/setup.md) has both, and takes about fifteen minutes.

Then, with a stabilised and cropped source that SeedVR2 has upscaled:

```bash
bash pipeline/finish.sh raw_upscaled.mp4 MyClip in.mp4
```

That produces the source-cadence render, an ungraded reference, and the 60fps version.

No GPU? The upscale runs on a rented one for about **$0.34 for the whole clip** —
[docs/cloud-gpu.md](docs/cloud-gpu.md).

## Documentation

| | |
|---|---|
| [docs/setup.md](docs/setup.md) | Install: Python, ffmpeg/vidstab, SeedVR2, torch and the Blackwell trap |
| [docs/pipeline.md](docs/pipeline.md) | All eight steps, why they are in that order, and the script reference |
| [docs/cloud-gpu.md](docs/cloud-gpu.md) | Renting a GPU: which card, what it costs, what goes wrong |
| [docs/findings.md](docs/findings.md) | The full engineering log — what was tried, and what was ruled out |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Licence terms, branching, and the standard for adding findings |

## A note on what this produces

The source captured 352×288. Everything above that is **reconstructed, not recovered** —
the model infers plausible detail rather than revealing hidden detail. It is consistent and
convincing, but it is not evidence.

During development the model rendered a phone number on a sign cleanly and confidently as
`09 9270 5500`. The sign reads `08 9370 5600`.

Good for watching. Not for reading, and not a faithful record of what the camera captured.
If you share a render, say that it is AI-reconstructed.

## Licence

Apache-2.0 — see [LICENSE](LICENSE).

One caveat before reuse: `pipeline/detect_car.py` imports `ultralytics`, which is
AGPL-3.0, so the permissive licence here does not extend to that file's dependency chain.
[NOTICE](NOTICE) has the detail. No code licence covers the footage.
