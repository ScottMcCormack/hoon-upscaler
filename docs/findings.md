# Findings

What was tried and ruled out, so it isn't repeated. Source throughout: a 2007 Nokia N90
clip, 352×288, 15fps VFR, mpeg4 at 509kbps.

## Pre-filters — roughly twenty variants, all unnecessary in the end

The model speckled in dark areas. The cause turned out to be the **chain-link fence**:
fine mesh sitting at the resolution limit of a 352×288 source gives the model an aliased
signal, and it invents noise trying to reconstruct it.

| Filter | Result |
|---|---|
| `nlmeans`, `bilateral`, `smartblur` | Failed — edge-preserving by design, so they protect the very structure that needed removing |
| `lp85`, `lp75`, `gblur` (linear band-limit) | Failed — attenuate the mesh but leave its structure, so the model still tries to rebuild it |
| `blend50`, `blend75` (partial median) | Failed — half-strength median leaves half the mesh |
| `smartblur` radius >1.5 | Also inverted the `COAL PIT` lettering — it treats a letter's flat interior as a region to smooth |
| `removegrain` | No effect on the artifact — it clamps single pixels, but the blobs are ~3×3 |
| `median radius 1` | **Worked**, at ~30% of image detail |

**Then cropping the fence out of frame solved it completely and removed the need for any
pre-filter.** Median's cost on the cropped frame drops to 7.3%, so it isn't worth using
either. Solve the problem at the framing stage, not the filter stage.

## Metrics that failed

Six attempts to score the speckling and flicker artifacts:

1. Whole-frame high-frequency energy
2. Dark-flat-region spatial energy — masked out the fence, where the artifact lived
3. Dark-flat-region temporal flicker
4. Connected-component blob counting — counted legitimate texture
5. Textured-region temporal flicker — GOOD and BAD variants interleaved
6. Sign-region luma (for the lettering inversion) — identical across all variants

The best managed 1.93× separation on labelled examples and still ranked filters the
opposite way round to human judgement. The last correlated with sharpness at
**r = 0.88** — because speckle *is* high-frequency content, so any measure that finds one
finds the other.

**Metrics that were reliable:** frame counts, timing-gap analysis, boundary alignment,
VRAM/throughput, file integrity. All objectively defined.

## The seventh metric, which worked — and the control that made it trustworthy

`tools/stall_discontinuity.py`. Built to answer whether the selective pass's 3-frame
cross-dissolve still earns its place now that stalls are held by repeated frames rather
than by interpolation across a gap.

**Why this one behaves where six did not.** The failures all went looking for an artifact
whose *location was unknown* — somewhere in the frame, somewhere in the clip — and found
sharpness instead. A stall's exit time is known in advance, from the source timestamps.
There is nothing to search for; the only question is whether the frame-to-frame change at
that known instant exceeds the clip's own ordinary motion. That is boundary alignment,
already on the reliable list.

**The null control is not optional.** A max-over-window divided by a median exceeds 1 by
construction, so a raw ratio always looks like a finding; only comparing it against the
same statistic computed away from the stalls says whether it is elevated.

Current readings, from a fresh run on the 190-frame slice with four stall exits:

| variant | baseline | observed | null median | percentile | sharp@exit |
|---|---|---|---|---|---|
| ease 3 (cross-dissolve) | 3.0992 | 1.10 | 1.50 | **8th** | 0.920 |
| ease 1 | 3.1012 | 1.66 | 1.54 | 60th | 0.977 |
| ease 0 (hold, then cut) | 3.0988 | 3.35 | 1.48 | **100th** | 1.017 |

Read together: the dissolve makes stall exits far smoother than ordinary motion (8th
percentile) at a cost of 8% edge energy on the blended frames; removing it makes them the
most abrupt moments in the clip (100th) but leaves every frame sharp. That is a genuine
trade, not a defect on either side, and which one is right is a question for the eye.

