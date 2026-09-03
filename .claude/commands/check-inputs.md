---
description: Pre-flight the upstream inputs before moving FEDORA_VERSION
---

Follow [`.github/prompts/bump-fedora-version.md`](../../.github/prompts/bump-fedora-version.md),
which frames the decision, and run the checks in
[`docs/manual-input-check.md`](../../docs/manual-input-check.md).

`ARG FEDORA_VERSION` changes last, only once the tags exist and agree. If they
do not, report that and change nothing — that is the expected answer for a
while after a Fedora release.

Target Fedora release: $ARGUMENTS
