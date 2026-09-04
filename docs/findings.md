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
