#!/usr/bin/env bash
#
# Asserts that CI still runs the shell suite, and that nothing it gates has
# quietly stopped being gated.
#
# Every host-side guarantee this repo makes rests on four facts about
# .github/workflows/, and until this file none of them was checked by anything:
#
#   1. build.yml's `Shell tests` job runs ./tests/run-tests.sh
#   2. coverage-gate.yml runs the same suite on the complement of build.yml's
#      paths-ignore, so a docs-only change is verified by something
#   3. both jobs install shellcheck *before* running the suite, which is what
#      makes test-shell-syntax.sh's shellcheck pass enforced rather than
#      skipped (that test skips it when the tool is absent, by design)
#   4. build_push has `needs: tests`, so a red suite blocks the image build
#
# Delete the tests job, drop `needs: tests`, drop the shellcheck install, or add
# a path to paths-ignore without adding it to coverage-gate.yml, and the suite
# stays green while the gate stops gating. test-coverage.sh does not catch it:
# it asserts a coverage *decision* exists for every shipped script, not that the
# decision is enforced anywhere.
#
# The path filters are the sharp case. A workflow that stops running is not a
# workflow that fails — the run that would have gone red is the run that no
# longer starts — so a paths-ignore that grows a third entry produces a green CI
# result on the very change that stopped covering that path.
#
# Only one direction of the path relation is asserted: every path build.yml
# ignores must appear in coverage-gate.yml for the same event. The reverse does
# not hold and should not. coverage-gate.yml also triggers on '**/README.md',
# which build.yml ignores on push but not on pull_request, so a pull request
# touching only tests/README.md runs the suite twice. Both workflows' comments
# call that trade deliberate, so the assertion is a superset check rather than
# equality.
#
# What runs this test matters as much as what it asserts. A `pull_request` run
# executes the *head* branch's copy of a workflow file — measured on this repo
# and written up in docs/SECURITY-AI.md — so a pull request that deletes the
# `Shell tests` job from build.yml is checked by the build.yml that no longer
# has it. The suite that would have gone red is the suite that no longer runs,
# and build_push proceeds. A test living inside the workflow it polices cannot
# close that on its own.
#
# So coverage-gate.yml triggers on '.github/workflows/**' as well, and this file
# asserts that it does. Any workflow edit is then checked by a workflow the pull
# request did not touch, and the two files police each other: build.yml runs the
# suite on a change to coverage-gate.yml, and coverage-gate.yml runs it on a
# change to build.yml. Disabling the gate takes an edit to both in one pull
# request rather than one line in one file. The last step — making that
# impossible rather than merely conspicuous — is a required status check in
# branch protection, which no file in the tree can assert.
#
# The YAML is read with an indentation-anchored parser rather than a real one:
# CONTRIBUTING.md asks for a conversation before adding a dependency, and the
# structure needed here is shallow. The risk of hand-parsing is silent
# under-extraction — a reformat the parser cannot follow yields an empty result,
# and an assertion over nothing passes. So every extraction is checked for
# emptiness first and fails loudly, and each parser helper is exercised against
# a fixture with a known answer before it is trusted against the real files.

set -uo pipefail

TEST_NAME="test-ci-workflows"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

BUILD_WF="${REPO_ROOT}/.github/workflows/build.yml"
COVERAGE_WF="${REPO_ROOT}/.github/workflows/coverage-gate.yml"
BADGES_WF="${REPO_ROOT}/.github/workflows/status-badges.yml"

# --- parser -----------------------------------------------------------------
#
# Two extractors, both anchored on indentation. The workflows are written with
# two-space indents throughout, so an event key sits at column 2, its `paths:`
# style keys at column 4, and their list items at column 6.

