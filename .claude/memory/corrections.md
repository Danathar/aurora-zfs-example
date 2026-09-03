# Corrections

Newest first. See [`README.md`](README.md) for what belongs here.

---

## `post-check.sh` and `bootc container lint` run *before* Chunkah, not after

**Believed:** the rechunked image is covered by the repo's validation, so a
mutable Chunkah tag is not much of a risk.

**True:** both are `RUN` steps in the `Containerfile`, so they execute during
`Build Image`. Chunkah runs afterward as a workflow step, and its output archive
is loaded, tagged, pushed and signed with neither check running again. `Verify
pushed tags share one digest` establishes that every tag resolves to one
manifest — not what that manifest contains.

**Established by:** `Containerfile` (the two `RUN` lines at the end) against the
step order in `.github/workflows/build.yml`. A Codex review on #71 caught the
claim stated backwards in a README rewrite.

**Avoid by:** reading the `Containerfile` and the workflow as one pipeline. Any
sentence of the form "X is checked by post-check.sh" is only true of the
pre-Chunkah image.

---

## `gh pr list` hides the window you are looking for

**Believed:** no open ZFS PR upstream means nothing is moving, so pin.

**True:** `gh pr list` defaults to `--state open`. The situation that matters
most is *after* a ublue patch PR merges but *before* the floating tag rebuilds —
precisely when the default shows nothing. It also hides akmods#554 and #566, the
two PRs `AGENTS.md` tells you to look for.

**Established by:** the 2026-08-09 incident, logged in `AGENTS.md`.

**Avoid by:** always `--state all` when checking upstream for a fix in flight.

---

## A differing `aurora-dx` kernel is not skew

**Believed:** three images, so all three kernel versions should match.

**True:** only the two akmods labels decide skew. `build_files/kernel-akmods.sh`
erases Aurora's kernel RPMs outright and installs the one from the akmods
stream, so this image legitimately runs a newer kernel than Aurora stable
whenever that stream is ahead. That is the design. The `aurora-dx` value is
useful only for judging *how far* ahead things have run.

**Established by:** `AGENTS.md`, "60-second diagnosis".

**Avoid by:** comparing exactly two labels, and treating the third as context.

---

## A full `podman inspect` for `--config-str` breaks at scale

**Believed:** Chunkah's `--config-str` takes a whole `podman inspect` document.

**True:** it takes the `.Config` element. A full inspect also carries
`RootFS.Layers`, `History` and `GraphDriver.Data.LowerDir`, all of which scale
with the base image's layer count. The value is passed as an environment
variable, and Linux caps a single argv/env string at `MAX_ARG_STRLEN` (128 KiB).
Once the Aurora base grew from 128 to 256 layers, the full form crossed that cap
and exec failed with `E2BIG` — surfacing as exit 126, "Argument list too long".
`.Config` stays around 1.5 KiB no matter how many layers the base grows to.

**Established by:** the incident recorded in the `Rechunk Image with Chunkah`
step comments in `.github/workflows/build.yml`.

**Avoid by:** treating any value passed through the environment as
size-bounded. A failure that appears only after an upstream base image grows is
the signature.

---

## Pinning one akmods input is worse than pinning neither

**Believed:** pinning the input that moved is enough to restore the build.

**True:** pinning only one recreates the skew. Both `FROM` lines must carry the
same kernel-pinned tag, and their `ostree.linux` labels must be confirmed
identical before pushing — that is the entire safety property.

**Established by:** the `Containerfile` comments and `AGENTS.md`, "Fix options".

**Avoid by:** changing both `FROM` lines in the same edit, always.

---

## A green local test run is weaker than a green CI run

**Believed:** `./tests/run-tests.sh` passing locally means the suite passes.

**True:** `tests/test-shell-syntax.sh` skips its `shellcheck` pass when the tool
is not installed, deliberately, so the suite stays usable without it. CI
installs `shellcheck` first, so it enforces what a bare local run silently
skips. The bar in CI is *zero output*, informational findings included.

**Established by:** the `Install shellcheck` step in
`.github/workflows/build.yml` and the skip branch in the test itself.

**Avoid by:** installing `shellcheck` before trusting a local pass. The runner
prints `skip shellcheck (not installed)` when it did not run — read it.