**An earlier version of this table reported 22nd and 53rd percentiles and concluded there
was no discontinuity to fix.** Both numbers were wrong, for two separate reasons, and the
conclusion drawn from them was wrong too: the 53rd came from comparing the eased variant
against the raw interpolated stream rather than against ease 0, and both were computed
with a null control that compared a mean against single samples. Corrected below.

**What it does not do:** say whether a discontinuity is visible. A step twice the size of
ordinary motion may be imperceptible. Use it to find out whether there is anything worth
looking at, then look.

### The metric was wrong twice more before it settled

Recorded because the pattern matters more than the fixes.

**It had the sign backwards.** It scored the cross-dissolve variant as *smoother* and I
read that as mildly good. Smoothness bought by blending two displaced frames **is** the
ghost — a delta-only measure structurally cannot tell graceful continuity from a double
exposure. Scott saw the smear by eye; the number had rated it an improvement. An
`edge_energy` term now reports sharpness alongside abruptness, and the two together
separate the cases: smooth and sharp is good, smooth and soft is a dissolve smearing the
picture.

**The null control compared the wrong statistic.** The observed value is a mean over N
stall exits, but each null sample was a *single* window ratio. A mean of N has a narrower
spread than one sample, so the percentile was biased — and null candidates were only
checked at their centre, letting an eight-frame window overlap a stall it was supposed to
avoid. Sampling means of N clear windows moved the readings from 22/74/93 to
**8/60/100**. Same direction, sharper separation, and only now measuring what it claims.

The lesson is narrow and repeatable: **the control has to be the same statistic as the
observation.** Every wrong conclusion in this project's measurement history — including the
byte-identical verification that hid two cancelling defects — came from comparing against
the wrong baseline rather than from a bad idea.

## Models

| Model | Result |
|---|---|
| **SeedVR2 3B fp8/fp16** | The pick. fp16 and fp8 are visually identical; fp8 is 4× faster on constrained hardware |
| SeedVR2 7B (fp16, no offload) | 36% softer and 2.3× slower than 3B. Tested fairly on a 48GB card after two earlier handicapped attempts suggested the same |
| SwiftVR | Sharper background, distorted subject. 12× slower on 16GB — its 19GB of weights page from disk |
| FlashVSR | Not tested — needs Block-Sparse Attention compiled; viable on Ampere if revisited |
| Real-ESRGAN | Fast (2 min full clip) but no temporal model; text becomes confident gibberish |

## Upscale ratio

| Ratio | Result |
|---|---|
| 2.5× | Most conservative, least invention |
| 3.3× | Good balance |
| 4.1× | Holds up well |
| **6.1×** | **Also holds up** — on adequate hardware |
| 7.5× | Subject dissolved entirely |

Locally the ratio appeared to cap out around 3×, but those high-ratio runs were all
VRAM-starved, quantised, or running narrow temporal windows. Given proper hardware the
model handles far more. **Distinguish "the model can't" from "this GPU can't".**

## Temporal batch width

- 5 → 17: transformative, fixed the ghosting
- 17 → 65: further improvement
- 65 → 217: **indistinguishable** on a full watch, despite cutting seams from 23 to 7

Above ~65 the setting stops earning its VRAM.

## Motion and timing

- The camera is **VFR** — gaps of 67/133/200/267ms, stalling 2-4 frame periods about 3%
  of the time. Flattening this to CFR makes the subject appear to leap.
- `minterpolate` defaults to scene-change detection (`scd=fdiff`), which false-triggers at
  stalls and duplicates frames instead of interpolating. Use `scd=none`.
- **Selective interpolation** — interpolate normal gaps, hold through stalls, cross-dissolve
  back — beat every tuning of blanket interpolation. Don't invent motion the camera never
  captured.
- Correlation trackers (CSRT) fail on this footage: they slide onto the smoke within
  seconds while reporting a successful lock every frame. Detection-based tracking (YOLO)
  re-decides each frame and cannot drift.

## Interpolation and stall handling — five things ruled out, 2026-09-03

