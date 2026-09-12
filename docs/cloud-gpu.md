# Renting a GPU

The upscale is the only step that needs real hardware. Everything else runs on a laptop.

The headline: **the whole clip cost $0.34**, including pod setup and the first-run model
download. Renting is cheaper than most people expect, and on 16GB it is the difference
between a render and no render at all.

## Which card

**Pick Ampere or Ada — an A40, A100 or L40S. Not Blackwell.** Blackwell cards need torch
from the cu130 index, and a cloud image that ships stock torch will not have `sm_120`
kernels. It is an avoidable hour.

**16GB is not enough, and it fails in two different ways depending on the card.** This
distinction is worth more than it sounds:

- A local RTX 5060 Ti *completes* above ~1021×576, but throughput collapses roughly 19×
  (about 1.3s/frame to about 25s/frame) as model blocks swap out to system RAM.
- A cloud RTX A4000, same 16GB, *does not degrade — it dies.* At 720 it raises
  `torch.OutOfMemoryError` inside the VAE and produces nothing. At 540 it is fine, at
  1.01 fps.

The OOM is in the VAE, not the DiT, so `--blocks_to_swap` and the CPU offload flags cannot
rescue it. **Do not plan around the graceful case.** If you rent 16GB, expect the crash.

An **A40 48GB** removes both problems and makes 1080p practical — the 5060 Ti *can* clear
that cliff too, just at roughly 19× the time per frame. Renting buys speed, not the only
way to get there.

## What was measured

All three VRAM branches, on hardware, 2026-09-04:

| card | reported | branch | resolution | result |
|---|---|---|---|---|
| A40 | 46368 MB | fp16, batch 33 | 720 | 214 frames, 5m24s, **0.68 fps** |
| A40 | 46368 MB | fp16, batch 33 | 720, full clip | 1480 frames, 25m11s, **0.98 fps** |
| RTX 4090 | 24564 MB | fp16, batch 17 | 720 | 214 frames, 5m23s, **0.68 fps** |
| RTX A4000 | 16376 MB | fp8 + offload | 720 | **OOM in the VAE** |
| RTX A4000 | 16376 MB | fp8 + offload | 540 | 60 frames, **1.01 fps** |

**A 24GB card matched a 48GB card for speed** — 5m23s against 5m24s. Batch width buys
temporal coherence, not throughput, so at this clip size the extra VRAM is a quality
decision rather than a speed one. Worth knowing before paying for a bigger card on speed
grounds.

## Running it

`cloud/launch_pod.sh` is the entry point. It rents the pod, uploads the input and
`cloud/run_on_pod.sh`, runs it remotely, downloads and verifies the result, and terminates
the pod whether the render succeeded or the script crashed first — you never run
`run_on_pod.sh` by hand or SSH in yourself.

It needs two inputs beside it, neither of which is in the repo since both are media.
Build them from your stabilised source (see [pipeline.md](pipeline.md)):

```bash
ffmpeg -i stabilised.mp4 -vf "crop=312:176:0:0" -crf 0 input/full_169.mp4
ffmpeg -i input/full_169.mp4 -frames:v 214 -c copy     cloud/test_15s.mp4
```

Then:

```bash
bash cloud/launch_pod.sh 720 test      # 15 seconds — DO THIS FIRST
bash cloud/launch_pod.sh 1080 full     # the whole clip, once the test looks right
```

**Run the 15-second one first, every time.** It costs about $0.15 and finds a broken setup
in five minutes instead of forty. The full clip at 720 was $0.34 at $0.49/hr.

Before you rent anything at all:

```bash
bash tests/launch_pod.sh    # the launcher: pod creation, SSH, download, cleanup
bash tests/cloud_pod.sh     # the on-pod runner: branch selection, guards, frame check
```

Both drive their script against stubs, with no card, so a run with several real polling
loops finishes in under a second. Neither can tell you anything about the pod image, and
the distinction is not academic: the stub `pip` in `tests/cloud_pod.sh` is a no-op, so it
sailed straight past the PEP 668 failure that killed the first real pod run before
inference even started.

## Things that cost time on a real pod

**PEP 668.** The `runpod-torch-v280` template is Ubuntu 24.04, which marks the system
Python externally managed, so `pip install` refuses with
`error: externally-managed-environment`. The runner now detects the `EXTERNALLY-MANAGED`
marker and adds `--break-system-packages` only when it is present. A venv is the reflex fix
and the wrong one — the point is to install alongside the CUDA-matched torch the image
already ships, and the pod is disposable.

**runpodctl 2.12.0 has no `--terminate-after`.** The documented cost guard for a throwaway
pod does not exist in that version, so nothing stops a forgotten pod billing. Use `--wait
--wait-timeout` to block until SSH answers, and arm your own watchdog. Also `--gpu-id`
wants the `gpuId` (`NVIDIA A40`), not the `displayName` (`A40`).

**Record the parameters or the render is uninterpretable.** The runner writes a manifest
for this reason.

## Renders are reproducible

SeedVR2 is deterministic. The 1080p master, rendered 2026-08-29, was reproduced
byte-for-byte from its recorded parameters seven days later:

```
master  sha256 8412f5bd5d662b03cc70b43f6a428658affae9a24ce9a5e1   273,813,416 bytes
repro   sha256 8412f5bd5d662b03cc70b43f6a428658affae9a24ce9a5e1   273,813,416 bytes
```

So **a master can be recreated, provided you have its parameters** — which makes the
manifest the load-bearing artifact, not the master file. `masters/` still earns its place
by saving the GPU spend and the wait, but it is a cache, not an irreplaceable original.

(An earlier finding claimed the opposite. It came from comparing a batch-33 render against
a batch-65 master — a parameter difference, not nondeterminism.)

## More detail

[findings.md](findings.md) has the full cloud-runner log, including everything above with
its working.
