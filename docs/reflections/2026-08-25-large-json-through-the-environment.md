# The failure was in the plumbing, not the payload

**2026-08-25** — build pipeline, Chunkah

## What happened

`Rechunk Image with Chunkah` started failing with:

```
/usr/local/bin/podman: Argument list too long
##[error]Process completed with exit code 126.
```

Nothing in this repo had changed. Upstream Aurora had grown from 128 to 256
layers.

The step passed a full `podman inspect` to Chunkah through
`CHUNKAH_CONFIG_STR`, an environment variable. A full inspect embeds per-layer
data three times over — `RootFS.Layers`, `History`,
`GraphDriver.Data.LowerDir` — so its size scales with the base image's layer
count. Linux caps a single argv/env string at `MAX_ARG_STRLEN` (32 pages =
128 KiB). At 256 layers the value crossed the cap and `exec` failed with
`E2BIG`.

Full diagnosis:
[`AGENTS.md`](../../AGENTS.md#chunkah-rechunk-argument-list-too-long-exit-126).

## What changed

The step now passes `--format '{{json .Config}}'`, which is what Chunkah
documents `--config-str` as taking in the first place. `.Config` holds only
Env/Cmd/WorkingDir/Labels and stays around 1.5 KiB no matter how many layers the
base grows to.

The fix is smaller than the bug, which is the tell that the original code was
passing something it never needed.

## What to carry forward

- **Read what the interface asks for.** Chunkah asked for the `.Config`
  element. Handing it the whole document worked by accident for months, and the
  accident had a size limit attached.
- **An input that scales with something you do not control is a time bomb with
  someone else's timer.** Nothing in this repo changed on the day it broke. When
  a value's size tracks an upstream property — layer count, package count, tag
  count — assume it will eventually cross a limit, and prefer the bounded form.
- **A limit you have never heard of is still a limit.** `MAX_ARG_STRLEN` is not
  in anyone's working memory. It is now in `AGENTS.md` with the symptom text,
  because the next person will meet it as `exit 126` and not as a documented
  constant.

The general form worth keeping: **do not pipe unbounded data through the process
environment.** If it can grow, put it in a file.