Run after the timing fixes landed, on a 190-frame slice of the real clip. All negative or
near-negative, which is why they are here: each one costs a couple of hours to re-derive.

### The selective pass is NOT redundant

With stalls now expressed as repeated frames, `minterpolate` holds them naturally, so the
substitution looked like it might have become a no-op. It has not. Comparing the pass's
FFV1 output against the exact interpolated stream it was fed:

| region | mean abs difference | max |
|---|---|---|
| outside stalls | 0.029 | 10.6 |
| inside stalls | **1.826** | 12.3 |

61 frames substituted, 55 inside stalls. The interpolator's natural hold is *close to* the
source frame but not equal to it, and the pass replaces the approximation with the real
thing. Keep it.

A first attempt compared two separately x264-encoded files and put the outside-stall figure
at 0.82 — that was codec noise read as signal. The lossless rerun is what settles it.

### No minterpolate setting recovers the 3.4% softening of synthesised frames

Three quarters of every 60fps frame is synthesised, and those measure ~3.4% softer than
frames landing on a real source instant. Nothing tested fixes that.

| variant | synth/real sharpness | p99 frame jump |
|---|---|---|
| aobmc / bidir / vsbmc (current) | 0.962 | 5.861 |
| aobmc / **bilat** / vsbmc | 0.974 | 5.996 |
| ffmpeg defaults | 0.974 | 6.021 |
| me=umh | 0.951 | 5.994 |

`me_mode=bilat` trades 1.2% sharpness for 2% rougher motion — a taste call, not a win, and
not adopted. `me=umh` is worse on both counts.

**Two of the three options the pipeline sets do nothing on their own.**
`mc_mode=obmc:vsbmc=1` and `mc_mode=aobmc:vsbmc=0` produce **byte-identical** files, so
`vsbmc` only takes effect with `aobmc`, and `aobmc` without it degenerates to `obmc`. Worth
knowing before anyone tunes them.

### The recovered tail is real motion, not padding

`tpad=stop=8:stop_mode=clone` pads the interpolator's input with clones. If those survived
the trim the clip would end on an artificial freeze. Tested on a slice deliberately ending
on **ordinary motion** (the full clip ends on a stall and cannot distinguish the two):
motion continues to the last real timestamp at 0.85× the body median, then three frames
hold. That hold is correct — the terminal frame's duration is one frame period, four frames
at 60fps.

### Grade order does not affect interpolation softness

The pipeline interpolates from the *graded* render, so the grade's 1.20 contrast boost might
have been amplifying an already-soft frame.

| order | ratio |
|---|---|
| grade then interpolate (current) | 0.962 |
| interpolate then grade | 0.960 |

No difference, and there is a documented reason not to reorder anyway: the selective pass
pulls held frames from the graded render, and mixing graded with ungraded puts a
10.5-mean/16.9-max luma step at every hold boundary. Leave it alone.

### Sources the pipeline was not built for

A stall-free CFR source works — 60 frames in, 60 at 15fps, 0 held, 240 output frames. The
stall machinery degrades to nothing rather than misbehaving.

Timing that no constant rate can express is refused rather than approximated: gaps of
50/70ms and 40/65/90ms are rejected, while 67/133/267ms and NTSC 15000/1001 are accepted.
Unit-tested in `tests/run.sh`, because building a video with genuinely irregular timing
turned out to be harder than testing the function.

### The ease ghost scales with camera movement, and every stall here moves

The cross-dissolve's damage is proportional to how far the camera travelled across the
stall — it blends two frames that far apart. Ground truth from consecutive source frames in
the master:

```
stall 119   200ms   4.09px
stall 128   200ms   4.17px
stall 145   267ms   3.55px
stall 188   267ms   8.18px
```

**Every stall in this clip carries 3.5-8.2px**, so there is no stall where blending is free.
A displacement-gated ease — dissolve only below a pixel threshold — was prototyped and
rejects all four at 2.5px, making it identical to `ease 0` here. The idea is sound; this
footage gives it nothing to work with.

