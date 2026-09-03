---
description: Pin both akmods inputs to a matching kernel, or unpin them again
---

Follow [`.github/prompts/pin-akmods.prompt.md`](../../.github/prompts/pin-akmods.prompt.md).

Non-negotiable: **both** `FROM` lines move together, and the `ostree.linux`
labels must be confirmed identical before the change is pushed. Leave a note
saying what would let the pin be removed.

Kernel tag to pin to, or `unpin`: $ARGUMENTS
