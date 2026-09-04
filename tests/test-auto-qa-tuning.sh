#!/usr/bin/env bash
#
# Keeps .github/auto-qa-tuning.json and .github/workflows/ in step.
#
# The manifest is the declared source of truth for this repo's CI timeouts, and
# auto-qa.yml compares each entry against the slowest recent run so a job
# growing into its cap is reported before it starts dying there. That mechanism
# has two blind spots, and neither one fails anything on its own:
#
#   1. A job absent from the manifest is never sampled. Nothing goes red -- the
#      workflow reads the list, not the YAML -- so the job is simply unwatched,
#      and looks the same as one somebody decided not to watch.
#   2. A timeout_minutes that no longer matches the YAML makes every verdict
#      wrong in a direction nobody can see. auto-qa.yml says so itself: "The
#      workflow reports a mismatch it cannot see; it reads the numbers here, not
#      the YAML."
#
# Both are silent, which is what makes them worth a test rather than a comment.
# The manifest already carried that comment; status-badges.yml still shipped for
# months with no timeout-minutes at all and no entry here (issue #94).
#
# So, in both directions:
#
#   * every job in every workflow declares a timeout-minutes      (no 360m default)
#   * every job appears in exactly one of `jobs` or `untracked`   (a decision exists)
#   * every `untracked` entry gives a reason                      (and says why)
#   * every `jobs` entry names a job that exists                  (stale after a rename)
#   * every `jobs` entry's timeout_minutes equals the YAML's      (the drift above)
#
# `untracked` is the same idiom as test-coverage.sh's UNCOVERED: not-watched is
# a legitimate answer, but it has to be an answer. It lives in the JSON rather
# than in this file because it is a statement about the manifest, and the person
# adding a workflow job should meet it where the timeouts already are.
#
# The YAML is read with an indentation-anchored parser, matching
# test-ci-workflows.sh and for the same reason -- CONTRIBUTING.md asks for a
# conversation before a new dependency, and the structure needed here is two
# levels deep. The failure mode of hand-parsing is silent under-extraction, so
# the parser is run against a fixture with a known answer before it is trusted
# against the real files, and a workflow that yields no jobs at all is a failure
# rather than a vacuous pass.

set -uo pipefail

TEST_NAME="test-auto-qa-tuning"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

CONFIG="${REPO_ROOT}/.github/auto-qa-tuning.json"
WORKFLOW_DIR="${REPO_ROOT}/.github/workflows"

# --- parser -----------------------------------------------------------------