An earlier version of this section reported 0.00px for two of those stalls. That was wrong:
the measurement read frames from the 60fps output at indices that both landed inside a hold,
so it compared a frame with itself.

## The cloud runner, first executed 2026-09-04

`cloud/run_on_pod.sh` existed for months without ever being run. `tests/cloud_pod.sh` now
drives it against stubs and catches most of what can go wrong, but the first real pod run
found something no stub could.

**PEP 668 killed it before inference.** The `runpod-torch-v280` template is Ubuntu 24.04,
which marks the system Python externally managed, so `pip install` refuses outright:

```
error: externally-managed-environment
```

The script died there on its first ever run. A venv is the reflex fix and the wrong one:
the point is to install *alongside* the CUDA-matched torch the image already ships, and the
pod is disposable. It now detects the `EXTERNALLY-MANAGED` marker and adds
`--break-system-packages` only when present, since older pips reject the flag.

Worth being precise about why the stub harness missed it: the stub `pip` was a no-op, so it
could never have surfaced this. Stubs prove the script's own logic — branch selection, the
guards, the frame check. They cannot prove anything about the environment it lands in.

**runpodctl 2.12.0 does not have `--terminate-after`.** The documented cost guard for a
throwaway pod does not exist in this version, so there is nothing to stop a forgotten pod
billing. Use `--wait --wait-timeout` to block until SSH answers, and arm your own watchdog.
Also `--gpu-id` wants the `gpuId` (`NVIDIA A40`), not the `displayName` (`A40`).

**SeedVR2 is not reproducible.** Re-rendering the same 1480-frame input at the same
resolution on the same model produced a different master:

```
frames compared      1480
identical            0
median PSNR          39.2 dB    (min 31.1 dB)
```

Every frame differs. 39 dB is close enough that the two are probably hard to tell apart by
eye, but they are not the same file and never will be. The cause was not isolated — a fresh
SeedVR2 checkout, no seed is passed, and CUDA kernels need not be deterministic.

The consequence matters more than the cause: **a master cannot be recreated, only kept.**
That is exactly why `masters/` exists and why its README says every downstream choice can be
re-run from there for free. Re-deriving one is not a fallback; it produces a different
starting point.

## All three VRAM branches, measured on hardware 2026-09-04

`run_on_pod.sh` picks one of three configurations from the card's reported VRAM. Until now
only the top branch had ever run. All three, one 15-second test each:

| card | reported | branch | resolution | result |
|---|---|---|---|---|
| A40 | 46368 MB | fp16, batch 33 | 720 | 214 frames, 5m24s, **0.68 fps** |
| A40 | 46368 MB | fp16, batch 33 | 720, full clip | 1480 frames, 25m11s, **0.98 fps** |
| RTX 4090 | 24564 MB | fp16, batch 17 | 720 | 214 frames, 5m23s, **0.68 fps** |
| RTX A4000 | 16376 MB | fp8 + offload | 720 | **OOM in the VAE** |
| RTX A4000 | 16376 MB | fp8 + offload | 540 | 60 frames, **1.01 fps** |

**The 4090 at batch 17 matched the A40 at batch 33** — 5m23s against 5m24s. Batch width is
about temporal coherence, not throughput, so the extra VRAM buys quality rather than speed
at this clip size. Worth knowing before paying for a bigger card on speed grounds.

**The low-VRAM branch is not broken, but 720 is out of reach for 16GB.** It dies with
`torch.OutOfMemoryError` inside `attn_video_vae.py`, in the VAE rather than the DiT — so
`--blocks_to_swap 16` and the CPU offload flags, which act on the DiT, cannot save it. The
same card completed 540 comfortably. That is the cliff CLAUDE.md describes, located
precisely: between 540 and 720 output on 16GB.

The script now warns before that combination rather than letting someone discover it after
paying for setup. A warning, not a refusal: the branch covers 16-22GB and the exact limit
moves with the card.

