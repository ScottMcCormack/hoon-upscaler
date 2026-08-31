# Context for Claude

Restoration pipeline for degraded handheld video. Built for a 2007 Nokia N90 clip
(352×288, 15fps VFR, mpeg4 509kbps) of a burnout at a Perth speedway, but the recipe
generalises to other low-resolution phone/camcorder footage.

## Repository conventions

**`main` is protected and only ever receives commits through a pull request.** Never
`git push origin main`. Branch from `main`, push the branch, open a PR.

**PRs are always squash-merged** — one PR becomes one commit on `main`, prefilled from the
PR title and description. The PR description is therefore the permanent record; branch
commit messages are working notes that do not survive the merge. Keep the PR description
current as the branch changes, and write it for `git log`, not for the reviewer.

**Never commit credentials, media, or model weights.** `.gitignore` covers the known
cases; if something new appears, extend it rather than committing the file. A committed
API key is compromised even if the commit is later removed — say so and rotate it.

See `CONTRIBUTING.md` for the full terms, including the standard for adding to
`docs/findings.md`.

## Working style that proved correct

**On perceptual artifacts, trust Scott's eye over invented metrics.** Six metrics were
built during development to score speckling and flicker; all six failed or actively
misled. One correlated with sharpness at r = 0.88 — because speckle *is* high-frequency
content, so any measure that finds one finds the other.

Meanwhile four plain observations each located a root cause immediately: *"the speckling
is on the fence"*, *"only in the 60fps versions"*, *"just before a pause"*, *"not in the
ungraded one"*. Treat observations like these as strong hypotheses and test them
directly.

Build metrics only for things with objective definitions — frame counts, timing gaps,
boundary alignment, file integrity. Those were reliable throughout. For "does this look
right", produce a visual comparison and ask.

## Ordering rules — most bugs were a sensible step in the wrong place

- **Never denoise before the restoration model.** `hqdn3d` helped Real-ESRGAN and badly
  hurt SeedVR2, which is trained on degraded input and wants artifacts left in.
- **Never flatten variable frame timing.** Extracting frames at constant rate discards
  the camera's real per-frame durations. A 267ms stall then plays in 70ms and the subject
  appears to leap. Restore true durations via ffmpeg's concat demuxer.
- **Stabilise before upscaling.** Shake moves content *inside* the model's temporal batch,
  which it reconciles by inventing doubled detail (ghost text).
- **Interpolate from the same grade the held frames come from.** Mixing graded and
  ungraded sources in the selective pass put a 10.5-mean/16.9-max luma step at every hold
  boundary, against 0.25 between ordinary frames.
- **Crop problem content out rather than filtering around it.** Fine chain-link mesh at
  the source's resolution limit made the model speckle; ~20 filters failed, cropping it
  out of frame solved it and removed the need for any pre-filter at all.
- **Disable rotation in stabilisation** (`maxangle=0`). Handheld shake is nearly all
  translation; rotation fitting chases noise and produces a swimming picture.
- **No `unsharp` in the grade.** It rings on high-contrast lettering.

## Hardware notes

- **RTX 5060 Ti is Blackwell, sm_120.** Stock PyTorch builds (cu124/126/128) have no
  kernels for it — install with `--index-url .../whl/cu130`. Cloud Ampere/Ada cards (A40,
  A100, L40S) take stock builds; another Blackwell (RTX 5090) repeats the trap.
- **16GB VRAM is a cliff, not a curve.** Below it ~1.3s/frame, above ~25s/frame — 19×
  from a 25% resolution increase. An A40 48GB at $0.44/hr removes it for about $1 a job.
- **15GB system RAM.** Long clips held entirely in memory trigger the OOM killer. Use
  chunked/streaming modes; check `dmesg | grep -i oom-kill` when a process dies silently.
- **Venvs cannot be created on `/mnt/z`** (Windows mount) — installs fail on file copies.
- **`nohup`/`setsid` do not survive Claude Code turn boundaries. Use tmux.**

## Model findings

- **3B beats 7B**, tested fairly at fp16 with nothing offloaded: 36% sharper, 2.3× faster.
- **fp16 ≈ fp8** in output; fp8 is 4× faster on constrained hardware.
- **SwiftVR** was sharper on background but distorted the subject, and pages from disk on
  a 16GB card.
- **Temporal batch width plateaus.** 5→17 was transformative; 65→217 indistinguishable.
- **Upscale ratio matters more than model size** — but high ratios failed locally partly
  from VRAM starvation. On adequate hardware 6.1× held up fine. Distinguish "the model
  can't" from "this GPU can't".
- **Generated text is confident and wrong.** A phone number rendered cleanly as
  `09 9270 5500`; the source reads `08 9370 5600`. Lower ratios render honest garble
  instead, which is preferable for a personal record.
- **Always frame-count-check inference output** — a crashed run silently produced a
  plausible truncated file that only its duration gave away.
