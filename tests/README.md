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

`build_files/*.sh` and `build_files/post-check.sh` run inside the image build
against a real RPM database, module tree and initramfs. Their happy path is
exercised by the `Build container image` workflow — a failure there blocks the
push — but their failure branches are not reachable from a test on the host, and
they are not structured for sourcing: each runs its work at the top level, so
`source` executes the whole script. Making those testable means guarding the
entry point, for example:

```bash
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
```

which is a change to shipped build code and out of scope for this test-only
change.

## Wiring into CI

The suite is not yet run by any workflow. To gate on it, add a job to
`.github/workflows/build.yml`:

```yaml
  tests:
    name: Shell tests
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v5
      - name: Install shellcheck
        run: sudo apt-get update && sudo apt-get install -y shellcheck
      - run: ./tests/run-tests.sh
```

and make `build_push` depend on it with `needs: tests`. Running it on
`pull_request` is what closes the current gap: `ci/write-badges.sh` executes
only on the `Status badges` workflow's schedule, which never runs on a PR, so a
change to it reaches `main` unexecuted today.
