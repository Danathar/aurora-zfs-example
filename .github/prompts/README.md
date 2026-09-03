# Prompt catalog

Task prompts for the recurring operations in this repo. Each one is a procedure
with a decision at the end, not a description of the codebase — that lives in
[`AGENTS.md`](../../AGENTS.md), and these link to it rather than copying from
it. One copy, one place to keep current.

| Prompt | Use when |
| --- | --- |
| [`diagnose-build-failure.prompt.md`](diagnose-build-failure.prompt.md) | A `Build container image` run is red |
| [`pin-akmods.prompt.md`](pin-akmods.prompt.md) | Skew is confirmed and waiting is no longer acceptable |
| [`bump-fedora-version.prompt.md`](bump-fedora-version.prompt.md) | Fedora N+1 is out and you are considering the move |

The `.prompt.md` suffix is required, not decorative: GitHub Copilot discovers
prompt files in `.github/prompts/` by that extension, so a plain `.md` here
would be invisible to it. Each carries `description` and `mode` frontmatter for
the same reason.

`.claude/commands/` wraps these as slash commands for Claude Code. The prompt
files are the source; the commands are thin pointers.
