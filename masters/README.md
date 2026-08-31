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
