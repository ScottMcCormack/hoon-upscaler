# Terms of use and contribution

## Licence

This project's own code is licensed **Apache-2.0** — see [LICENSE](LICENSE).

Apache-2.0 rather than MIT for two reasons that apply here: it carries an explicit patent
grant, which matters in territory this dense with video-codec and ML patents, and its
NOTICE mechanism is the right place to record third-party terms.

**Read [NOTICE](NOTICE) before reusing this code.** It vendors nothing, but
[pipeline/detect_car.py](pipeline/detect_car.py) imports `ultralytics`, which is
**AGPL-3.0**. The Apache-2.0 licence here is not permission to use that file, or a work
derived from it, in a closed-source product. The reframing solver
([pipeline/reframe_src.py](pipeline/reframe_src.py)) reads detections as JSON and does not
import ultralytics, so a different detector can be substituted at that boundary.

**No code licence covers video.** The source clip and any renders are not in this
repository and are not licensed by `LICENSE`. If you share a render, state its terms
where you share it.

## Branching and merging

`main` is protected. It never receives commits directly.

- Branch from `main` for all work. Never `git push origin main`.
- Every change lands through a pull request.
- **PRs are always squash-merged.** One PR becomes one commit on `main`.

Because the merge squashes, **the PR title and description become the permanent commit on
`main`** — the squash commit is prefilled from them, not from your branch's commit
messages. Write the description for someone reading `git log` in a year: what the change
is and why, not how the review went.

Branch commit messages are working notes. They earn their keep during review, where they
are read alongside the diff, but they do not survive the merge — so a branch is free to
carry "address review" and "fix the fix" commits without that history reaching `main`.

After a merge:

```bash
git fetch origin
git switch main && git merge --ff-only origin/main
git branch -D your-branch     # -D, not -d: the squash commit is new, so the
                              # branch's commits are never its ancestors
```

## What never gets committed

[.gitignore](.gitignore) enforces most of this. The reasoning:

| Never commit | Why |
|---|---|
| `*.key`, `*.pem`, `.env*`, `runpod.toml`, `**/config.toml` | Credentials. A rented-GPU API key in history is a live key. |
| `*.mp4`, `*.mkv`, `*.mov`, `*.png`, `*.jpg`, `*.trf` | Media is too large for git and never diffs usefully. |
| `models/`, `*.safetensors`, `*.pth`, `*.gguf` | Model weights belong to their upstream projects. |
| `input/`, `masters/`, `out/`, `work/`, `frames_*/` | Working media. Kept on disk, never pushed. |

If you need a file to survive inside an ignored directory, exclude the directory's
**contents** rather than the directory itself, then negate:

```gitignore
masters/*
!masters/README.md
```

`masters/` on its own cannot be undone by a later `!` line — git never descends into an
excluded directory, so the negation is silently ignored along with everything else.

**If a credential is ever committed, it is compromised.** Rotate it. Removing the commit
is not sufficient.

## How claims get made in this repo

[docs/findings.md](docs/findings.md) records what was tried and ruled out so it isn't
repeated. Contributions to it follow the same standard the existing entries do:

- **State what was tested, and what it was tested against.** "36% softer and 2.3× slower
  than 3B, on a 48GB card" is usable; "7B was worse" is not.
- **Say when a result was handicapped.** Several early conclusions came from VRAM-starved
  runs and were wrong. Distinguish *the model can't* from *this GPU can't*.
- **Do not add perceptual quality metrics.** Six were built and all six failed or actively
  misled — one correlated with sharpness at r = 0.88, because speckle *is* high-frequency
  content. Metrics are welcome for things with objective definitions: frame counts, timing
  gaps, boundary alignment, throughput, file integrity. For "does this look right",
  produce a visual comparison and ask.
- **Record dead ends, not just wins.** The twenty failed pre-filters are the most useful
  section in the file.

## A term of use for the output

The source is 352×288. Everything above that is **reconstructed, not recovered** — the
model infers plausible detail rather than revealing hidden detail.

During development the model rendered a phone number on a sign cleanly and confidently as
`09 9270 5500`. The sign reads `08 9370 5600`.

Output from this pipeline is suitable for viewing. **It is not evidence, and must not be
presented as a faithful record of what the camera captured.** If you publish or share a
render, say that it is AI-reconstructed.

## Contributions

Contributions are welcome. **Open an issue before sending a pull request** so the
approach can be agreed first — a lot of the reasoning in this repository is about what
was already tried and ruled out, and an issue is the cheapest place to find out that
your idea is in [docs/findings.md](docs/findings.md) already.

Issues are also the right place for bug reports, questions, and results from running the
recipe on your own footage — the last of these is genuinely useful, since everything here
was tuned against a single 2007 Nokia N90 clip.

Pull requests should keep `main` mergeable by squash: one PR, one coherent change.
