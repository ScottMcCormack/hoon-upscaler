# Findings

What was tried and ruled out, so it isn't repeated. Source throughout: a 2007 Nokia N90
clip, 352×288, 15fps VFR, mpeg4 at 509kbps.

## Contents

Roughly chronological within each group. Every entry records something that was
tried and settled, so it is not tried again; `CONTRIBUTING.md` sets the standard for
adding one. `tests/run.sh` asserts that this list covers every section, so appending
one without listing it here fails the suite.

**What the model needs**

- [Pre-filters — roughly twenty variants, all unnecessary in the end](#pre-filters--roughly-twenty-variants-all-unnecessary-in-the-end)
- [Models](#models)
- [Upscale ratio](#upscale-ratio)
- [Temporal batch width](#temporal-batch-width)

**Measuring the unmeasurable**

- [Metrics that failed](#metrics-that-failed)
- [The seventh metric, which worked — and the control that made it trustworthy](#the-seventh-metric-which-worked--and-the-control-that-made-it-trustworthy)

**Timing and interpolation**

- [Motion and timing](#motion-and-timing)
- [Interpolation and stall handling — five things ruled out, 2026-09-03](#interpolation-and-stall-handling--five-things-ruled-out-2026-09-03)
- [minterpolate cannot interpolate a fast pan, 2026-09-06](#minterpolate-cannot-interpolate-a-fast-pan-2026-09-06)
- [The interpolator threshold was measured in the wrong units, 2026-09-08](#the-interpolator-threshold-was-measured-in-the-wrong-units-2026-09-08)
- [The interpolator's blind spots were all in what it did not look at, 2026-09-11](#the-interpolators-blind-spots-were-all-in-what-it-did-not-look-at-2026-09-11)
- [Fixing the multiplier did not fix the rate, 2026-09-11](#fixing-the-multiplier-did-not-fix-the-rate-2026-09-11)
- [Even timestamps are not even motion, 2026-09-11](#even-timestamps-are-not-even-motion-2026-09-11)
- [A full-branch self-review found four stale numbers no round had checked, 2026-09-11](#a-full-branch-self-review-found-four-stale-numbers-no-round-had-checked-2026-09-11)
- [p95 over a whole clip discards its top 5% by definition, 2026-09-11](#p95-over-a-whole-clip-discards-its-top-5-by-definition-2026-09-11)
- [An independent high-effort review found ten more, all in code no round had touched, 2026-09-11](#an-independent-high-effort-review-found-ten-more-all-in-code-no-round-had-touched-2026-09-11)
- [CI failed twice on a test that passed locally both times, 2026-09-11](#ci-failed-twice-on-a-test-that-passed-locally-both-times-2026-09-11)
- [`git checkout` on a file with real uncommitted work silently discarded it, 2026-09-11](#git-checkout-on-a-file-with-real-uncommitted-work-silently-discarded-it-2026-09-11)
- [A second review round found six more, mostly the source-vs-render mixup repeating, 2026-09-11](#a-second-review-round-found-six-more-mostly-the-source-vs-render-mixup-repeating-2026-09-11)
- [The atomicity fix itself broke the RIFE path, and "lossless" wasn't, 2026-09-12](#the-atomicity-fix-itself-broke-the-rife-path-and-lossless-wasnt-2026-09-12)
- [round() can stop the output schedule short of the last frame, 2026-09-12](#round-can-stop-the-output-schedule-short-of-the-last-frame-2026-09-12)
- [The schedule's own target was one frame-duration short of the clip's real length, 2026-09-12](#the-schedules-own-target-was-one-frame-duration-short-of-the-clips-real-length-2026-09-12)
- [A downsampling request would close the decoder's pipe before it finished writing, 2026-09-12](#a-downsampling-request-would-close-the-decoders-pipe-before-it-finished-writing-2026-09-12)
- [The standalone interpolation CLI silently dropped every audio track, 2026-09-12](#the-standalone-interpolation-cli-silently-dropped-every-audio-track-2026-09-12)
- [A packet count is not a frame count, and a container can refuse a codec outright, 2026-09-12](#a-packet-count-is-not-a-frame-count-and-a-container-can-refuse-a-codec-outright-2026-09-12)
- [My own audio fix cost the pipeline a redundant remux, and could delete a finished render, 2026-09-12](#my-own-audio-fix-cost-the-pipeline-a-redundant-remux-and-could-delete-a-finished-render-2026-09-12)
- [The stride grid's blind spot was never only at the tail, 2026-09-12](#the-stride-grids-blind-spot-was-never-only-at-the-tail-2026-09-12)

**Grading**

- [The grade was clipping half the picture, 2026-09-06](#the-grade-was-clipping-half-the-picture-2026-09-06)

**Renting a GPU**

- [The cloud runner, first executed 2026-09-04](#the-cloud-runner-first-executed-2026-09-04)
- [All three VRAM branches, measured on hardware 2026-09-04](#all-three-vram-branches-measured-on-hardware-2026-09-04)
- [Record the parameters or the render is uninterpretable](#record-the-parameters-or-the-render-is-uninterpretable)
- [Durable output and A40 availability are currently mutually exclusive](#durable-output-and-a40-availability-are-currently-mutually-exclusive)
- [A pod is not necessarily yours alone](#a-pod-is-not-necessarily-yours-alone)

**What review keeps finding**

- [Argument validation, reviewed adversarially 2026-09-06](#argument-validation-reviewed-adversarially-2026-09-06)
- [The tests that guarded the manifest could not read it, 2026-09-06](#the-tests-that-guarded-the-manifest-could-not-read-it-2026-09-06)
- [The fix for an asymmetry was itself asymmetric, 2026-09-07](#the-fix-for-an-asymmetry-was-itself-asymmetric-2026-09-07)
- [Round three, part two: the same fix missing from a fourth file, twice](#round-three-part-two-the-same-fix-missing-from-a-fourth-file-twice)
- [Copilot on the grade: two real defects and one half-right, 2026-09-07](#copilot-on-the-grade-two-real-defects-and-one-half-right-2026-09-07)
- [Two adversarial reviews of the grade change, 2026-09-07](#two-adversarial-reviews-of-the-grade-change-2026-09-07)
- [Failing loudly is not the same as failing safely, 2026-09-08](#failing-loudly-is-not-the-same-as-failing-safely-2026-09-08)
- [Scanning every frame did not close the hole it was supposed to, 2026-09-08](#scanning-every-frame-did-not-close-the-hole-it-was-supposed-to-2026-09-08)
- [Reviewing my own work found what the reviewers had already fixed, 2026-09-08](#reviewing-my-own-work-found-what-the-reviewers-had-already-fixed-2026-09-08)

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

`cloud/run_on_pod.sh` was committed on 2026-08-31 and first run on 2026-09-04 - four days
unexecuted, not the "months" an earlier draft of this line claimed. `tests/cloud_pod.sh` now
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

**SeedVR2 IS deterministic — an earlier entry here said the opposite and was wrong.**

Two renders of the same clip, back to back on one pod, produced **byte-identical output**:

```
resolution, model, extra_args, fixed_args, gpu, torch, seedvr2_commit, input sha256   all identical
output sha256   40003bbf860a7310f48b32fb23c72577…   (both runs)
```

The earlier claim came from comparing a fresh batch-33 render against the batch-65 720p
master and finding all 1480 frames different. That was a parameter difference, not
nondeterminism — the same mismatched-baseline error CLAUDE.md now warns about, made while
writing up the previous finding.

What this changes: **a master can be recreated, provided you have its parameters.** That
makes the manifest the load-bearing artifact rather than the master file itself. It also
makes `BATCH_SIZE`/`TEMPORAL_OVERLAP` overrides worth having, since the VRAM branch picks
settings for a fresh render and cannot select the batch 65 the 720p master was built with.

**Confirmed against a real master.** The 1080p master, rendered 2026-08-29 and
reproduced 2026-09-05 - seven days, not months - was
reproduced from its recorded parameters:

```
master  sha256 8412f5bd5d662b03cc70b43f6a428658affae9a24ce9a5e1   273,813,416 bytes
repro   sha256 8412f5bd5d662b03cc70b43f6a428658affae9a24ce9a5e1   273,813,416 bytes
```

That is stronger than the two-runs-on-one-pod test, because it clears confounds that test
could not: `chunk_size`, the cache flags and `color_correction` were unrecorded for that
master, and the SeedVR2 revision was unknown. A byte-identical result means all of them
match the script's current values.

`masters/` still earns its place — it saves the GPU spend and the wait — but it is a cache,
not an irreplaceable original.

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
same card completed 540 comfortably, at 1.01 fps.

**This is probably not the cliff CLAUDE.md describes, and the difference matters.** That
entry records ~1.3s/frame below the limit against ~25s/frame above it — a 19x slowdown
that still *finishes*, on the local RTX 5060 Ti. What the A4000 does at 720 is die with
zero frames. A run that completes 19x slow and a run that produces nothing are different
failure modes, and the two cards are different architectures with the same 16GB. No
throughput number exists for a completing-but-slow 720 on 16GB, so nothing here locates
the 5060 Ti's cliff; what it locates is the A4000's OOM boundary, between 540 and 720.

Recorded as two adjacent limits rather than one, because collapsing them would be the same
mistake this file already documents four times: a sound measurement compared against
something that differs by more than the variable under test.

The script now warns before that combination rather than letting someone discover it after
paying for setup. A warning, not a refusal: the branch covers 16-22GB and the exact limit
moves with the card.

## Record the parameters or the render is uninterpretable

Every master needs its full invocation stored beside it. `cloud/run_on_pod.sh` writes a
`.json` manifest with the argument list, model, resolution, GPU and VRAM, torch version,
SeedVR2 commit, and frame counts plus sha256 for input and output.

The cost of not having this was concrete. `masters/README.md` recorded batch and overlap
only, so when a fresh render was compared against the 720p master and every frame differed,
the obvious reading was that SeedVR2 is nondeterministic. It was not evidence of anything:
the master is batch 65 and the render was batch 33. Different questions, different answers.

`chunk_size`, the cache flags, `color_correction` and the SeedVR2 revision were unrecorded
for both existing masters. That turned out not to matter — the 1080p master reproduced
byte-for-byte, so all of them match the script's current values — but it was not knowable
in advance, which is the point.

The 720p master needs `BATCH_SIZE=65` passed explicitly, since the A40 branch derives batch
33 and nothing selects 65 from VRAM alone. That override exists precisely because the
branch chooses for a *fresh* render and reproducing one is a different job.

The general form of this is already in CLAUDE.md: a comparison is only evidence if you can
state what differs between the two things. A manifest is how you state it after the fact.

## Durable output and A40 availability are currently mutually exclusive

A pod's local disk dies with the pod. A power cut on the controlling machine cost one
1080 render (~$0.66) because nothing local survived to download it, and the pod was
orphaned until it was noticed by hand.

The fix is a network volume, which outlives the pod. It cannot be used with an A40:

```
A40 stock          CA-MTL-1 (Low), EU-SE-1 (none), US-MO-1 (none)
volume-capable DCs CA-MTL-3, CA-MTL-4, EU-FR-1, EU-NL-1, EU-RO-1, EUR-IS-1, US-MO-2, …
                   — neither CA-MTL-1 nor EU-SE-1 among them
```

The cheapest volume-compatible card at 48GB is an RTX 6000 Ada at $0.84/hr against the
A40's $0.49. But price is not the reason to avoid it: **determinism has only been verified
within one card.** Cross-GPU determinism is untested, so reproducing an A40-made master on
a different architecture would confound the result — a mismatch could be floating-point
kernel differences rather than anything about the pipeline.

The asymmetry is worth remembering: on a different card, a *match* would prove a lot
(determinism holds across architectures too); a *mismatch* would prove nothing. So use a
volume for any run that is not reproducing an existing A40 master, and accept the local-disk
risk for the ones that are.

## A pod is not necessarily yours alone

`cloud/run_on_pod.sh` does not create or destroy pods — it runs *on* one and tells you to
terminate it yourself. Everything below concerns the orchestration around it, which for
these runs was a throwaway local script, not part of this repository.

That script terminated its pod from an `EXIT` trap, bounding the pod's life by the work
rather than by a timer. That was the right fix for the failure before it: an earlier run
armed only a *watchdog*, which knew the clock and nothing else, so a render that finished
in about an hour sat idle until a two-hour timer killed it — $1.01 for a completed render
that was never downloaded.

But the trap nearly caused a worse loss. A second, unrelated workload was started on the
same pod, and the trap would have torn it down the moment the first render's download
finished. The trap catches `INT` and `TERM`, so killing the orchestrator would have
triggered exactly what needed preventing; `SIGKILL` was the only way to stop it firing.

Three finished renders belonging to that other job were still sitting undownloaded when
teardown was requested. Terminating would have destroyed them.

**Before any teardown, automatic or manual, check what is actually there:**

```bash
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv
pgrep -af inference_cli
ls -lh /workspace/cloud/*.mp4        # is every output actually downloaded?
```

The general lesson is not about traps. Automatic cleanup has to establish that it owns the
thing it is cleaning up, and a rented pod is shared infrastructure the moment anyone else
touches it.

## Argument validation, reviewed adversarially 2026-09-06

An adversarial review of `cloud/run_on_pod.sh` found five accepted-but-wrong inputs. Four
cost money or credibility rather than crashing, which is why none had been noticed.

**The two guards were written in the same commit, to different standards.** The override
validation says `[[ "$val" =~ ^[0-9]+$ ]] && [ "$val" -gt 0 ]`. The resolution guard,
twenty lines away, says only `[[ "$RES" =~ ^[0-9]+$ ]]` — while printing "must be a
positive integer" when it fails. So `run_on_pod.sh 0 test` ran to completion. It did not
error; it produced a render and a manifest recording `"resolution": 0`. The manifest work
exists to make renders interpretable, and here it faithfully recorded a setting that was
never meant to be reachable.

Having written the stricter form once is not evidence it was applied everywhere. Grep for
the standard, not for whether the idea occurred to you.

**`${2:-full}` cannot distinguish an omitted argument from an empty one.** Omitting the
mode meaning "full" is deliberate and documented. But a wrapper passing through an unset
variable arrives as an empty string and gets the same answer — and the answer is the
chargeable full render rather than the 15-second test. A default that is merely wrong is
a bug; a default that is wrong and bills for it is the one worth guarding. Empty is now
refused. The documented default was left alone: it is an interface, not a defect.

**Batch overrides were only guarded downward.** The OOM warning keys on resolution, but
VRAM is driven by batch width too, and overriding upward is exactly what reproducing the
720p master's batch 65 on a smaller card requires. The guard existed on one side of a
cliff that has two.

A methodological note, from getting it wrong during the same session: the five new tests
were mutation-checked by reverting the script and confirming each one fails. That is the
right check, but it was run against the shared working tree while a second review agent
was executing the same suite, which killed its run mid-flight and made its results
unusable. Mutation testing mutates shared state. Do it in a worktree or a copy when
anything else is reading the tree.

## The tests that guarded the manifest could not read it, 2026-09-06

A second adversarial review, of the tests and the docs rather than the shell, found that
the manifest test validated everything except the manifest.

`manifest: carries the full invocation and both checksums` checked that nine keys existed,
that `seedvr2_commit` matched `^[0-9a-f]{40}$`, that `torch` looked like a version, that
`gpu.name` was unpolluted, and that `resolution` was an `int`. Every one of those is a
check on *shape*. None compared a recorded value against what was actually invoked.

Demonstrated by mutation: hardcoding `"resolution": 999` and
`"model": "WRONG_MODEL.safetensors"` into the writer passed all 59 tests. So did replacing
`sha256()` with a function returning the literal string `not-a-real-hash` — in a test whose
name promises "both checksums", three lines from a field checked against a 40-hex regex.

The manifest exists so two renders can be told apart. A test that cannot distinguish a
truthful manifest from a fabricated one guards nothing, and it would have passed happily
through exactly the confusion the manifests were introduced to end: the 720p master's
batch 65 recorded nowhere, and a batch-33 render compared against it to "disprove"
determinism.

The test now takes the expected values as arguments — `720 test 33 5 <model>` — supplied
from the invocation rather than read back out of the file under test. Reading the artifact
to decide what the artifact should say is the mismatched-baseline error at its smallest.

**A second gap, from the same cause.** Every one of the 29 cloud cases passed both
positional arguments explicitly. The values used when they are *omitted* had never been
executed. Flipping `MODE="${2:-full}"` to `${2:-test}` — silently swapping the chargeable
render for the free one, or the reverse — passed the entire suite, in the same commit that
had just added a guard because "the wrong guess is the chargeable full render". The guard
went on the adjacent case and missed the fundamental one.

The rule that catches both: a test asserts against something *outside* the thing it tests,
and the arguments a script is normally called with are not its defaults.

**Three false "months" claims.** This file said the cloud runner "existed for months
without ever being run" under a heading reading "first executed 2026-09-04"; it was
committed on 2026-08-31, four days earlier. It said the 1080p master was reproduced
"months later" when the interval was seven days. `masters/README.md` repeated it. The
repository's first commit is 2026-08-29 — nothing in it can be months old. An invented
interval, in the document that catalogues other unverified claims, added because it made
the finding sound weightier. Dates are cheap to check: `git log --diff-filter=A` settles
every one of them.


## The fix for an asymmetry was itself asymmetric, 2026-09-07

Round three of the adversarial review found one defect, and it was in the fix from round
one. The commit titled *"Apply the same integer standard to every argument the runner
accepts"* added an explicit-empty guard for the mode and did not add one for the
resolution, though `${1:-720}` and `${2:-full}` substitute on empty identically.

The resolution case is the worse of the two. A lone empty argument also leaves `$2` unset,
so `run_on_pod.sh ""` selects **720 and full** — the chargeable render, at a resolution
nobody chose — completes, and writes a manifest reading `"resolution": 720, "mode": "full"`
with nothing to mark it as unintended. Confirmed by execution against the stub harness.

That is three instances of the same shape: `RES` vs the override validation, the mode guard
vs the resolution guard, and the manifest test's shape checks vs its absent content checks.
Each time the reasoning was written down correctly and applied to one of two places.

The rule now in CLAUDE.md: when you tighten a check, grep for every other input of the same
kind and tighten those in the same commit. The untightened twin is where the next bug lives.

Worth noting what caught it. Two rounds of review had already read this file, and the
defect survived both because it was introduced *by* the first round's fix. New code written
in response to a review is not reviewed code, and is disproportionately likely to be wrong —
it is written quickly, under the impression that the area is now understood.

## Round three, part two: the same fix missing from a fourth file, twice

The tests-and-docs review found five defects. Two of them are the rule from the section
above, caught in the act.

**"Months" survived in `cloud/run_on_pod.sh`.** The correction went to `CLAUDE.md`,
`docs/findings.md` and `masters/README.md`. The runner — the file the whole story is about,
and the one under test — kept the false claim in two comments. **The README kept the
conflated 16GB cliff** for the same reason: the correction was applied to three files and
the fourth was not searched for. Both were fixed by grepping rather than by remembering.

**The timeout diagnostic was dead code from the moment it was written.** The branch tested
for exit status 137 on the reasoning that `--signal=KILL` produces 128+9. `timeout` reports
**124** whenever it fires, whatever signal it sent; the signal only reaches the status with
`--preserve-status`. So the helpful message never appeared and the generic one did. Written,
committed, and never once executed - `timeout --signal=KILL 1 sleep 5; echo $?` would have
settled it in two seconds. The value is also no longer hardcoded into its own message,
which had already desynced during testing.

**Format checks are not content checks, still.** Round two tightened `sha256` from
truthiness to a 64-hex regex, which a `sha256()` returning `"ab" * 32` satisfies - the same
fixed, content-blind value for two different files. `gpu.name`, `torch` and
`seedvr2_commit` were regex-checked only, so `"Definitely Not A40"`, torch `9.9.9` against
a stub reporting `2.4.0`, and a well-formed fabricated commit all passed. The test now
recomputes both hashes from the files on disk and compares the three environment fields
against what the stubs are configured to emit.

Tightening a check one notch is how this survived two rounds: truthiness to format looks
like progress and stops short of the actual question, which is whether the value is *true*.

**Two of three VRAM branches never had their arguments checked.** Only the top branch's
real `--batch_size`/`--temporal_overlap` were verified, through the happy-path manifest.
The other two were confirmed by their banner text alone, so setting the fp8 branch's
`EXTRA` to `--batch_size 999 --temporal_overlap 999` passed the entire suite while printing
the correct banner. The bottom branch is the least checked and the most complex - it carries
the offload flags and covers the widest VRAM range. Both are now pinned to their manifests.

**A fixture that was too convenient.** Adding the recomputed-hash check immediately failed
with "input and output sha256 are identical". Not a bug in the check: the stub built its
output from the same `testsrc2` at the same settings as the input, so the two files were
byte-identical, and a bug recording the input's hash for the output would have been
invisible. The stub now emits a different pattern at a different size, which is also what a
real upscale does.

## The grade was clipping half the picture, 2026-09-06

`finish.sh` hardcoded `eq=contrast=1.20:saturation=1.28:gamma=0.96`. `eq`'s contrast
expands around a **fixed pivot of 128**, so what it does to a clip depends entirely on
where that clip's content sits relative to 128 — which nothing was checking.

```
                     mean Y    clipped to white    crushed to black
N90 night clip        139.6          1.7%                3.5%
MVI_0081 graded       214.1         51.8%                0.02%
MVI_0081 ungraded     208.1          1.8%                0.00%
```

**51.8% is not a look, it is deletion.** The tarmac sits at 230-245; the transfer function
maps everything above ~236 to 255, so every difference within that band becomes the same
white. It was spotted by eye first — "it looks like the car is on a white plane" — and the
measurement only confirmed what the eye had already found.

The N90 clip has the same bug at the other rail. Its 3.5% crushed black was visible during
development and read as acceptable because the subject was a white car against dark tarmac.
It is the same defect, quieter.

### Turning the constant down does not work

The obvious fix is a gentler contrast. Measured on MVI_0081:

```
contrast=1.20   51.8% clipped
contrast=1.06   39.4% clipped
```

A 6% expansion still destroys a third of the frame, because at mean 208 the content is
already within ~20 units of the ceiling. **There is no safe value of `eq=contrast` for this
footage** — the pivot is wrong, not the gain. That is what sent the fix to `curves`.

### What replaced it

`pipeline/grade.py` measures the clip and picks among three fixed presets, and `finish.sh`
then verifies the result. `GRADE` still overrides, and an explicit `GRADE` is verified too.

The verification is the load-bearing part: it compares clipped and crushed fractions
against the *ungraded* render of the same clip and fails if grading made either materially
worse. A blown source is the camera's doing and is allowed; a grade that adds clipping is
not. That check rejects the old grade outright, which is the property worth having.

### The automatic curve that was tried and abandoned

The first three attempts synthesised a curve per clip from its own percentiles rather than
selecting a preset. Each was tuned to land closer to a curve already approved by eye, and
each stayed measurably worse than it:

```
                            tarmac stdev (local contrast, higher = more detail)
ungraded                              39.22
synthesised, linear ramp              32.95
synthesised, squared ramp             32.95
synthesised, two-anchor p50/p99       36.78
hand-tuned, approved by eye           39.03
old grade                             44.43   <- but 51.8% clipped, so this is
                                                 the variance of a half-white frame
```

Three iterations of an automatic thing chasing a target only an eye can call is the shape
of the six failed perceptual metrics above. So the curves are fixed rather than
synthesised, only the *choice* between them is automatic, and only clipping — which has an
objective definition — is asserted anywhere.

Fixed is not the same as approved, and the distinction is enforced rather than described: a
curve becomes auto-selectable only after it has been checked by eye, and until then it sits
in `UNREVIEWED` and the picker falls back to `neutral`. `dark` is in that state today — see
the later section on this. An earlier version of this paragraph said the curves were
"fixed and eye-checked", which was true when written and became false in the same PR that
introduced the gate.

Note the last row: the old grade scores *highest* on local contrast. Any metric rewarding
contrast would have preferred it. That is the same trap as the speckle metric that
correlated with sharpness at r = 0.88.

## Copilot on the grade: two real defects and one half-right, 2026-09-07

**A sampled guard cannot assert what it does not look at.** `verify` compared ungraded
against graded using every 20th frame, so damage confined to a shorter run passed unseen.
Demonstrated: a 40-frame clip with frames 1-9 blown to white measures **0.00% clipped at a
stride of 20 and 22.50% scanning every frame** - the sampled check called a clip a fifth
destroyed "verified".

Sampling is now a speed knob for *choosing* a preset only. The guard scans every frame,
which it can afford because the statistics come from a streamed 256-bin histogram rather
than a buffered array: constant PIXEL memory, one frame at a time. (A later round added
per-frame rail statistics, which are linear but tiny - see the section on the averaging
gap below; this paragraph originally said "constant memory regardless of clip length" and
that stopped being true.) Buffering every frame of a 1480-frame 1080p render would be
~3GB on a machine whose notes already record the OOM killer taking processes out. uint8 has 256 possible values, so mean and percentiles from
the histogram are exact, not approximations.

**A test that proved only that a message was printed.** `GRADE="eq=saturation=1.0"` is an
identity filter, and the assertion matched a line emitted *before* ffmpeg ran. Mutation-
proved: making `finish.sh` announce "grade: explicit" and then silently discard the
override left the test passing. It now uses `saturation=0`, requires exit 0, and reads
`signalstats.SATAVG` back out of the render - measuring the effect rather than the
announcement.

**Copilot was half right here, and the half it got wrong matters.** It claimed the same
flaw applied to the adjacent `contrast=4.0` case. It does not: that filter is not an
identity, and the same mutation *fails* it, because the assertion depends on the grade
having been applied and then measured. Reviewing the claim by mutation rather than by
agreement is what separated the two.

**An unreviewed preset was auto-selectable.** The `dark` curve carried a comment saying it
had not been checked by eye, in a module whose docstring says every curve was. The
measurement could select it, and an unapproved look would be baked into a master silently.
It is now in `UNREVIEWED`: `pick` still reports it as the measurement's honest answer, but
the CLI falls back to `neutral` and says so on stderr unless `GRADE_ALLOW_UNREVIEWED=1`.
Neutral is safe rather than good - it shapes the middle and leaves the rails alone.

No footage in the project currently reaches it: `full_169.mp4` and `test_15s.mp4` measure
neutral, `mvi0081_full.mp4` measures bright. So this closed a latent trap rather than a
live one - worth saying, because "we would have noticed" was the reasoning that let the
fixed grade clip 51.8% of a daylight clip in the first place.

## Two adversarial reviews of the grade change, 2026-09-07

Correctness and simplicity, reviewed separately. Both earned their keep, and the most
useful result was a rejected suggestion.

**A truncated file measured clean and passed the guard.** ffmpeg exits **0** after dropping
frames it cannot decode, so a file cut by 600 bytes decoded 25 of its 60 frames, reported
`clipped 0.000%`, and passed `verify` — on a render that is 50% blown white. `CLAUDE.md`
already records this exact trap for inference output; the grade guard had no equivalent.

The fix needed a second correction. Comparing decoded frames against `-count_packets`
catches nothing: a truncated file *recounts* to whatever survived, so the reference agreed
with the damage. `nb_frames` comes from the header and survives truncation — 60 declared
against 25 recounted. **A cross-check is only as good as its reference, which is this
project's recurring error wearing another hat.**

**A two-pipe deadlock.** `histogram` drained stdout in a blocking loop and read stderr only
afterwards. On a densely corrupted file ffmpeg wrote 128KB of decode errors, filled the
stderr pipe, and blocked; the loop waited for stdout that could never arrive. Reproduced,
hung until killed. stderr now goes to a temp file, never a pipe.

**Snapping a percentile to a bin edge is not the same as interpolating one.** `np.percentile`
interpolates between order statistics; `searchsorted` on a cumulative histogram does not,
and the two disagreed by up to 9 luma levels. It reached a decision: 603 pixels at 151 and
7 at 250 give **p99 = 241.09 interpolated and 250.00 snapped**, which crosses `pick`'s
`p99 >= 250` and silently changes the preset. Now reproduces numpy to 9e-16 across 2000
random arrays. `verify` never touches percentiles, so the guard was never affected — worth
stating, because "it's in the measurement code" is not the same as "it's in the guard".

**Sampling barely sampled.** `select` without `-fps_mode passthrough` lets ffmpeg's default
sync duplicate frames back up to a constant rate, so `every=20` decoded ~70% of the clip
rather than 5%. The comments calling it a speed knob were describing an intention. Now
`every=20` on a 60-frame clip decodes 3 frames.

**The rails had no test.** `counts[254:]` -> `counts[255:]` and `counts[:2]` -> `counts[:1]`
both passed the entire suite. `pick` and `verify` only need gross classification, so nothing
pinned where the rail actually starts. `summarise(counts)` is now separate from `stats(path)`
so the boundary can be asserted without an encoder in the way.

### The rejected suggestion is the most valuable result

The simplicity review was asked whether ffmpeg's own `signalstats` could replace the numpy
histogram entirely. It built that version and found it computes **silently wrong numbers**:

```
                numpy    signalstats mask
bright         67.19%          12.85%
dark          100.00%          51.17%
gap_graded     22.50%          22.50%   <- agrees, misleadingly
```

Feeding a constant through `lutyuv` emits **214 for a requested 200** — `(200-16)*255/219`
— a limited-to-full range rescale inside the filter graph that a plain `format=gray` decode
does not apply. The two fixtures that agreed did so only because their damage sits exactly
on the 0/255 rails, which a range rescale leaves fixed. **A partial agreement on the cases
you happen to test is the most dangerous result available**, and it is the mismatched-baseline
error again, this time hiding inside ffmpeg's colorspace negotiation.

### What was simplified

Reading `frame_bytes * 8` per iteration measured *slower* than one frame at a time (1.60s
against 1.38s on 200 frames at 1080p) — a guessed constant that cost performance and
clarity. And `finish.sh` called `grade.py pick` twice for the same clip, once for the filter
and once for the name, decoding the whole render each time; `--both` makes it one call.

The memory justification held up under measurement rather than assertion: 622MB for 300
frames at 1080p, extrapolating to 3.07GB for the real clip, against ~2KB of bins.

## Failing loudly is not the same as failing safely, 2026-09-08

A second Copilot review on the grading PR, after the first round's fixes. Three findings,
all correct, all verified by execution before being accepted.

**The deliverable was written before it was checked.** `finish.sh` encoded the graded render
straight to `OUT_DIR` and ran the clipping guard afterwards. `set -e` stops the pipeline on a
refusal, which felt sufficient - but by then the destroyed file is sitting where a
deliverable belongs, and it has already overwritten the previous good render. Both encodes
now go to the work directory and are moved into place only after the guard passes.

The distinction is worth naming: **failing loudly is not the same as failing safely.** This
project has already shipped one plausible-looking bad file - a truncated render that only
its duration gave away - so a bad artifact in the output directory is exactly the failure
mode that survives an error message nobody scrolls back to read.

**A friendly diagnostic that could never run.** `dims()` called ffprobe with `check=True`,
which raises `CalledProcessError` before the "missing, unreadable, or not a video" message
below it. On the commonest bad input - a path that is not a video - it produced a traceback.
Dead code written in the same commit as the check it defeats, which is the third instance of
that shape in this branch after the `timeout` 137 branch and the mode/resolution guard pair.

**A relative import three lines from a correct one.** The new rails test did
`sys.path.insert(0, "pipeline")`, rooted at the caller's working directory, while the
existing snippet in the same file passes `"$REPO"` in for exactly this reason. Running
`bash /path/to/tests/run.sh grade` from anywhere else failed to import `grade`. Confirmed by
running the suite from `/tmp` - 11 passed, 1 failed - and fixed by copying the pattern that
was already there.

The pattern across all three: each was introduced *by* a fix from the previous review round.
New code written in response to review is not reviewed code, and this is now the second time
that has been the round's main lesson.

## Reviewing my own work found what the reviewers had already fixed, 2026-09-08

After rebasing onto the CI branch, a systematic mutation sweep of the grading code -
ten mutations, one per behaviour the tests claim to protect - found **two survivors**, and
both were fixes made in response to earlier review that were never pinned by a test.

```
clipped rail 254 -> 255            caught
crushed rail :2 -> :1              caught
verify samples instead of scans    caught
UNREVIEWED gate disabled           caught
frame_count recounts packets       caught
TOLERANCE 0.005 -> 1.0             caught
deliverable moved before verify    caught
explicit GRADE discarded           caught
dims check=True restored           SURVIVED
percentile snaps to a bin edge     SURVIVED
```

Both survivors were behaviours a reviewer had asked for and I had implemented correctly.
Correct code with no test is a fix with a half-life: the next person to touch it has
nothing telling them the behaviour was deliberate. **Fixing a review finding is not
finished until a mutation of the fix fails something.**

**The index went stale within one PR of being added.** `docs/findings.md` gained a Contents
index; the very next branch appended four sections and the index knew about none of them. A
hand-maintained list of the document it sits inside will always drift, so it is now asserted:
the suite fails if a section is missing from the index, or if the index names a section that
does not exist. Mutation-verified both ways.

That is the general shape worth keeping. A documentation convenience that cannot be checked
becomes, with time, a confident statement that is wrong - which is the same failure as an
unverified measurement, wearing different clothes.

## Scanning every frame did not close the hole it was supposed to, 2026-09-08

The guard was changed to scan every frame after a review found that a stride of 20 stepped
over a nine-frame burst. That fixed the sampling gap and left a second one untouched, which
the next review round found: **the clip-wide figure is an average, and averages dilute short
runs to nothing.**

Demonstrated on the real shape of this project's footage - 1480 frames, seven of them fully
blown to white:

```
ungraded  clipped 0.000%
graded    clipped 0.473%      <- under the 0.5 point tolerance, so: verified
```

Seven frames with no picture left in them, passed as acceptable. The earlier regression test
only caught its own case because the fixture was 40 frames long, where nine destroyed frames
are 22.5% of the clip. At real length the same damage is 0.473%.

The fix keeps per-frame rail fractions rather than only the total, and rejects a material
rise on **any single frame** as well as across the clip.

That changes the memory story, so state it precisely rather than repeating the old
headline. **Pixel** memory is still constant - one frame decoded, counted, discarded. The
per-frame statistics are linear: ~113 bytes a frame, measured at 167KB for 1480 frames,
against the 3.07GB that buffering the pixels would cost. The linear part is roughly
18,000x smaller than the part that was removed, which is why it is worth paying; but
"constant memory regardless of clip length" was the claim before rails existed and is no
longer true as written. The threshold came from measurement,
not from choosing a round number:

```
                                  max single-frame rise in clipping
chosen 'bright' preset                          -0.70 points   (improves every frame)
old fixed grade                                +70.42 points
```

A legitimate preset never raises any frame's clipping at all, so two points sits far above
the honest case and far below the destructive one.

**A second finding in the same round: `verify` compared renders without checking they were
comparable.** Each file's decode is cross-checked against its own header, which says nothing
about the pair. A graded encode that is legitimately shorter - an explicit `GRADE` carrying a
`trim` - passes its own check and is then scored frame-for-frame against a longer ungraded
render, with the later `tpad` step turning the missing tail into held frames. Geometry and
length must match before percentages mean anything.

The lesson is not about grading. **A fix aimed at one hole should be checked against the
class of hole, not the instance reported.** "Scan everything" answered the sampling gap and
read like a general answer, which is why the averaging gap survived it - and why the
write-up claimed a completeness the code did not have.

## minterpolate cannot interpolate a fast pan, 2026-09-06

The 60fps deliverable for MVI_0081 looked "glassy" — the picture flowing rather than
moving. Reported by eye, and the two qualifiers in the report were what located it:
*only in the 60fps version*, and *worst in the first five seconds*.

Both followed from one measurement. `minterpolate` searches for each block's motion within
`search_param` pixels, default **32**, and that default had never been sized against
footage that pans:

```
                       block motion p95     frames beyond a 32px search
N90 clip (fine)              39px                     ~5%
MVI_0081 (glassy)           130px                    32.4%   (60% of the first 5s)
                       (both measured on the 1080p deliverables, ~2000px wide)
```

At 15fps the frames are the model's own, so nothing is synthesised and nothing warps —
which is exactly why the artifact exists only at 60.

### Raising the search range does not fix it

```
search  32   276/851 frames beyond range
search 200     6/851
search 250 + trimming the opening second     0/851  -- and still glassy
```

Zero frames beyond range and the artifact remains, which rules the search range out as the
mechanism. Also ruled out: `me=umh` at search 400 (no improvement, added noise around the
subject, ~50 minutes per 5 seconds of output), and `mi_mode=blend`, which is not a softer
60fps but 14fps with extra steps — blending frames 66ms and 100px apart gives a double
image, and the eye reads a double image as one judder rather than two positions.

Two things remain, neither reachable by any parameter:

- **Occlusion.** At speed, 8.35% of the frame width is newly revealed each frame. That
  content has no correspondence in the previous frame, so block compensation stretches
  neighbours into it.
- **Baked-in motion blur.** Gradient energy along the motion direction falls to 0.52 of
  the perpendicular at speed. A 66ms exposure shown at 16ms intervals is a mismatch no
  interpolator removes.

### RIFE fixes the first; nothing fixes the second

RIFE v4.25 synthesises intermediate frames rather than warping blocks, and resolved it.
On the local RTX 5060 Ti: **3405 frames in 2m42s**, no rented GPU.

`scale` inverts — lower estimates flow on a coarser pyramid and handles larger motion. By
eye 0.5 and 1.0 were indistinguishable, so it was settled on step evenness, which is
objective *within one method*: the four steps between each pair of source frames should be
equal.

```
RIFE scale 0.5    within-group CV 0.0913
RIFE scale 1.0    within-group CV 0.0653   <- chosen
```

That statistic cannot compare across methods. `minterpolate` scores *better* than both
(0.0490) and looks worst, because evenly spaced warped frames still score well. It ranks
spacing, not quality.

### Two traps worth recording

**A partial file is not a small file.** `mi_umh.mp4` appeared at 1.0MB against 2.3MB for
the same content, and that was read as fewer artifacts. It was a render still in progress.
The frame count says so immediately and the byte count never does — the same lesson as the
truncated inference output already in CLAUDE.md, arrived at from the other direction.

**Two fixes were tested separately and only worked together.** Trimming the opening was
measured against the 32px threshold, where it moves 32.4% to 31.1% — negligible, and
reported as such. Against the 200px threshold it removes 4 of the 6 remaining bad frames.
Useless alone, near-complete in combination.

## The interpolator threshold was measured in the wrong units, 2026-09-08

Self-review of the RIFE branch, before asking anyone else to look at it. The finding is not
in the mechanism - block compensation really does fail on a fast pan, and RIFE really does
fix it - but in how the decision between them is made.

**The recorded figures could not be reproduced from the files they named.** The docstring
said the N90 clip measures p95 39px and MVI_0081 130px. Measuring those files gives 5.8px
and 20.2px. Both discrepancies are the same ratio, and both imply a source about 2000px
wide: the numbers were taken from the **1080p deliverables**, not from the sources the text
pointed at. Nothing was wrong with the measurements; the text simply did not say what had
been measured, which made them unreproducible and therefore unverifiable.

**Worse, the threshold was in absolute pixels.** Block motion scales with resolution, so
60px means different things on different renders. Same six seconds of footage, varying only
width:

```
width  296  ->   37.6px         width 1024  ->  141.9px
width  440  ->   47.7px         width 1914  ->  229.0px
width  640  ->   84.7px
```

A 6.1x spread in pixels against 1.3x as a fraction of width. With the 60px threshold that
footage was judged **minterpolate at width 440 and rife at width 520** - the same footage,
opposite answers, decided by output size rather than by motion. This pipeline renders at
both 720p and 1080p, so it was reachable rather than theoretical.

`block_motion` now returns a fraction of frame width and the threshold is 3%. At the time
this landed it reproduced the original calibration exactly - N90 1.86%, MVI_0081 6.81% -
while removing the dependence on render size. A test pins the property that matters
(resolution independence): the same clip at 1x and 4x must pick the same interpolator, and
reverting to pixels fails it. The two specific numbers did not stay put - see the entry
below on scanning the whole clip, which moved both of them again, MVI_0081 by far more than
N90. The pinned property held throughout; the two calibration figures quoted here did not,
which is exactly why the test asserts the property and not the numbers.

The general point is one this project keeps meeting from new angles. **A measurement needs
its units and its baseline recorded, or it is an anecdote.** "39px" is not a fact about a
clip; it is a fact about a clip at a resolution, and the resolution was the part left out.

## The interpolator's blind spots were all in what it did not look at, 2026-09-11

A third review round on the RIFE branch. Five findings, and four of them share a shape:
something was checked over a subset, and the subset was not stated.

**Motion was measured over the first 400 frames only** - 27% of the N90 clip, and 47% of
MVI_0081's 852. A clip that is static early and pans later could not influence its own
recommendation, which is exactly the footage the tool exists to catch. Measuring everything
costs 1.1s against 0.5s on 1480 frames, and the answer moved on both calibration clips - N90
1.86% -> 1.94%, a small shift, and MVI_0081 6.81% -> 5.58%, a much larger one, only found
later during a full self-review of the branch because nothing had re-measured the second
clip at the time this landed. Neither shift crosses the 3% threshold, so `pick()`'s
decision on either clip is unchanged; what moved was the documented calibration figures,
which sat wrong in four files (this one included) until that self-review caught it. A
fixture that pans only after frame 400 now pins the first-400-frames blind spot: the whole
clip says rife, the first 400 frames say minterpolate.

**`available()` checked the weights but not the model code.** `interpolate()` does
`from train_log.RIFE_HDv3 import Model`; the guard looked only for `flownet.pkl`. A
half-installed model passed the friendly check and failed with `ModuleNotFoundError` from
inside the import - the failure the guard exists to pre-empt. Worth recording that this was
found one round *after* the same function was changed for a different reason: fixing
`exists()` to `os.access(X_OK)` did not prompt asking whether it was checking the right
files.

**The frame multiplier was hardcoded to 4**, correct only for a 15fps source. At 30fps that
is 120fps, and trimming to the expected 60fps frame count then keeps the first half of the
clip - with every frame-count guard still passing, because the count is right. It is now
derived from `BASE_FPS`, and lives in `rife.py` rather than inline in the shell so it can be
tested without a GPU.

**A test that could stop testing without failing.** The fallback case asserted any
`auto -> ` line, and its fixture measured 3.80% against a 3.0% threshold. It did enter the
fallback - but a 27% margin is close enough to drift across silently, after which the test
would pass while exercising nothing. The fixture is now an unambiguous pan (66.35%) and the
assertion requires both `auto -> rife` and the warning.

The fifth: the setup notes cloned mutable HEAD and asked for "a model's" files, while the
findings name **v4.25** and the code calls `RIFE_HDv3`'s signature. The notes now name the
version and the exact files, and carry a `git checkout` step - but the revision itself is
still a placeholder. Recording a specific pin asserts that *that* commit is the tested
combination, which is a claim about provenance rather than something readable off this
machine. **The setup is named, not yet pinned**, and the placeholder is deliberate so the
gap is visible rather than silent.

**Three of my own fixes in this round initially survived a mutation sweep**, including two
that the review had explicitly asked to be covered by tests. Writing the fix and reading the
request is not the same as doing what it asked.

## Fixing the multiplier did not fix the rate, 2026-09-11

A fourth round on the same branch, and the headline finding is a direct consequence of the
third round's fix.

Deriving the RIFE multiplier from the source rate was right and incomplete. The multiplier
only guarantees **at least** 60fps, and the trim that follows counts frames rather than
converting rate. At 24fps the multiplier is 3, RIFE emits 72fps, and trimming to the 60fps
frame count keeps **5/6 of the clip**:

```
15fps x4 = 60fps -> 600 frames is 10.00s of a 10s clip   100%
24fps x3 = 72fps -> 600 frames is  8.33s of a 10s clip    83%
30fps x2 = 60fps -> 600 frames is 10.00s of a 10s clip   100%
```

The frame-count guard passes throughout, because **the count is right and the duration is
not**. The minterpolate branch never had this because `minterpolate=fps=60` normalises as a
side effect; the RIFE branch had to say it, and did not. `fps=60` now sits before the trim.

That is the same shape as the defect it followed. Round three fixed "the multiplier assumes
15fps"; round four found "the trim assumes 60fps". **Fixing the input to a calculation is
not the same as fixing the calculation**, and the second half was reachable only because
the first half had been fixed - at a hardcoded 4, a 24fps source never got far enough to
hit it.

Two smaller findings of the same family:

- `multiplier()` forced a floor of 2, so a 60fps source bought a 120fps model pass whose
  every other frame the fps filter then discards. `interpolate()`'s loop is
  `range(1, multi)`, so 1 was always valid - the most expensive possible way to change
  nothing.
- `available()` checked for files and called that availability. A venv without torch, or
  with one built for another CUDA line, passed every file check and then failed inside the
  model **after auto-selection had committed to RIFE**. It now runs the import in the venv
  that will do the work. Files present is not the same as importable.

And two stale claims written during the previous round: a comment describing a 400-frame
decode cap that had been removed in the same commit, and a findings line saying the model
revision was "pinned" when the setup notes still carry a placeholder. Both were true when
drafted and false by the time they were committed.

## Even timestamps are not even motion, 2026-09-11

The 60fps normalisation from the previous round fixed the duration and left the cadence
broken, which the next review found.

Interpolating to a whole-number multiple and resampling afterwards is not the same as
interpolating to the target rate. A 24fps source at x3 is 72fps; `fps=60` on that keeps 60
of every 72 frames, and measured over one second the source position advances in steps of:

```
step 0 frames:  4 times      <- a frame repeated outright
step 1 frame : 34 times
step 2 frames: 21 times
```

The container timestamps are perfectly uniform, the frame count is right, the duration is
right - and the picture judders, because **motion advances unevenly while the clock does
not**. Every check in place at the time was a check on the clock.

RIFE takes an arbitrary timestep, so the fix is to synthesise AT the output instants rather
than at source-multiples: walk the 60Hz clock, and for each instant ask the model for the
exact fraction between the two source frames bracketing it. The multiplier concept
disappears entirely, which is a simplification rather than a cost - one fewer number to
derive, and no resampling stage to get wrong.

**What is asserted, and why it is not the rendered frames.** Two fixtures were built and
both were useless: a flat-luma ramp has no motion for the model to estimate, and a
textureless moving bar gives it nothing to track, so the model's output on either says more
about RIFE on synthetic input than about cadence. What this repository actually decides is
the *schedule*, so `output_schedule()` is pure and separable and the test asserts that its
steps are evenly spaced at 15, 24, 25, 30, 14.75 and 60fps. Reverting to multiples-then-
resample fails it.

**A rationale that argued against itself.** The module docstring, `finish.sh`, `CLAUDE.md`
and the test header all said minterpolate fails because motion exceeds its 32px search
window - and then, immediately below, that raising the window to 250 left zero frames
beyond range and the output still glassy. Both statements were true and the first is not
the cause. The cause is occlusion: ~8% of the frame width is newly revealed each frame with
nothing to warp from. Block motion remains the selection criterion because it is a good
*proxy* - both follow from fast panning - and that is now what the text says. The review
named four locations; there were six.

## A full-branch self-review found four stale numbers no round had checked, 2026-09-11

After six Copilot review rounds and a CI pass, PR #8 sat at zero unresolved threads. That
is not the same as every claim in it being true, and it was not: a holistic re-read of the
whole accumulated diff - the first time all eight commits were read together rather than
one round's worth at a time - found the calibration figures for MVI_0081 were wrong in
every file that quoted them.

**Live-measuring the two calibration clips right now gives N90 1.94%, MVI_0081 5.58%.**
Four files said something else: the module docstring and the `MOTION_THRESHOLD` comment in
`pipeline/rife.py`, `CLAUDE.md`, and `README.md` all still quoted N90 1.86% and MVI_0081
6.81% (or 6.82%, the two did not even agree with each other) - the numbers from before the
round-3 fix that made `block_motion` scan the whole clip instead of the first 400 frames.
That round's own findings.md entry documented the N90 side moving (1.86% -> 1.94%) and never
checked whether MVI_0081 moved too. It had, by far more (6.81% -> 5.58%), and nothing
caught it because no later round re-ran the measurement against the current code - each
treated the earlier round's numbers as ground truth and reasoned about the diff rather than
about the clips.

Neither shift crosses `MOTION_THRESHOLD` (3%), so no decision made by the code was ever
wrong - `pick()` chooses correctly on both clips throughout. What was wrong is confined to
prose that nobody re-verified after the code it described had changed underneath it.

**The general lesson: a number that is correct when written and never re-checked becomes,
silently, a number that is merely remembered.** Six review rounds each verified the *diff*
against the *previous* round's claims. None re-derived a claim from the file it was
supposedly describing. The fix here was mechanical once looked for - `grep` for the two old
figures found all four locations in under a second - the missing step was deciding to look,
which took a full read of the branch as one piece rather than as six sequential patches.

## p95 over a whole clip discards its top 5% by definition, 2026-09-11

A percentile is not immune to the blind spot it was built to fix. `block_motion` scanning
the whole clip (see the entry above) closed the first-400-frames blind spot; a clip-wide
`p95` has a structurally identical one at a different scale, and it took a direct Copilot
review to name it.

**p95 discards the top 5% of samples by construction.** If the frames genuinely needing
RIFE - a real, severe pan - make up less than 5% of the clip's total length, the p95
statistic never sees them: they ARE the discarded top 5%. Reproduced: 40 fast-panning
frames in a 990-frame clip (4.0%, the same pan speed a 12.5%-panning fixture correctly
flags) measured **0.00%** and picked `minterpolate` - the exact glassy failure this tool
exists to prevent, for footage that is mostly calm with one bad stretch, which is a
perfectly ordinary way for real handheld footage to behave.

**Fix: a windowed maximum, not a single global percentile.** `block_motion` now takes the
mean motion within short (~1s) windows and reports the MAX across windows, with a half-
window stride so a pan straddling a window boundary still lands fully inside at least one
offset window. A window only has to be internally fast; it no longer needs to be a minimum
share of the whole clip. The 4% fixture above now measures 20.55% and correctly selects
`rife`.

**The threshold moved again, a third time, for the same underlying footage.** Windowing
changes what the statistic reports even on clips with no short/rare pans - it now measures
N90 at 2.96% and MVI_0081 at 11.65%, both up from the un-windowed 1.94%/5.58%, because
"maximum of short-window means" and "p95 across the whole clip" are different quantities
even when computed on the same data. `MOTION_THRESHOLD` moved from 3% to 6% to keep a
comfortable margin from both (roughly 2x above N90, roughly half of MVI_0081) - up from a
2.9x gap between the calibration clips to a 3.9x one, since windowing raises the floor for
footage that is mostly calm with brief fast passages more than it raises footage with
sustained panning throughout.

**Verifying the fix exposed a second, unrelated defect in the resolution-independence
test.** Rerunning it after the windowing change failed: the same footage, compared 1x
against a 4x bicubic upscale of itself, picked different interpolators. Tracing it down
found the OLD un-windowed statistic already disagreed by 6.2x between the two resolutions
(6.39% against 39.39%) - it just happened that both numbers cleared the old 3% threshold,
so the test passed by coincidence of where the threshold sat, not because the measurement
was actually resolution-independent. The cause is specific to the fixture, not to
`block_motion`: bicubic-upscaling a low-resolution synthetic test pattern and re-measuring
optical flow on the blown-up result introduces flow-estimation artifacts of its own, most
visible in the first several frames after the resize. Two INDEPENDENTLY rendered clips at
the two resolutions - the actual relationship between a 720p and a 1080p render of real
footage - measure within 0.6 points of each other (5.06% vs 5.65%) and land on the same
side of the threshold, confirming the property genuinely holds; only the derived-by-
upscaling test fixture did not. The suite now renders both sizes natively.

## An independent high-effort review found ten more, all in code no round had touched, 2026-09-11

A `/code-review --high` pass, separate from the Copilot cycles, ranked ten findings by
severity against the accumulated branch. Six correctness, three maintainability, one test
coverage. All ten were real; one scenario didn't reproduce as described, and the underlying
defect it pointed at was real anyway.

**The `recommend` call eleven lines above a guarded probe was itself unguarded.** Bare
`RECO="$(rife.py recommend ...)"` under `set -e`: if `block_motion` raised on an
unmeasurable render, this killed `finish.sh` immediately - after luma-fix, cadence-restore
and grading had already run - instead of falling back to minterpolate. Mutation-verified
both directions: without the guard, a forced failure aborts the pipeline after grading (2
of 3 deliverables, no 60fps output); with it, the same failure logs a message and produces
all three. Fixing this properly meant fixing the duplicated `&&/||` idiom too (see below),
since patching just this one call site would have been the fourth time it needed writing.

**A relative `RIFE_HOME` broke two different ways, not the one way described.** The review's
scenario was "the probe says available, then `interpolate()` dies" - reproduced instead
that BOTH break, differently: the probe's `subprocess.run(cwd=RIFE_REPO)` resolves a
relative executable path against the CHILD's cwd (documented Python behaviour), so it
looked for the venv python at `RIFE_REPO/RIFE_REPO/venv/bin/python` and failed with "No
such file" - correctly reporting unavailable, just for the wrong-sounding reason.
`interpolate()`'s `sys.path.insert` before `os.chdir` breaks the same way on the import
side. Neither failure is the one the review described, but both are real, and the fix is
the same either way: normalise `RIFE_HOME` to absolute the moment it is read, which removes
the whole class rather than patching each call site's particular symptom.

**The calibration numbers were measured on the source; production measures the render.**
Camera stalls become repeated, zero-motion frames after cadence-restore, and a windowed-max
statistic can move either direction depending on where those repeats land relative to the
fastest window - measured: N90 source 2.96% vs render 3.27% (up), MVI_0081 source 11.65%
vs render 9.95% (down). Neither crosses the 6% threshold either way, so no decision was
ever wrong, but the documented numbers now come from the actual file `recommend` measures.

**The RIFE path paid for an extra lossy generation minterpolate does not.** `interpolate()`
wrote its output at crf 12, and `finish.sh` re-encoded that at crf 12 again for the
tpad/trim pass; minterpolate goes through that second pass only, once. Comparing `auto`
(which picks RIFE on a pan) against forced minterpolate by eye - this project's standard
way of judging anything perceptual - would have compared generation count along with
interpolator, the "more than the variable under test differs" trap by name. `interpolate()`
now writes lossless (crf 0); it is an intermediate immediately re-encoded again, so disk
space is the resource to spend, not quality.

**`rife.py`'s `probe()` never got the `check=True` fix `grade.py`'s `dims()` already
carries**, with a comment explaining why. Found by accident, reproduced while testing an
unrelated change: a bad path raised a raw `CalledProcessError` traceback instead of the
clean `SystemExit` every other guard in this pipeline is tested against. Same fix.

**Three maintainability findings, all real duplication with a named future failure mode
attached, not duplication for its own sake:** the `&&/||` exit-capture idiom at two call
sites (a future third site copying the surrounding pattern and missing that one line has
already happened once); the tpad/trim/encode settings spelled out independently in both
interpolator branches (a `stop=8` or `crf` change landing in one and not its twin); the
`"rife" if m > MOTION_THRESHOLD else "minterpolate"` comparison duplicated between
`measure` and `recommend` (nothing stopping the two commands from silently disagreeing).
Fixing the first turned out not to be reducible to a single shared helper the naive way:
`X="$(fn ...)"` runs `fn` in a subshell, so an out-parameter `fn` sets is invisible to the
caller once that subshell exits - the actual fix shares the invocation and leaves the
`&& OK=0 || OK=$?` capture at each call site, which is a one-line idiom instead of a
multi-line block, not eliminated entirely. Bash's own scoping rules set a floor under how
much of this class of duplication can be removed.

**One test-coverage finding:** five near-identical 4-line inline Python snippets probing
`rife.available()` across ~110 lines, differing only in which fake `RIFE_HOME` was passed.
One shared `rife_available()` helper now takes the directory as its only argument, which is
also the only thing that was actually under test at each site.

108 tests, all fixes mutation-verified.

## CI failed twice on a test that passed locally both times, 2026-09-11

The resolution-independence fixture from an earlier round measured 5.06%/5.65% against
the 6% threshold - under a point of margin on the low side, barely a third of a point on
the high side. It passed on this machine. It failed on GitHub's runner, twice, on two
separate commits: `1x said minterpolate, 4x said rife`.

**Same synthetic clip, same code, different answer, because a different ffmpeg/OpenCV
build measures optical flow on it slightly differently.** Nothing here is non-deterministic
in the sense the project usually means - SeedVR2's determinism claims are about repeat
runs on identical hardware. This is smaller and more mundane: floating-point results from
`calcOpticalFlowFarneback` are not bit-identical across builds, and a fixture measured
within a point of its own threshold has no room to absorb that.

The fixture is not a real render - real footage is never compared 1x against a scaled copy
of itself, and no production decision runs this close to the line by construction. Widened
the margin instead of chasing bit-for-bit reproducibility: the same pan, slowed down, now
measures ~3.1%/3.2%, roughly half the threshold rather than a hair's width from it. Every
other block_motion fixture in the suite was checked against the same standard - all carry
at least 4 points of margin, most far more (the tightest of the rest is 4.09 points; most
exceed 10).

**The general rule, which the project's own standard already implies but had not been
applied to a threshold-adjacent test until this:** a test asserting which side of a
threshold a continuous measurement lands on needs margin proportional to the measurement's
own noise floor, not just enough margin to pass once, in one place, on one machine. CI
finding this is exactly what CI is for.

## `git checkout` on a file with real uncommitted work silently discarded it, 2026-09-11

The RECO guard, the shared `rife_try()` helper, and the stderr redirect on unknown
`INTERP` were all fixed once already, reported as done, and then quietly reverted before
they were ever committed - by me, running `git checkout -q pipeline/finish.sh` to restore
the file after a manual mutation test, not realising the file still held real, uncommitted
fixes at that moment. `git checkout` restores from the last commit, not from "a moment
ago" - it does not know or care that a mutation test was the only thing that should have
been undone.

The next Copilot review round found both losses independently, as if they were new: the
unguarded `RECO=` assignment (identical to a defect already fixed and written up two
commits earlier) and the missing `>&2` (same). Re-fixed, and this time verified by copying
the file to a scratch path before mutating it, never touching git state for a throwaway
test.

**The regression test for the RECO guard could not be built the way earlier guard tests in
this suite are: by handing `rife.py` a file it cannot measure.** `block_motion` already
refuses a too-short render cleanly (its own guard, tested elsewhere), and the pipeline's
own stages fail loudly on a genuinely pathological source before ever reaching
auto-select. Testing "does finish.sh survive `recommend` failing" therefore needed
`recommend` to fail on a valid render, which nothing in this codebase does. The test
copies `pipeline/` to a scratch directory, patches that copy's `rife.py` to force
`recommend` to fail, and runs the real `finish.sh` against a real, valid clip end to end -
mutation-verified against the exact defect that motivated it: reverting the guard fails
this test and none of the others.

**A second, smaller mistake surfaced building that test.** The first attempt copied the
pipeline files flat into the scratch directory. `finish.sh` derives its own `REPO` as
`"$HERE/.."` and then imports `timing.py` from `"$REPO/pipeline"` - a flat copy breaks
that assumption and the test failed before ever reaching the code under test, with an
unrelated `ModuleNotFoundError`. Mirroring the real `pipeline/` subdirectory fixed it.
Diagnosed by running the exact scenario by hand outside the suite rather than guessing
from the truncated failure message the harness prints.

## A second review round found six more, mostly the source-vs-render mixup repeating, 2026-09-11

**An explicitly empty `RIFE_HOME` resolved two different ways.** `os.environ.get("RIFE_HOME",
default)` only substitutes the default when the key is *absent* - `RIFE_HOME=""` resolved to
`abspath("")`, the interpreter's own cwd, while `finish.sh` reads the same variable as
`${RIFE_HOME:-default}`, which treats an empty value as unset. The probe and `interpolate()`
would then run against two different installations for the same environment variable.
Reproduced directly before fixing: `RIFE_HOME="" python -c "...os.environ.get(...)"` printed
the test's own cwd, not the default path. Fixed with `or` instead of the dict-get default,
which falls back on any falsy value the way bash's `:-` does.

**The calibration numbers drifted back to the raw source in three places that were not
touched when the render-vs-source finding above landed.** `CLAUDE.md`, `README.md`, and
`pipeline/rife.py`'s own `MOTION_THRESHOLD` comment all still read 2.96%/11.65% - the source
figures - while the module docstring twelve lines above that same comment already carried
the corrected 3.27%/9.95% render figures. The fix landing in one place and not its three
siblings is the exact "standard applied once is not applied" pattern from `CLAUDE.md`.
Re-measured directly against the actual calibration renders rather than trusting either set
of numbers: `work/final/Final_lumafix_14fps.mp4` gives 3.271% (matches the docstring) and
`out/MVI0081_720_lumafix_14fps.mp4` gives 9.953% (matches). The frame count quoted alongside
it was also wrong in a related way - "1480-frame clip" is the SOURCE's frame count (and
matches every other reference to 1480 in this repo, all of which are genuinely
source-based), not the render's; cadence-restore duplicates held frames, and the actual
calibration render measures 1556. Recomputed the un-windowed-vs-windowed gap on the same
basis for consistency (2.5x vs 3.0x on the renders, not the stale 2.9x vs 3.9x the old
comment carried from source-based numbers) rather than leaving one half of the sentence
correct and the other stale.

**`INTERP` was validated, and a forced-but-unavailable RIFE was refused, only after
luma-fix, cadence-restore and grading had already run and both 14fps deliverables had
already been moved into `OUT_DIR`.** A typo'd `INTERP=bogus` paid for the whole expensive
part of the run before saying so; re-running an existing `TAG` with a bad `RIFE_HOME` left
a stale 60fps deliverable sitting next to freshly-replaced 14fps ones, an output set that
looked current but wasn't. Moved both checks to immediately after venv activation, before
any stage runs - the case-statement validation is free, and the forced-rife availability
probe (`rife.py why`) never depended on the render anyway, only on the venv/model files on
disk. This left the later re-probe-and-refuse block genuinely unreachable (by construction,
not by accident: every path that can still set `INTERP=rife` downstream already guarantees
`RIFE_OK=0` before it does), so it was simplified to a comment stating the invariant instead
of kept as dead error-handling. Mutation-tested the property that actually matters - not
just that the refusal still happens, but that it happens before any output is written: with
the checks moved back to their original spot, a fixture asserting `I_lumafix_14fps.mp4`
does not exist after the refusal fails; with the checks at the top, it passes.

**`rife.py`'s CLI silently accepted extra arguments everywhere except nowhere.**
`cloud/run_on_pod.sh` has always rejected them (`[ "$#" -le 2 ] || { ... exit 1; }`), but
`rife.py`'s `main()` only checked a *minimum* argument count per command, so `recommend
video --explan` (a typo) ran to completion with no explanation and no complaint, and an
extra trailing argument to `interpolate` would still have launched the model. Added a
per-command maximum arity check and made a malformed option after `recommend`'s video
argument an error rather than silent no-op. Mutation-tested: reverting either check makes
the new "extra argument" and "mistyped --explain" tests fail.

**`interpolate()` opened the caller's final output path directly, before the frame-count
check that exists to catch a truncated result.** A model exception, decoder failure, or
short count could leave a plausible partial file sitting at the exact path a caller is
about to treat as a finished deliverable - checked whether this actually threatens the
pipeline before fixing it as reported: `finish.sh` only ever calls `interpolate()` with a
work-directory scratch path (`$W/i60_raw.mp4`), not a published one, so the severity Copilot
described does not reach the real pipeline today. Fixed anyway, since a direct CLI caller is
still exposed and the fix is cheap: write to `dst + ".partial"`, verify the count, then
`os.replace()` into the real `dst` only on success. Not covered by an automated test - like
the rest of `interpolate()`'s internals, exercising it needs a CUDA torch and model weights
this repo does not vendor, which is the same documented scope boundary the rest of the test
suite already respects.

**Declined: smoke-loading the actual model weights in the availability probe.** The probe
confirms a CUDA kernel launches but never loads `flownet.pkl` or imports the real model
class with it, so a zero-byte or incompatible weight file would still report "available"
and only fail once `interpolate()` is already running. A real fix needs the actual
`Model()`/`load_model()` call this environment cannot exercise (no GPU, no vendored
weights - the same boundary the project has stated throughout for this file). Left as a
named gap rather than guessed at.

## The atomicity fix itself broke the RIFE path, and "lossless" wasn't, 2026-09-12

**The previous round's own atomicity fix (`dst + ".partial"`) would have broken every real
RIFE run.** Appending the marker after the extension turns `i60_raw.mp4` into
`i60_raw.mp4.partial` - not a recognised container extension, and ffmpeg infers its output
muxer from one when `-f` isn't given for the destination. Reproduced directly: `ffmpeg ...
out.mp4.partial` refuses with "Unable to find a suitable output format" before writing a
frame. The temp file was never wrong in principle - splitting the extension and inserting
the marker before it (`i60_raw.partial.mp4`) keeps a real extension and was confirmed
to encode correctly. A fix for one defect (a partial file at the published path) shipped a
worse one (the RIFE path cannot run at all) in the same commit, caught by the next review
round rather than by anything in this project's own process - there is no automated test
over `interpolate()`'s internals for the reason repeated throughout this file, so this class
of mistake is exactly what that gap allows through.

**"Lossless (crf 0)" was lossless only relative to a pixel format that already discarded
information.** `-c:v libx264 -crf 0 -pix_fmt yuv420p` makes the H.264 encode step
mathematically lossless, but `yuv420p` subsamples chroma to a quarter of luma's spatial
resolution before that encode ever sees the frame - a real, permanent loss the crf setting
cannot see or undo. Measured directly rather than trusting the claim already in the code:
round-tripped one frame through `libx264/yuv420p/crf0` (max channel difference from the RGB
source: 37 of 255, mean 2.5) against `libx264rgb/crf0` fed the same `rgb24` the model
already produces (max difference: 0, bit-exact). Switched to `libx264rgb`, which needed no
other change - the pipe already carries `rgb24` frames, `yuv420p` was an unnecessary
conversion on the way in as well as a lossy one.

**A third finding in the same round - a stride-grid gap in the windowed-max statistic -
was reproducible and fixed with a test.** `block_motion`'s window starts are
`range(0, len(arr) - win + 1, stride)`; when `len(arr) - win` isn't itself a multiple of
`stride`, the grid's last start falls short of it, and the true final window - covering the
clip's last `win` samples - is never tried on its own. A severe pan confined to exactly that
tail is only ever seen diluted alongside earlier, calmer frames in whichever window the
grid does reach. Reproduced with a fixture built to land in the gap deliberately (70 calm
frames + a 15-frame pan at the very end): 4.70% with only the grid's windows (picks
`minterpolate`), 8.30% once the true final window is included (picks `rife`). Fixed by
appending that window's start whenever the grid doesn't already include it. Unlike the two
findings above, this one lives in `block_motion`, which the suite can and does exercise
directly - mutation-tested the usual way: reverting the fix fails the new regression test
and none of the others.

## round() can stop the output schedule short of the last frame, 2026-09-12

**`output_schedule`'s frame count used `round()`, which can land BELOW the true final
source instant rather than at or past it.** `output_schedule(46, 24, 60)` computes
`round(112.5)` - Python rounds half to even, so this is 112, not 113 - giving a schedule
whose last position is 44.8 against a true endpoint of 45. The clip's actual last frame is
then never scheduled on its own, only ever as 80% of a blend with the second-to-last one;
`finish.sh`'s tail-pad clones that blended frame to reach the target duration instead of the
real final frame. Reproduced directly before fixing, and worth being precise about why the
existing schedule test never caught it: it asserted even STEP SIZE only, never that the
schedule actually REACHES the last frame - a schedule can be perfectly evenly spaced and
still stop short. That gap was real regardless of which frame count the test happened to
use. It was not, however, purely theoretical: the same test's existing 48-frame fixture
was **already** short at 14.75fps (46.9542 against a true 47) before this fix, on the exact
input the suite was already running - just never checked for, because nothing asserted the
endpoint.

**Fixed with a ceiling, not a bigger round.** `int(math.ceil(span * target_fps - 1e-9)) + 1`
reaches or passes the true endpoint in every case checked (46 and 48 source frames, at
15/24/25/30/14.75/60fps), and the small tolerance keeps the exact-multiple cases from
gaining a spurious extra frame to floating-point noise - verified this holds for all of
them, not assumed. The existing schedule test now checks 46 as well as 48 source frames,
and asserts the schedule's last position actually reaches `n_src - 1`, not only that its
steps are even. Mutation-tested: reverting to `round()` fails on exactly the cases
identified above (46@24fps, 46@14.75fps, and the previously-unchecked 48@14.75fps) and
passes the rest.

**"Endpoint" here means the last frame's START position (`n_src - 1`), not the clip's
full playback duration (`n_src` frames later) - the next entry below finds that this fix,
correct as far as it goes, was still short of the latter by one whole frame-duration, and
supersedes this one's target rather than contradicting it.**

**The same review pointed out two real test-coverage gaps, both now closed.** The CUDA
availability probe's two asserts (`torch.cuda.is_available()`, then an actual kernel
launch) were not pinned by anything in the suite - every existing fixture's fake
`venv/bin/python` is a shell script that exits 0 or 1 unconditionally, ignoring whatever
probe source it is handed, so deleting either assert would still leave every prior test
green. Verified this directly: with both asserts stripped from the probe, the full suite
still passed before adding coverage for them. Two new fixtures use a REAL python
interpreter with a fake `torch` and `train_log.RIFE_HDv3` on `PYTHONPATH` so the probe's
own source actually executes - one where `cuda.is_available()` returns `False`, one where
it returns `True` but the kernel launch itself raises (the shape of the Blackwell-no-kernels
case `CLAUDE.md` records). Separately, the CLI arity test's own comment named `interpolate`
as the case that used to reach the model on a stray extra argument, but no test exercised
`interpolate` itself - added one; the arity guard runs before any model import, so it needs
no real input file and stays CUDA-independent.

## The schedule's own target was one frame-duration short of the clip's real length, 2026-09-12

**The previous round's fix made `output_schedule` reach the last frame's START position;
it never made it reach the clip's actual END.** `n_src` frames at `src_fps` each occupy
`1/src_fps` seconds, so the clip's true playback duration is `n_src/src_fps` seconds - the
position of the last frame's start, `(n_src-1)/src_fps`, is one whole frame-duration short
of that. Scheduling only to the last frame's start therefore under-counts by design, not
by a rounding accident this time. Reproduced directly: 15 real frames of 15fps source (one
full second of footage) used to schedule only 57 output frames at 60fps - 0.95s, not the
full 1.0s - a genuine, visibly clipped 50ms off the end.

**This does not break `finish.sh`, which has never relied on `output_schedule` reaching the
full duration on its own.** Its `tpad=stop=8:stop_mode=clone,...,trim=end_frame=$EXPECT60`
step pads to `EXPECT60`, computed independently from the real source's own timestamps
(`timing.py`'s `span.txt`, which is `sum(durs) + term` - already the full-duration figure,
not a last-frame-start one). Checked this directly rather than assuming it: `EXPECT60` and
`output_schedule`'s new target now measure the *same* quantity from two different sources
(a real-timestamp sum vs. a frame count and nominal rate), so they should already agree to
within a frame or two - and the 8-frame `tpad` buffer covers exactly that residual, the same
as it did before this fix, just with less of the buffer needed since RIFE's own genuine
synthesis now covers more of the tail. The defect was real, but only for the documented,
standalone `rife.py interpolate <in> <out>` CLI, which has no padding step of its own and
simply publishes whatever `interpolate()` writes.

**Fixed by redefining the schedule's own target to the clip's full duration** (`n_src /
src_fps` seconds, not `(n_src - 1) / src_fps`), keeping the ceiling-based rounding from the
previous round for the same reason it was added there. Verified against every previously
tested combination (46 and 48 source frames, six rates) that the new target is met, not
merely hoped for. The schedule test's endpoint assertion was rewritten to match: it now
checks that `len(schedule) / target_fps` covers `n_src / src_fps`, not that the schedule's
last position reaches `n_src - 1` - the old assertion is automatically satisfied by the new
one, since covering the full duration implies covering the last frame's start, but not the
reverse. Mutation-tested: reverting to the previous round's `(n_src - 1)`-based target fails
this test and none of the others.

**Declined: detecting and rejecting genuinely variable-rate input.** The review that found
this also noted `output_schedule` assumes uniform frame spacing from `probe()`'s nominal
frame rate alone, which would silently flatten real VFR input the way CLAUDE.md's timing
rule warns against - but only for a hypothetical direct CLI caller. `finish.sh` never
exposes this: it always feeds `interpolate()` the `_lumafix_14fps.mp4` render, which
cadence-restore has already converted to genuine CFR (with stalls represented as held,
repeated frames) before this code ever sees it. Building a VFR detector was not attempted:
verifying one needs known-good VFR fixtures to calibrate a rejection tolerance against, and
this repository has exactly one real VFR file with no independently-known-correct answer to
check a detector against - a wrong tolerance risks the opposite failure, `finish.sh`'s own
legitimate CFR intermediate being refused. Documented the constraint in `rife.py`'s own
usage text instead of guessing at an unverifiable guard.

## A downsampling request would close the decoder's pipe before it finished writing, 2026-09-12

**`output_schedule` never rejected a target rate below the source rate, and `interpolate()`
silently mishandled it.** A lower target means the schedule does not need every source
frame - some source indices are skipped entirely - so the frames it skips are never read
from the decoder's stdout. `interpolate()` closes that pipe once the schedule is exhausted,
regardless of whether the decoder has finished writing. Reproduced directly, outside the
model (this is pipe mechanics, not anything CUDA-dependent): a real ffmpeg decoder given ten
frames, with only eight of them read before its stdout is closed, exits with a non-zero
"Broken pipe" code. `interpolate()` reports exactly that exit code as `"reading {src}
failed ... unreadable input, or no decoder for it"` - a confusing, wrong diagnosis for a
decode that was actually fine; the real cause was never reading the rest of it.

**Fixed by refusing downsampling outright, not by draining the decoder to support it.**
This tool exists to synthesise frames going *up* to a higher rate - `finish.sh` only ever
asks for 60fps from sources at or below it, and no supported source rate exceeds 60. Draining
the unread frames would make downsampling *work*, but that is a feature this tool was never
designed around and the pipeline never needs; refusing it outright is the smaller, more
honest change, and matches one of the two fixes the review itself offered. The equal-rate
case (`target_fps == src_fps`) is deliberately still accepted - it is a no-op, not a
reduction, and the schedule already reads every source frame in that case by construction.
Mutation-tested: removing the guard fails the new downsampling-is-refused test and none of
the others, including the equal-rate one.

**A `finish.sh` comment fell out of date in the same review, from an earlier round's own
fix.** It said RIFE's schedule "stops at the last source instant," true before the previous
entry's full-duration fix and false after it - the schedule now holds the last frame through
its own remaining duration instead of stopping at its start. Corrected to describe what the
tail-pad step is actually compensating for now: a small residual difference between two
independently-computed duration estimates (a frame count and nominal rate, vs. the source's
real per-frame timestamps), not a structural shortfall in RIFE's own schedule.

## The standalone interpolation CLI silently dropped every audio track, 2026-09-12

**`interpolate()` only ever built a raw-video encoder, so its output never carried audio -
for anyone using the documented standalone `rife.py interpolate <in> <out>` CLI directly,
not just `finish.sh`.** Confirmed by reading the encode command itself: the pipe feeding
the encoder is raw video frames only, with no second input and no `-c:a` anywhere in it.
`finish.sh` never notices, because it remuxes the ORIGINAL source's audio into its own final
deliverable regardless of what `interpolate()` writes - but a direct caller publishing
`interpolate()`'s own output got a silent picture with no warning. Also worth correcting in
the same pass: an earlier entry in this file described the schedule-duration shortfall as
"audible" - a poor word choice given the output has no audio track to be audible in at all.
Fixed to "visibly clipped" instead, here and in the code comment that originated it.

**Fixed by muxing the source's audio in afterward, not by declining as a documented
limitation.** Unlike the VFR and downsampling findings in the entries above, this one had a
clean, verifiable fix within reach: stream-copy the audio (untouched by anything this
function does, so a copy is exact and free) from `src` into the already-finished video,
only when `src` actually has an audio stream to begin with. Verified the exact ffmpeg
invocation directly against real fixtures - one with audio, one without - before wiring it
in: muxing a video-only file with a source that has audio produces a file with both streams
and the correct frame count; `ffprobe`'s own audio-stream check correctly reports none for a
source that has none. The mux keeps the same atomicity guarantee the video write already
has - written to a second temp file, not the final `dst`, and not into `dst_tmp` itself
(ffmpeg cannot read and write the same path in one invocation) - so a failed mux cannot
leave a half-written file at the path a caller is about to publish.

**Not covered by an automated test, for the same reason as the last several fixes inside
`interpolate()`: reaching this code at all needs a real model run, which needs a CUDA torch
and vendored weights this environment does not have.** Verified what could be verified
without one: the exact ffmpeg mux and audio-detection commands, run directly against real
fixture files built for this purpose, confirmed to produce the expected result in both the
with-audio and without-audio cases.

## A packet count is not a frame count, and a container can refuse a codec outright, 2026-09-12

**`probe()` counted DEMUXED PACKETS (`nb_read_packets`), but `output_schedule` needs a
DECODED FRAME count, and ffmpeg does not promise the two are equal.** A container or codec
that packs more than one frame into a packet, or splits one across several, would build a
schedule against a number `interpolate()`'s own decoder disagrees with - it might then hold
early or try to read past what the decoder actually produces, echoing the broken-pipe
finding two entries above but for a completely different, harder-to-guess reason. Tried
hard to reproduce actual divergence before deciding how far to take the fix: libx264,
libx265, mjpeg, mpeg4, and a raw Annex-B elementary stream all measured identically by
either method in this environment. Fixed anyway, since the tools this pipeline's own
encodes use matching by coincidence is not the same claim as the two counts being
guaranteed equal, which they are not: switched to `-count_frames`/`nb_read_frames`, which
ffprobe documents as the frame-accurate count, confirmed identical output shape and guard
behaviour on every existing fixture. Not mutation-tested, for once by necessity rather than
by the usual CUDA boundary - without a fixture where the two counts actually differ, no
version of this code can be made to fail the way the fix is meant to prevent.

**Stream-copying the source's audio into the output container can fail outright, and it
used to do so only after the whole (expensive, in the real model-backed path) interpolation
had already succeeded.** Reproduced directly: `pcm_u8` and `wmav2` audio both refuse to mux
into an MP4 container via stream copy - "codec not currently supported in container" - while
AAC, and even less-common-but-still-standard codecs like Opus, muxed in without complaint on
the ffmpeg build this environment has. Losing an otherwise-complete render to a container
mismatch discovered only at the very last step is a worse failure than a lossy but
universally-accepted re-encode, so the fix retries with AAC before giving up rather than
failing on the first attempt.

**Pulled the whole audio-publishing step out of `interpolate()` into its own function,
`publish_with_audio()`, specifically to make it testable.** Everything else this round
touched inside `interpolate()` could only be verified by direct ffmpeg reproduction outside
the function, because reaching the function at all needs a CUDA torch and vendored model
weights this environment doesn't have. This step never touches the model - it only needs
`ffprobe`/`ffmpeg` and two file paths - so extracting it means the fallback behaviour can be
exercised for real, not just reasoned about. Three fixtures: a source with no audio (video
passes through untouched), a source with AAC audio (stream-copied, codec unchanged), and a
source with `pcm_u8` audio (falls back to AAC). Mutation-tested: removing the AAC retry
fails exactly the third case and none of the others.

## My own audio fix cost the pipeline a redundant remux, and could delete a finished render, 2026-09-12

**The previous round's audio fix made `interpolate()` always call `publish_with_audio()`,
without noticing that `finish.sh`'s own call site immediately discards whatever audio it
attaches.** `finish.sh` feeds the graded 14fps render (which already has AAC audio) into
`interpolate()`, then re-encodes the result with `-an` a few lines later. Every real RIFE
run in the pipeline was therefore stream-copying its entire large, lossless RGB intermediate
into a second temp file solely to attach a track nobody downstream reads - doubling peak
disk use and I/O for nothing. Fixed by adding a `with_audio` parameter to `interpolate()`
(default `True`, matching the documented standalone CLI's behaviour) and a `--no-audio` CLI
flag, which `finish.sh` now passes explicitly, with a comment stating why.

**The same review caught a second bug in the same function, more serious than the first:
`publish_with_audio()` deleted the completed video BEFORE checking whether the mux it was
about to replace it with had actually succeeded.** If both the stream-copy and the AAC
retry fail - a full disk, a muxer that refuses AAC too - the function deleted the only
existing copy of an otherwise-complete interpolation and then raised, discarding real
(in the model-backed path, expensive) work for a failure the caller might otherwise have
been able to recover from. Fixed by moving the deletion to after the success check, and
naming the preserved path in the error message so a caller knows where to find it.
Mutation-tested with a fixture that forces both mux attempts to fail (`dst` pointed at a
nonexistent directory): reverting the fix fails this test, and only this test.

Both findings live in `publish_with_audio()`, which the previous round had already pulled
out of `interpolate()` specifically because it needs no CUDA torch or model to reach -
that decision is what let both of these be caught with real fixtures instead of only
reasoned about, the same as the round that introduced the function.

## The stride grid's blind spot was never only at the tail, 2026-09-12

**Fixing the stride grid's gap at the clip's tail two rounds ago fixed one instance of a
general defect, not the defect itself.** `block_motion`'s windowed statistic sampled window
starts at a stride (half the window width) rather than every possible position. At
`win=15, stride=7`, a pan landing 3 or 4 samples past a multiple of 7 is only ever seen by
the two windows straddling it, both diluting it with samples outside the pan - proven
directly on a synthetic array (not merely argued): a window checking every start finds the
`10.0` a hand-built "hot" region actually contains, while the stride grid's best answer on
the exact same array is `8.0`, provably diluted. The earlier fix only ever tried the clip's
very last possible window in addition to the strided ones, which happens to catch the case
where the grid runs out of clip before it runs out of stride - but the identical dilution
can occur at any interior offset the grid skips, and fixing only the tail while leaving
every interior position exposed was the "standard applied once" pattern `CLAUDE.md` warns
against by name.

**Fixed by replacing the stride grid with a true sliding-window maximum, computed via a
cumulative sum in the same O(n) the strided version cost.** `windowed_max_mean(arr, win)`
checks literally every possible start, so there is no grid left to fall between - and the
tail-specific special case from two rounds ago is now redundant (a full scan already
includes the last possible window) and was removed rather than kept alongside the general
fix. Pulled out as its own pure function specifically so it could be tested without a
video or optical flow at all, the same reasoning `output_schedule()` already demonstrated
for the schedule itself - proving the fix meant building one synthetic array with the
"hot" region at the worst possible offset, not searching for a real clip and pan speed
where the effect happens to survive real-world optical-flow noise at the needed precision
(tried first; the margin an interior position allows is much narrower than the tail's, and
real footage kept the noise from a clean transition dominating the signal at that scale).
Mutation-tested: reverting to the stride grid fails this test and none of the others.

**Recalibrated MOTION_THRESHOLD's own documentation against the new statistic, since
switching to a true maximum can only ever raise (never lower) a clip's measured value.**
Re-measured both calibration renders: N90 moved from 3.27% to 3.36% (the interior-position
fix found a slightly worse window than the strided grid previously had), MVI_0081 stayed
at 9.95% (its worst window was apparently already on the old grid). `MOTION_THRESHOLD`
itself did not need to move - 6% still sits comfortably between both figures - but the
comment, module docstring, `CLAUDE.md`, and `README.md` all still cited the old 3.27%,
and were updated to the re-measured 3.36% rather than left to drift, the way earlier
rounds' calibration numbers were found to have done.
