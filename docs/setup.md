# Setup

Everything the pipeline needs, in the order it needs it. Budget about fifteen minutes,
most of which is the SeedVR2 install.

If you only want to see what the pipeline does before installing anything, the
before/after clip is in the [README](../README.md).

## 1. The repository

```bash
git clone https://github.com/ScottMcCormack/hoon-upscaler.git
cd hoon-upscaler
python3.12 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

**Python 3.12, not 3.14.** Neither numpy nor opencv ships a `cp314` wheel yet, so 3.14
fails at install time rather than at run time.

`requirements.txt` is the core pipeline only — the finishing steps, the timing maths and
the grade. It does not pull in torch, and it does not install SeedVR2.

## 2. ffmpeg, with vidstab

`ffmpeg` and `ffprobe` must be on PATH, and **the ffmpeg build must include the vidstab
filters**. Stabilisation uses `vidstabdetect` and `vidstabtransform`, which are only
present in builds configured with `--enable-libvidstab`. Not every distribution build has
them, so check before you rely on it:

```bash
ffmpeg -filters | grep vidstab      # expect vidstabdetect and vidstabtransform
```

Two lines of output means you are fine. No output means your ffmpeg cannot stabilise and
you need a different build — a full-featured static build, or your package manager's
`ffmpeg` rather than a minimal one. Check the same way afterwards; the flag is the only
thing that settles it.

## 3. SeedVR2

SeedVR2 is a separate project and is deliberately not vendored here. Clone it *beside*
this repository, so that `../SeedVR2` resolves from the repo root:

```bash
cd ..
git clone https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler.git SeedVR2
cd SeedVR2
```

Install its requirements, but **strip torch out first**:

```bash
grep -vE '^(torch|torchvision)([=<>].*)?$' requirements.txt > /tmp/req_noTorch.txt
pip install -r /tmp/req_noTorch.txt
```

Its `requirements.txt` lists bare `torch` and `torchvision`. Installed as written, pip
replaces whatever CUDA-matched build you have with a generic one, and you find out when
inference fails on a card that worked yesterday.

**Model weights download themselves** from HuggingFace on first run — there is nothing to
fetch by hand. They come from
[numz/SeedVR2_comfyUI](https://huggingface.co/numz/SeedVR2_comfyUI). The first run is
therefore slower than every run after it, which is worth knowing before you time one on a
rented GPU.

## 4. torch, and the Blackwell trap

If you are installing torch locally — for SeedVR2, or for the reframing path below — the
card generation decides the index you install from.

**On Blackwell (RTX 50-series, `sm_120`), install from the cu130 index first:**

```bash
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu130
```

Stock cu124/126/128 builds carry no `sm_120` kernels. The failure is not a clean "card
unsupported" message, so it is worth getting right the first time.

On Ampere or Ada — including every cloud card this pipeline has been run on — any recent
build works, and this step is just `pip install torch torchvision`.

More hardware detail, including the VRAM thresholds that actually matter, is in
[cloud-gpu.md](cloud-gpu.md).

## 5. Optional: the reframing path

The experimental tracked-reframing scripts need a second requirements file:

```bash
pip install -r requirements-reframe.txt
```

This pulls in `ultralytics`, which is **AGPL-3.0**, not Apache-2.0 like the rest of this
repository. Read [NOTICE](../NOTICE) before reusing any of it. Install it only if you
intend to work on that path — it is **not part of the main pipeline**, and is not
runnable as shipped. See [pipeline.md](pipeline.md#the-experimental-reframing-path).

## Checking it worked

```bash
bash tests/run.sh
```

No GPU and no footage of your own required — the fixtures are synthetic and tiny, and the
cloud layer is stubbed. It really does run ffmpeg, ffprobe, numpy and OpenCV end to end
through the finishing pipeline, so it is a genuine check that step 1 installed correctly
and that the pipeline's own logic is right.

**It is not a check of steps 2-4.** The preflight it runs on itself confirms `ffmpeg` and
`ffprobe` are on PATH, not that the build has the vidstab filters step 2 actually needs —
run the `ffmpeg -filters | grep vidstab` check above for that. SeedVR2 and torch (steps 3
and 4) are stubbed throughout, by design: a fake torch module stands in so the surrounding
script logic can be tested without a GPU, but nothing here imports the real one or reaches
SeedVR2 itself. The first honest test of a real GPU, model, and render is a short cloud
run — see [cloud-gpu.md](cloud-gpu.md).
