# Session summary

State of play for an agent picking this repo up cold. `AGENTS.md` says how the
repo *works*; this says what is currently *in flight*, which is the part git
history does not make obvious.

Rewrite it at the end of a session that changes the answer. Delete anything that
has landed — a stale entry here is worse than an empty file, because the next
agent will act on it.

---

**Last updated:** 2026-09-03

## Where things stand

`main` is the maintained AMD/non-NVIDIA branch. The NVIDIA variant lives on
`nvidia-legacy`, tagged `nvidia-last-known-good-2026-05-31`, and is unmaintained.

Neither akmods input is pinned. `FEDORA_VERSION` is 44. If either changes, the
reason belongs in `AGENTS.md`'s incident log, not here.

## In flight

A batch of repository-hygiene work opened together, all off `main` and
independent of each other — no forward references between them, so merge order
does not matter:

| Subject | Notes |
| --- | --- |
| README accuracy (#70) | Corrected the Chunkah pinning and renovate config claims, plus a test that fails when the docs name a path that does not exist |
| Contributor templates | `CONTRIBUTING.md`, PR template, issue forms |
| Style config and coverage gate | `.shellcheckrc`, `.editorconfig`, a coverage manifest, and a workflow covering the paths `build.yml` ignores |
| End-to-end build | `tests/e2e/`, including a mode that re-checks the rechunked image |
| Agent configuration | Prompts, commands, and this file |
| L3 quality docs | `docs/quality.md`, `docs/metrics.md`, `docs/review-rubric.md`, `.claude/settings.json` |

`docs/` is in `build.yml`'s `paths-ignore`, so a docs-only branch may show no
checks at all. That is the workflow config, not a failure.

## Open threads worth knowing about

**Nothing validates the image after Chunkah.** `post-check.sh` and `bootc
container lint` are `RUN` steps, so they run before the rechunk; the re-layered
archive is loaded, tagged, pushed and signed unchecked. `tests/e2e/run-e2e.sh
--rechunk` closes this loop locally but nothing does in CI. Worth running after
a Chunkah version bump.

**The Chunkah pin is a semver tag, not a digest**, and `renovate.json` disables
digest updates for it deliberately. Do not "fix" that without checking whether
the maintainer wants the tradeoff changed.

## Before you start anything

Check the OpenZFS/kernel badge. If it says `blocked`, upstream akmod skew is in
progress, the build cannot pass, and the response — wait, pin both inputs, or
switch streams — is in `AGENTS.md`. Do not attempt a code fix for it.