# event_paths <file> <event> <key>
#
# Prints one path per line from `on: <event>: <key>:`. Quotes are stripped;
# order is preserved.
event_paths() {
    local file=$1 event=$2 key=$3
    awk -v event="${event}" -v key="${key}" '
        # Top-level "on:" opens the trigger block; any other column-0 key ends it.
        /^on:[[:space:]]*$/ { in_on = 1; next }
        /^[^[:space:]#]/    { in_on = 0 }

        !in_on { next }

        # A column-2 key is an event name: enter the one we were asked for,
        # and leave whichever we were in.
        /^  [^[:space:]]/ {
            in_event = ($0 ~ "^  " event ":[[:space:]]*$")
            in_key = 0
            next
        }

        !in_event { next }

        # A column-4 key under that event, likewise.
        /^    [^[:space:]]/ {
            in_key = ($0 ~ "^    " key ":[[:space:]]*$")
            next
        }

        # A column-6 list item under the key we want.
        in_key && /^      - / {
            line = $0
            sub(/^      - /, "", line)
            gsub(/^["'"'"']|["'"'"']$/, "", line)
            sub(/[[:space:]]+#.*$/, "", line)
            print line
        }
    ' "${file}"
}

# job_block <file> <job>
#
# Prints the body of one entry under the top-level `jobs:` key.
job_block() {
    local file=$1 job=$2
    awk -v job="${job}" '
        /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
        /^[^[:space:]#]/      { in_jobs = 0 }

        !in_jobs { next }

        /^  [^[:space:]]/ {
            in_job = ($0 ~ "^  " job ":[[:space:]]*$")
            next
        }

        in_job { print }
    ' "${file}"
}

# --- the parser is tested before it is trusted ------------------------------
#
# An extractor that silently returns nothing would make every assertion below
# pass vacuously, so both are run against a fixture whose answer is known.

fixture=$(mktemp)
trap 'rm -f "${fixture}"' EXIT
cat >"${fixture}" <<'FIXTURE'
---
name: Fixture
on:
  pull_request:
    branches:
      - main
    paths-ignore:
      - 'alpha.md'
      - 'beta/**'
  push:
    branches:
      - main
    paths-ignore:
      - 'gamma.md'
  workflow_dispatch:

jobs:
  first:
    name: First
    steps:
      - name: Marker
        run: ./first-marker.sh
  second:
    needs: first
    steps:
      - name: Marker
        run: ./second-marker.sh
FIXTURE

assert_eq "parser reads a two-item paths-ignore list" \
    "alpha.md beta/**" "$(event_paths "${fixture}" pull_request paths-ignore | tr '\n' ' ' | sed 's/ $//')"
assert_eq "parser keeps events separate" \
    "gamma.md" "$(event_paths "${fixture}" push paths-ignore | tr '\n' ' ' | sed 's/ $//')"
assert_eq "parser returns nothing for an absent key" \
    "" "$(event_paths "${fixture}" pull_request paths)"
assert_contains "parser reads a job body" \
    "$(job_block "${fixture}" first)" "./first-marker.sh"
assert_not_contains "parser stops at the next job" \
    "$(job_block "${fixture}" first)" "./second-marker.sh"
assert_contains "parser reads the second job" \
    "$(job_block "${fixture}" second)" "needs: first"

# --- 1. both workflows run the suite, with shellcheck installed first -------

check_runs_suite() {
    local label=$1 file=$2
    local block
    block=$(job_block "${file}" tests)

    if [[ -z "${block}" ]]; then
        _fail "${label} has a tests job" \
            "no 'tests:' job found under jobs: in ${file#"${REPO_ROOT}"/}" \
            "if the job was renamed, this test must be updated with it"
        return
    fi
    _pass "${label} has a tests job"

    assert_contains "${label} runs the shell suite" "${block}" "./tests/run-tests.sh"
    assert_contains "${label} installs shellcheck" "${block}" "apt-get install -y shellcheck"

    # Order matters: installing shellcheck after the suite has run would leave
    # test-shell-syntax.sh's shellcheck pass skipped, and skipping is silent.
    local install_line run_line
    install_line=$(grep -n 'apt-get install -y shellcheck' <<<"${block}" | head -1 | cut -d: -f1)
    run_line=$(grep -n './tests/run-tests.sh' <<<"${block}" | head -1 | cut -d: -f1)
    if [[ -n "${install_line}" && -n "${run_line}" && "${install_line}" -lt "${run_line}" ]]; then
        _pass "${label} installs shellcheck before running the suite"
    else
        _fail "${label} installs shellcheck before running the suite" \
            "install step at line ${install_line:-none}, suite at line ${run_line:-none} (job-relative)"
    fi
}

check_runs_suite "build.yml" "${BUILD_WF}"
check_runs_suite "coverage-gate.yml" "${COVERAGE_WF}"

# --- 2. a red suite still blocks the image build ----------------------------

build_push=$(job_block "${BUILD_WF}" build_push)
if [[ -z "${build_push}" ]]; then
    _fail "build.yml has a build_push job" "no 'build_push:' job found in build.yml"
else
    _pass "build.yml has a build_push job"
    assert_contains "build_push needs the tests job" "${build_push}" "needs: tests"
fi

# --- 3. every path build.yml ignores is covered by coverage-gate.yml --------
#
# Per event, because the two triggers do not ignore the same spellings.

for event in pull_request push; do
    ignored=$(event_paths "${BUILD_WF}" "${event}" paths-ignore)
    covered=$(event_paths "${COVERAGE_WF}" "${event}" paths)

    # GitHub evaluates path patterns in order, and a later '!' pattern removes
    # paths an earlier one matched. The membership check below cannot reason
    # about that: 'docs/**' followed by '!docs/private/**' would still satisfy
    # it while a docs/private-only change is claimed by neither workflow. So a
    # negation is refused outright rather than silently mis-read. If one is ever
    # wanted, this test has to evaluate the ordered set instead.
    if negated=$(grep -- '^!' <<<"${ignored}${covered:+$'\n'}${covered}"); then
        _fail "${event}: path filters use no '!' negation" \
            "found: ${negated//$'\n'/, }" \
            "order-dependent negation makes the membership check below unsound;" \
            "teach this test to evaluate the ordered pattern set before adding one"
        continue
    fi
    _pass "${event}: path filters use no '!' negation"

    if [[ -z "${ignored}" ]]; then
        _fail "build.yml declares paths-ignore on ${event}" \
            "extracted nothing; either the filter was removed (in which case the" \
            "suite now runs on every change and this test should be updated) or" \
            "the parser can no longer follow the file"
        continue
    fi
    _pass "build.yml declares paths-ignore on ${event}"

    if [[ -z "${covered}" ]]; then
        _fail "coverage-gate.yml declares paths on ${event}" \
            "extracted nothing; a docs-only ${event} would be verified by neither workflow"
        continue
    fi
    _pass "coverage-gate.yml declares paths on ${event}"

    # The trigger that makes the two workflows check each other. Without it a
    # pull request editing only build.yml is checked by the build.yml it edited
    # — a pull_request run executes the head branch's copy — so the assertions
    # above would never execute on the change that breaks them.
    if grep -qxF '.github/workflows/**' <<<"${covered}"; then
        _pass "${event}: coverage-gate.yml triggers on workflow changes"
    else
        _fail "${event}: coverage-gate.yml triggers on workflow changes" \
            "without '.github/workflows/**' in its ${event} paths, a pull request" \
            "that removes the suite from build.yml runs only the build.yml it just" \
            "edited, and nothing in this file executes"
    fi

    while IFS= read -r path; do
        [[ -z "${path}" ]] && continue
        if grep -qxF "${path}" <<<"${covered}"; then
            _pass "${event}: '${path}' is ignored by build.yml and picked up by coverage-gate.yml"
        else
            _fail "${event}: '${path}' is ignored by build.yml and picked up by coverage-gate.yml" \
                "build.yml skips it, coverage-gate.yml does not claim it," \
                "so a ${event} touching only that path runs no shell suite at all"
        fi
    done <<<"${ignored}"
done

# --- 4. status-badges.yml still skips pull requests -------------------------
#
# This is why build.yml's tests job exists at all: ci/write-badges.sh is
# executed by no other trigger on a pull request. If Status badges started
# running on PRs, the reasoning in build.yml's comment would be stale — and it
# must not start, because it pushes to the status branch.

badges=$(job_block "${BADGES_WF}" badges)
if [[ -z "${badges}" ]]; then
    _fail "status-badges.yml has a badges job" "no 'badges:' job found in status-badges.yml"
else
    _pass "status-badges.yml has a badges job"
    assert_contains "status-badges.yml still skips pull requests" \
        "${badges}" "github.event.workflow_run.event != 'pull_request'"
fi

finish
