# masters

Raw SeedVR2 output — before timing repair, grading and interpolation.

Keep these. Any change to the grade, the interpolation strategy or the timing
handling can be re-run from here with `pipeline/finish.sh`, on CPU, in about an
hour — with no GPU and no cloud spend.

| file | what |
|---|---|
| `sr_out_1080.mp4` | 1914x1080, 6.1x, A40, batch 33 / overlap 5 — the master used for the final |
| `sr_out_720.mp4`  | 1276x720, 4.1x, A40, batch 65 / overlap 5 |

Regenerating either needs ~$0.50 of rented GPU; regenerating everything downstream
of them is free.

## Every master needs its parameters beside it

`cloud/run_on_pod.sh` now writes a `.json` manifest next to each render — the full
argument list, model file, resolution, GPU and VRAM, torch version, the SeedVR2 commit,
and frame counts plus sha256 for both input and output.

That is not bookkeeping. These two masters were made before the manifest existed, and the
table above records only batch and overlap: `chunk_size`, the cache flags,
`color_correction` and the SeedVR2 revision are all unrecorded. It cost a wasted
comparison — a fresh batch-33 render was measured against the batch-65 720p master and the
difference read as evidence the model is nondeterministic, when the two had simply been
asked for different things.

**The 720p master needs an override to reproduce.** It was made at batch 65 and the A40
branch derives batch 33, so pass the recorded parameters explicitly:

```bash
BATCH_SIZE=65 TEMPORAL_OVERLAP=5 bash run_on_pod.sh 720 full
```

SeedVR2 is deterministic given identical parameters — verified byte-identical across two
runs on one pod — so a manifest plus these overrides recreates a master exactly.

Any master added from here should arrive with its manifest. For the two above, what is
known is in the table and nothing more is recoverable.
