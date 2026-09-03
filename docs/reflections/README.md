# Reflections

Durable lessons from things that went wrong here — written down so the next
session, human or agent, starts with them instead of rediscovering them.

## How this differs from the incident log

[`AGENTS.md`](../../AGENTS.md#incident-log) already has an **incident log**, and
this does not replace or duplicate it. They answer different questions:

| | Answers | Example |
| --- | --- | --- |
| `AGENTS.md` incident log | *What is upstream doing to us right now, and what do I do about it?* | Fedora kernel 7.1 vs OpenZFS 2.4.3 skew, and whether to wait, pin or switch |
| This directory | *What did we learn about how to build and operate this repo?* | Never pipe large JSON through the process environment |

The incident log is a **diagnostic reference** consulted mid-incident, and it
tracks upstream events this repo does not control. These entries are
**retrospective**, they are about decisions made on this side, and they are
written once the dust has settled.

If you are debugging a red build right now, you want
[`AGENTS.md`](../../AGENTS.md), not this directory.

## What earns an entry

Not every fix. An entry is worth writing when the fix taught something that
would not be obvious to someone reading the resulting code:

- a failure whose cause was somewhere other than where it surfaced
- a check that existed but proved nothing, or proved less than it appeared to
- a class of change this repo should treat differently from now on

A one-line fix to an obvious bug does not need an entry. A one-line fix that
took two days to find usually does.

## Format

One file per lesson, named `YYYY-MM-DD-short-slug.md`, dated when the lesson was
learned rather than when it was written up. Three headings: what happened, what
changed, what to carry forward. Keep the diagnosis in `AGENTS.md` and link to it
rather than restating it.

Entries are append-only. If a lesson later turns out to be wrong, add a new
entry saying so and link the two — do not quietly edit history, because the
point of this directory is to be trustworthy about what was believed and when.
