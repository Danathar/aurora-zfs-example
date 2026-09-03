# Claude Code commands

Slash commands for this repo. Each is a thin pointer at the matching file in
[`.github/prompts/`](../../.github/prompts/), which is where the actual
procedure lives — so there is one copy to keep current, and Copilot, Cursor and
Claude all read the same source.

| Command | Does |
| --- | --- |
| `/diagnose-build` | Work out whether a red build is akmod skew, with evidence |
| `/pin-akmods` | Pin both akmods inputs to a matching kernel, or unpin |
| `/check-inputs` | Pre-flight the upstream inputs before moving `FEDORA_VERSION` |
