# Tests

Plain-bash tests for the shell this repository ships. No framework to install.

```bash
./tests/run-tests.sh                    # everything
./tests/run-tests.sh test-write-badges  # one file
```

Requirements: bash 4+, `jq`, GNU `date`, `sed`. `shellcheck` is used when
present and skipped when not.

## What is covered

| File | Covers |
| --- | --- |
| `test-write-badges.sh` | `ci/write-badges.sh` end to end, with `skopeo` stubbed |
| `test-post-check.sh` | the pure helpers in `build_files/post-check.sh`, with `rpm`, `ldd` and `find` stubbed |
| `test-post-check-checks.sh` | `check_kernel_tree` and `check_zfs_packages`, against a text stand-in for the RPM database |
| `test-shell-syntax.sh` | `bash -n`, shebang and exec bit on every `*.sh`; `shellcheck -x` when installed |
| `test-docs-paths.sh` | every repo path README.md and AGENTS.md name actually exists |

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

Running on `pull_request` is what closes the gap this suite was written for:
`ci/write-badges.sh` is executed by no other trigger here — the `Status badges`
workflow runs it on a schedule and on `workflow_run` completion and explicitly
skips `pull_request` — so before this job a change to it reached `main` having
never run once.
