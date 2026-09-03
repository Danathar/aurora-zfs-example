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
| `test-shell-syntax.sh` | `bash -n`, shebang and exec bit on every `*.sh`; `shellcheck -x` when installed |

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

## Not covered

`build_files/post-check.sh`'s `check_*` functions run inside the image build
against a real RPM database, module tree and initramfs, so they are not
reachable from a test on the host. Its helpers are: the script guards its entry
point with

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