# workflow_jobs <file>
#
# Prints "<job id><TAB><job name><TAB><timeout-minutes>" for every entry under
# the top-level `jobs:` key. A job with no `name:` prints its id, which is what
# the Actions API reports for it; a job with no `timeout-minutes:` prints the
# literal NONE.
#
# Anchored on exact columns: a job id sits at column 2, and its own keys at
# column 4. That is what separates a job's `name:` from a *step's* -- steps are
# a column-4 `steps:` key whose items begin at column 6, so every key inside one
# is at column 8 or deeper and cannot be mistaken for the job's.
workflow_jobs() {
    local file=$1
    awk '
        /^[[:space:]]*#/      { next }
        /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
        /^[^[:space:]#]/      { in_jobs = 0 }
        !in_jobs { next }

        /^  [^[:space:]]/ {
            id = $0
            sub(/:[[:space:]]*$/, "", id)
            sub(/^  /, "", id)
            n++
            ids[n] = id
            names[n] = ""
            timeouts[n] = "NONE"
            next
        }

        n == 0 { next }

        /^    name:[[:space:]]*/ {
            v = $0
            sub(/^    name:[[:space:]]*/, "", v)
            gsub(/^["\047]|["\047]$/, "", v)
            names[n] = v
            next
        }

        /^    timeout-minutes:[[:space:]]*/ {
            v = $0
            sub(/^    timeout-minutes:[[:space:]]*/, "", v)
            sub(/[[:space:]]*#.*$/, "", v)
            timeouts[n] = v
            next
        }

        END {
            for (i = 1; i <= n; i++) {
                printf "%s\t%s\t%s\n", ids[i], (names[i] == "" ? ids[i] : names[i]), timeouts[i]
            }
        }
    ' "${file}"
}

# --- the parser is tested before it is trusted ------------------------------

fixture=$(mktemp)
trap 'rm -f "${fixture}"' EXIT
cat >"${fixture}" <<'FIXTURE'
---
name: Fixture
on:
  workflow_dispatch:

jobs:
  alpha:
    name: Named Alpha
    runs-on: ubuntu-24.04
    timeout-minutes: 7
    env:
      name: not-the-job-name
    steps:
      - name: A step, not the job
        timeout-minutes: 999
        run: echo hi
  beta:
    runs-on: ubuntu-24.04
    steps:
      - name: Another step
        run: echo hi
FIXTURE

fixture_jobs=$(workflow_jobs "${fixture}")
assert_eq "parser reads a job's name and timeout" \
    "alpha	Named Alpha	7" "$(grep '^alpha	' <<<"${fixture_jobs}")"
assert_eq "parser falls back to the job id, and reports a missing timeout" \
    "beta	beta	NONE" "$(grep '^beta	' <<<"${fixture_jobs}")"
assert_eq "parser reads exactly the two jobs" 2 "$(wc -l <<<"${fixture_jobs}")"

# --- the manifest itself parses ---------------------------------------------

if jq -e . "${CONFIG}" >/dev/null 2>&1; then
    _pass "auto-qa-tuning.json is valid JSON"
else
    _fail "auto-qa-tuning.json is valid JSON" "jq could not parse ${CONFIG}"
    finish
    exit
fi

# workflow <TAB> job name, for each list.
tracked=$(jq -r '.jobs[] | [.workflow, .job] | @tsv' "${CONFIG}")
untracked=$(jq -r '.untracked[]? | [.workflow, .job] | @tsv' "${CONFIG}")

if [[ -z "${tracked}" ]]; then
    _fail "the manifest declares at least one tracked job" \
        "jobs[] is empty; every assertion below would pass vacuously"
    finish
    exit
fi

# --- 1. every job in every workflow is bounded, and has a decision ----------

workflows=()
while IFS= read -r file; do
    workflows+=("${file}")
done < <(find "${WORKFLOW_DIR}" -maxdepth 1 -name '*.yml' -type f | sort)

if [[ "${#workflows[@]}" -eq 0 ]]; then
    _fail "found workflow files to check" "no *.yml under ${WORKFLOW_DIR}"
    finish
    exit
fi

for file in "${workflows[@]}"; do
    wf=$(basename "${file}")
    jobs=$(workflow_jobs "${file}")

    if [[ -z "${jobs}" ]]; then
        _fail "${wf}: parser found its jobs" \
            "no jobs extracted; a reformat the parser cannot follow would" \
            "silently exempt this file from every assertion below"
        continue
    fi

    while IFS=$'\t' read -r id name timeout; do
        [[ -z "${id}" ]] && continue

        # A job with no timeout-minutes inherits GitHub's 360-minute default,
        # which is not a budget anyone chose.
        if [[ "${timeout}" == "NONE" ]]; then
            _fail "${wf}: ${id} declares a timeout-minutes" \
                "no timeout-minutes on the job; it inherits the 360-minute default"
        else
            _pass "${wf}: ${id} declares a timeout-minutes (${timeout}m)"
        fi

        local_key="${wf}	${name}"
        in_tracked=0
        in_untracked=0
        grep -qxF "${local_key}" <<<"${tracked}" && in_tracked=1
        grep -qxF "${local_key}" <<<"${untracked}" && in_untracked=1

        if [[ $((in_tracked + in_untracked)) -eq 1 ]]; then
            _pass "${wf}: ${name} has a recorded tuning decision"
        elif [[ $((in_tracked + in_untracked)) -eq 0 ]]; then
            _fail "${wf}: ${name} has a recorded tuning decision" \
                "add it to jobs[] in .github/auto-qa-tuning.json so auto-qa.yml samples it," \
                "or to untracked[] with the reason it should not be"
        else
            _fail "${wf}: ${name} has a recorded tuning decision" \
                "it appears in both jobs[] and untracked[]; it can only be one"
        fi
    done <<<"${jobs}"
done

# --- 2. and every entry still refers to a job that exists, at its timeout ----

while IFS=$'\t' read -r wf job timeout_minutes; do
    [[ -z "${wf}" ]] && continue

    if [[ ! -f "${WORKFLOW_DIR}/${wf}" ]]; then
        _fail "tracked entry ${wf} / ${job} names a workflow that exists" \
            "no such file: .github/workflows/${wf}"
        continue
    fi

    actual=$(workflow_jobs "${WORKFLOW_DIR}/${wf}" | awk -F'\t' -v job="${job}" '$2 == job { print $3 }')

    if [[ -z "${actual}" ]]; then
        _fail "tracked entry ${wf} / ${job} names a job that exists" \
            "no job named that in ${wf}; auto-qa.yml matches on the job *name*," \
            "so a rename leaves it silently sampling nothing"
        continue
    fi
    _pass "tracked entry ${wf} / ${job} names a job that exists"

    # The mismatch auto-qa.yml cannot see: it compares observed durations
    # against the number here, never against the YAML.
    assert_eq "${wf} / ${job}: declared timeout matches the workflow" \
        "${actual}" "${timeout_minutes}"
done < <(jq -r '.jobs[] | [.workflow, .job, .timeout_minutes] | @tsv' "${CONFIG}")

while IFS=$'\t' read -r wf job reason; do
    [[ -z "${wf}" ]] && continue

    if [[ ! -f "${WORKFLOW_DIR}/${wf}" ]]; then
        _fail "untracked entry ${wf} / ${job} names a workflow that exists" \
            "no such file: .github/workflows/${wf}"
        continue
    fi

    if workflow_jobs "${WORKFLOW_DIR}/${wf}" | awk -F'\t' -v job="${job}" '$2 == job { found = 1 } END { exit !found }'; then
        _pass "untracked entry ${wf} / ${job} names a job that exists"
    else
        _fail "untracked entry ${wf} / ${job} names a job that exists" \
            "no job named that in ${wf}; remove the stale entry"
        continue
    fi

    if [[ -n "${reason// /}" ]]; then
        _pass "untracked entry ${wf} / ${job} says why it is not sampled"
    else
        _fail "untracked entry ${wf} / ${job} says why it is not sampled" \
            "an untracked entry must carry a non-empty reason"
    fi
done < <(jq -r '.untracked[]? | [.workflow, .job, .reason // ""] | @tsv' "${CONFIG}")

# --- 3. the policy auto-qa.yml reads is present and usable ------------------

for key in sample_size at_risk_ratio loose_ratio statistic; do
    value=$(jq -r --arg k "${key}" '.policy[$k] // empty' "${CONFIG}")
    if [[ -n "${value}" ]]; then
        _pass "policy.${key} is set (${value})"
    else
        _fail "policy.${key} is set" \
            "auto-qa.yml reads it unconditionally; an absent key makes every" \
            "comparison in that workflow run against an empty string"
    fi
done

finish
