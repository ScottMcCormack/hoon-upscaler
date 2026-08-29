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
