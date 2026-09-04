# Tests

Plain-bash tests for the shell this repository ships. No framework to install.

```bash
./tests/run-tests.sh                    # everything
./tests/run-tests.sh test-write-badges  # one file
```

Requirements: bash 4+, `jq`, GNU `date`, `sed`. `shellcheck` is used when
present and skipped when not.

## What is covered

| File                        | Covers                                                                                     |
| --------------------------- | ------------------------------------------------------------------------------------------ |
| `test-write-badges.sh`      | `ci/write-badges.sh` end to end, with `skopeo` stubbed                                     |
| `test-post-check.sh`        | the pure helpers in `build_files/post-check.sh`, with `rpm`, `ldd` and `find` stubbed      |
| `test-post-check-checks.sh` | `check_kernel_tree` and `check_zfs_packages`, against a text stand-in for the RPM database |
| `test-shell-syntax.sh`      | `bash -n`, shebang and exec bit on every `*.sh`; `shellcheck -x` when installed            |
| `test-coverage.sh`          | every shipped `*.sh` is declared covered by a named test or UNCOVERED with a reason        |
| `test-docs-paths.sh`        | every repo path README.md and AGENTS.md name actually exists                               |
| `test-ci-workflows.sh`      | CI still runs this suite, and neither workflow's path filter leaves a gap                  |
| `test-auto-qa-tuning.sh`    | every workflow job is bounded by a timeout, and declared to the auto-QA manifest at the number the YAML actually says |

`ci/write-badges.sh` is run as a real subprocess. Its only two inputs are a
Containerfile (a fixture file) and `skopeo inspect`, which a stub earlier on
`PATH` answers from canned JSON while recording its own argv. Nothing else is
mocked, so the tests exercise the script's actual control flow, including the
two properties its comments call deliberate:

- an input that cannot be read leaves the corresponding badge file untouched
  instead of overwriting it with a guess, and
- image references come from the Containerfile's `FROM` lines, so an outage pin
  is reflected in the badge rather than reported against the floating tags.

One case copies the checked-in `Containerfile` in as its fixture: if a stage is
renamed or dropped, that test fails rather than the badge silently going stale.

`test-docs-paths.sh` applies the same idea to the prose. AGENTS.md tells an
agent mid-incident to trust these two documents, so a path they name that does
not exist is a real defect — README.md advertised `.github/renovate.json5` for
some time while the file was `renovate.json` at the repo root. It checks the
"Repository Layout" block line by line, then the inline code spans, anchoring
the filter on `git ls-files` so that GitHub `org/repo` references are skipped
while anything rooted in a real top-level entry is enforced.

`test-ci-workflows.sh` closes the same kind of gap one level up. Everything in
the "In CI" section below was, until it existed, prose that nothing checked: the
suite could keep passing while the workflow that runs it was renamed, stripped
of its `shellcheck` install, or unhooked from `build_push`. The path filters are
the sharp case, because a workflow that stops running is not a workflow that
fails — a `paths-ignore` that grows a third entry produces a *green* result on
the very change that stopped being covered. It reads the YAML with an
indentation-anchored parser rather than adding a dependency, and exercises that
parser against a fixture first, so a reformat it cannot follow fails the suite
instead of passing over an empty extraction.

What runs that test matters as much as what it asserts, and this is the part a
first draft got wrong. A `pull_request` run executes the *head* branch's copy of
a workflow file, so a pull request deleting the `Shell tests` job from
`build.yml` would be checked by the `build.yml` that no longer has it — the
suite that would have gone red is the suite that no longer runs. So
`coverage-gate.yml` triggers on `.github/workflows/**` too, and the test asserts
that it does: any workflow edit is checked by a workflow the pull request did
not touch, and the two files police each other. Disabling the gate now takes an
edit to both in one pull request. Making that impossible rather than merely
conspicuous needs a required status check in branch protection, which no file in
the tree can assert.

The branch and activity filters are checked for the same reason. A path filter
is not the only way a workflow stops running: point `build.yml`'s
`pull_request` at another branch and it no longer runs on pull requests to
`main`, while `coverage-gate.yml` keeps running and every path assertion still
passes. Merge that and a source-only pull request runs no suite at all — the
same hole, reached by a different door.

`test-auto-qa-tuning.sh` holds `.github/auto-qa-tuning.json` against the
workflow files. That manifest is what `auto-qa.yml` samples against, and it has
two failure modes that are quiet in the same way: a job absent from it is never
sampled and nothing goes red, and a `timeout_minutes` that no longer matches the
YAML makes every verdict wrong in a direction the workflow cannot see — it reads
the numbers there, not the YAML. `status-badges.yml` shipped for months with no
`timeout-minutes` at all and no entry in the manifest, so its `badges` job — the
one holding `contents: write` — could have held a runner for six hours on a hung
`skopeo`. The test asserts every job declares a timeout, appears in exactly one
of `jobs` or `untracked`, and, when tracked, at the number the workflow really
declares. `untracked` is the `UNCOVERED` idiom from `test-coverage.sh`: not
watching a job is a legitimate answer, but it has to be an answer, with the
reason next to it.

