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
than a buffered array: constant memory regardless of clip length. Buffering every frame of
a 1480-frame 1080p render would be ~3GB on a machine whose notes already record the OOM
killer taking processes out. uint8 has 256 possible values, so mean and percentiles from
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
rise on **any single frame** as well as across the clip. The threshold came from measurement,
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
