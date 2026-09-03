#!/usr/bin/env bash
#
# Asserts that CI still runs this suite, and that the two workflows which run it
# between them cover every change.
#
# The shell suite is the only automated gate this repo has on the host side, and
# nothing in tests/ knew whether CI still ran it. Deleting the `Shell tests` job,
# dropping `needs: tests` from `build_push`, or narrowing a path filter would all
# leave every test green while the gate quietly stopped gating.
#
# The path filters are the subtle one. `build.yml` sets `paths-ignore` so a
# docs-only change starts no run there; `coverage-gate.yml` exists precisely to
# catch that complement. If somebody adds a path to `paths-ignore` and does not
# add it to `coverage-gate.yml`, a whole class of change stops being verified by
# anything, and no existing test notices. That is the invariant checked below:
#
#     every path build.yml ignores is a path coverage-gate.yml triggers on
#
# One direction only. The reverse does not hold and is not meant to:
# `coverage-gate.yml` also triggers on `**/README.md`, which `build.yml` ignores
# on `push` but not on `pull_request`, so a pull request touching only
# `tests/README.md` runs the suite twice. Both workflows' own comments call that
# trade deliberate.
#
# The YAML is read with a small indentation-aware parser rather than a YAML
# library, because the suite deliberately has no dependency beyond bash, jq,
# date and sed. It is anchored on the two-space/four-space/six-space shape the
# workflows are written in, and every extraction is asserted non-empty, so a
# reformat that defeats the parser fails loudly instead of passing vacuously.

set -uo pipefail

TEST_NAME="test-ci-workflows"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

BUILD_WORKFLOW="${REPO_ROOT}/.github/workflows/build.yml"
GATE_WORKFLOW="${REPO_ROOT}/.github/workflows/coverage-gate.yml"
BADGES_WORKFLOW="${REPO_ROOT}/.github/workflows/status-badges.yml"
RUNNER="./tests/run-tests.sh"

# --- the workflow files themselves ------------------------------------------

assert_file_exists "build.yml exists" "${BUILD_WORKFLOW}"
assert_file_exists "coverage-gate.yml exists" "${GATE_WORKFLOW}"
assert_file_exists "status-badges.yml exists" "${BADGES_WORKFLOW}"

if [[ ! -f "${BUILD_WORKFLOW}" || ! -f "${GATE_WORKFLOW}" ]]; then
    finish
    exit
fi

# --- both workflows run this suite ------------------------------------------

for workflow in "${BUILD_WORKFLOW}" "${GATE_WORKFLOW}"; do
    name="$(basename "${workflow}")"

    if grep -qF -- "run: ${RUNNER}" "${workflow}"; then
        _pass "${name} runs ${RUNNER}"
    else
        _fail "${name} runs ${RUNNER}" \
            "no step runs the suite; the gate this file is named for is gone"
    fi

    # test-shell-syntax.sh skips shellcheck when the tool is absent, so a run
    # without it installed is weaker than it looks. CI is where that pass is
    # enforced, which only holds while CI installs the tool.
    if grep -q 'apt-get install -y shellcheck' "${workflow}"; then
        _pass "${name} installs shellcheck before running the suite"
    else
        _fail "${name} installs shellcheck before running the suite" \
            "without it test-shell-syntax.sh skips its shellcheck pass in CI too"
    fi
done

assert_file_exists "the runner the workflows invoke exists" "${REPO_ROOT}/tests/run-tests.sh"

# --- a red suite still blocks the image build -------------------------------

if grep -qE '^ +needs: tests$' "${BUILD_WORKFLOW}"; then
    _pass "build_push still depends on the tests job"
else
    _fail "build_push still depends on the tests job" \
        "build.yml has no 'needs: tests'; a red suite would no longer block the build"
fi

# --- the path filters, which is where a gap would actually open -------------

# Reads a list under `on: <event>: <key>:` from a workflow, one entry per line
# with any surrounding quotes stripped. Indentation-anchored: events at two
# spaces, their keys at four, list entries at six.
extract_filter() {
    local file=$1 event=$2 key=$3
    local line in_on=0 in_event=0 in_key=0 value

    while IFS= read -r line; do
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue

        if [[ "${line}" == "on:" ]]; then
            in_on=1
            continue
        fi
        if [[ "${in_on}" -eq 1 && "${line}" =~ ^[^[:space:]] ]]; then
            in_on=0
        fi
        [[ "${in_on}" -eq 1 ]] || continue

        if [[ "${line}" =~ ^\ \ ([A-Za-z_]+):[[:space:]]*$ ]]; then
            if [[ "${BASH_REMATCH[1]}" == "${event}" ]]; then
                in_event=1
            else
                in_event=0
            fi
            in_key=0
            continue
        fi

        if [[ "${in_event}" -eq 1 && "${line}" =~ ^\ \ \ \ ([A-Za-z_-]+):[[:space:]]*$ ]]; then
            if [[ "${BASH_REMATCH[1]}" == "${key}" ]]; then
                in_key=1
            else
                in_key=0
            fi
            continue
        fi

        if [[ "${in_key}" -eq 1 ]]; then
            if [[ "${line}" =~ ^\ \ \ \ \ \ -[[:space:]]+(.*)$ ]]; then
                value="${BASH_REMATCH[1]}"
                value="${value%"${value##*[![:space:]]}"}"
                value="${value#[\"\']}"
                value="${value%[\"\']}"
                printf '%s\n' "${value}"
            else
                in_key=0
            fi
        fi
    done <"${file}"
}

contains_line() {
    local needle=$1 haystack=$2
    grep -qxF -- "${needle}" <<<"${haystack}"
}

for event in pull_request push; do
    ignored="$(extract_filter "${BUILD_WORKFLOW}" "${event}" paths-ignore)"
    triggers="$(extract_filter "${GATE_WORKFLOW}" "${event}" paths)"

    if [[ -z "${ignored}" ]]; then
        _fail "build.yml declares a ${event} paths-ignore list" \
            "parsed nothing; either the filter was removed or the file was reformatted" \
            "past what this test can read"
        continue
    fi
    _pass "build.yml declares a ${event} paths-ignore list"

    if [[ -z "${triggers}" ]]; then
        _fail "coverage-gate.yml declares a ${event} paths list" \
            "parsed nothing; a docs-only ${event} would now run no suite at all"
        continue
    fi
    _pass "coverage-gate.yml declares a ${event} paths list"

    while IFS= read -r path; do
        [[ -z "${path}" ]] && continue
        if contains_line "${path}" "${triggers}"; then
            _pass "${event}: coverage-gate.yml covers what build.yml ignores: ${path}"
        else
            _fail "${event}: coverage-gate.yml covers what build.yml ignores: ${path}" \
                "build.yml skips this path on ${event} and coverage-gate.yml does not" \
                "trigger on it, so such a change would run no shell suite anywhere"
        fi
    done <<<"${ignored}"
done

# --- why the suite has to run at pull-request time at all -------------------
#
# ci/write-badges.sh is executed by no other trigger here: status-badges.yml
# runs it on a schedule and on workflow_run completion, and skips pull requests.
# If that skip ever went away this test would be over-strict rather than wrong,
# but the comment in build.yml explaining why its tests job exists would have
# gone stale, which is worth being told about.

if grep -qF "github.event.workflow_run.event != 'pull_request'" "${BADGES_WORKFLOW}"; then
    _pass "status-badges.yml still skips pull requests"
else
    _fail "status-badges.yml still skips pull requests" \
        "build.yml's tests job documents this skip as the reason it runs write-badges.sh" \
        "on every pull request; update that comment if the skip is gone"
fi

finish