## End-to-end

`tests/e2e/run-e2e.sh` builds the real image with podman and checks the real
artifact. It is not part of this suite — `run-tests.sh` globs `test-*.sh` at
`maxdepth 1` — because it takes tens of minutes and about 40G.

Its `--rechunk` mode covers the one thing nothing else does: `post-check.sh` and
`bootc container lint` are `RUN` steps, so they validate the image *before* the
workflow hands it to Chunkah, and nothing re-checks the re-layered result before
it is pushed and signed. See [`e2e/README.md`](e2e/README.md).

## The coverage gate

`test-coverage.sh` exists because a percentage would be meaningless here. Most
of this repo's shell cannot be reached from the host at all, so a line-coverage
threshold would either sit near zero forever or get gamed. What is worth
enforcing is that the gap stays deliberate.

It holds a manifest pairing every tracked `*.sh` outside `tests/` with either
the test file that covers it or the literal `UNCOVERED` and a reason. Adding a
script without touching that manifest turns the suite red, so the decision gets
made once, in the open. It is checked in both directions — a stale entry left
behind by a deleted script fails too, as does a "covered by" claim naming a test
file that does not exist or never mentions the script.

## post-check.sh

The script guards its entry point with

```bash
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
```

so sourcing it defines `require_glob`, `verify_rpm_payload`,
`require_single_rpm_version` and the rest without running a single check.
`test-post-check.sh` calls them directly with a stub standing in for `rpm`,
`ldd` or `find`, and asserts the guard in both directions: sourcing runs no
check, executing still runs `main`.

`test-post-check-checks.sh` goes one level up, to the `check_*` stages. Two of
the six decide purely from what `rpm` and `find` report, so they run on any
host: `check_kernel_tree` and `check_zfs_packages`. What is worth testing there
is the wiring rather than any single call — which package names are demanded,
which glob feeds the version comparison, and whether a verdict assembled from
several `rpm` invocations survives. A stub that answers every query the same way
cannot show that, so this file backs `rpm` with a small text database — one
`NAME VERSION RELEASE ARCH` record per line — and lets the real queries run
against it. That also keeps the stub honest about a detail the script depends
on: `rpm -qa 'libzfs[0-9]*'` returns full `NVRA` strings that are handed
straight back to `rpm -q --qf`, so both forms have to resolve.

## Not covered

`check_zfs_modules`, `check_zfs_userspace` and `check_initramfs` read absolute
paths under `/usr/lib` and require `zfs`/`zpool`/`zdb`/`zed` on `PATH`. On any
host that is not the finished image they fail before reaching the logic worth
checking — the `spl`/`zfs` vermagic comparison, the `modules-load.d` content
match and the `lsinitrd` listing — so covering them needs an injectable root
prefix in the script itself. `check_rpm_payloads` is one call to
`verify_rpm_payload`, which `test-post-check.sh` already covers.

The other `build_files/*.sh` scripts still run their work at the top level, so
`source` executes the whole file. Their happy path is exercised by the `Build
container image` workflow — a failure there blocks the push — and their failure
branches remain untested.

## In CI

`.github/workflows/build.yml` runs the suite as a `Shell tests` job on every
pull request and push, with `shellcheck` installed so that pass is enforced
rather than skipped, and `build_push` has `needs: tests` so a red suite blocks
the image build.

`build.yml` sets `paths-ignore` for `README.md` and `docs/**` though, so a
change touching only those starts no run there.
`.github/workflows/coverage-gate.yml` triggers on that complement and runs the
same suite, so a docs-only change is no longer the one kind of change nothing
verifies. One workflow or the other runs the suite; a change touching both docs
and code trips both.

`coverage-gate.yml` also triggers on `.github/workflows/**`, which is the
deliberate exception to "one or the other": it is what lets it check a change to
`build.yml`, which `build.yml` cannot check for itself.

All four of those facts — both workflows running the suite with `shellcheck`
installed first, `needs: tests`, and every path one workflow ignores being
picked up by the other — are asserted by `test-ci-workflows.sh`, so this section
is enforced rather than merely accurate.

Running on `pull_request` is what closes the gap this suite was written for:
`ci/write-badges.sh` is executed by no other trigger here — the `Status badges`
workflow runs it on a schedule and on `workflow_run` completion and explicitly
skips `pull_request` — so before this job a change to it reached `main` having
never run once.
