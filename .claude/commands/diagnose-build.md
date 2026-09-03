---
description: Diagnose a red Build container image run — skew or not, with evidence
---

Follow [`.github/prompts/diagnose-build-failure.prompt.md`](../../.github/prompts/diagnose-build-failure.prompt.md).

That file is the procedure; do not restate it here. In particular:

- Run the two-label comparison before reading any logs.
- Use `--state all` when checking `ublue-os/akmods` PRs.
- Report a cause with evidence and a recommended option. Do not push a fix that
  loosens the `kmod-zfs` glob or makes its install non-fatal.

Run number or URL, if given: $ARGUMENTS
