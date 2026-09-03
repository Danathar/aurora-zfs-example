# Prompt catalog

Task prompts for the recurring operations in this repo. Each one is a procedure
with a decision at the end, not a description of the codebase — that lives in
[`AGENTS.md`](../../AGENTS.md), and these link to it rather than copying from
it. One copy, one place to keep current.

| Prompt | Use when |
| --- | --- |
| [`diagnose-build-failure.md`](diagnose-build-failure.md) | A `Build container image` run is red |
| [`pin-akmods.md`](pin-akmods.md) | Skew is confirmed and waiting is no longer acceptable |
| [`bump-fedora-version.md`](bump-fedora-version.md) | Fedora N+1 is out and you are considering the move |

`.claude/commands/` wraps these as slash commands for Claude Code. The prompt
files are the source; the commands are thin pointers.
