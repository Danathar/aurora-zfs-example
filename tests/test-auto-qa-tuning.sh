#!/usr/bin/env bash
#
# Keeps .github/auto-qa-tuning.json and .github/workflows/ describing the same
# repository.
#
# auto-qa.yml compares each declared timeout against the slowest recent run, so
# a job growing into its cap is reported before it starts dying there. That
# mechanism has two blind spots, and both are silent:
#
#   1. It reads the numbers in the manifest, not the YAML. The manifest file
#      says so itself ("The workflow reports a mismatch it cannot see"). Raise
#      `timeout-minutes` in a workflow and leave the manifest behind, and
#      auto-qa keeps measuring against a cap that no longer exists — it reports
#      "ok" on a job at 80% of its real timeout, or fails on one that is fine.
#   2. It iterates `.jobs[]`. A job that is absent from that list is never
#      sampled, so nothing compares it against anything. Absence produces no
#      output at all, which is indistinguishable from a healthy job.
#
# So both directions are checked here, the same way tests/test-coverage.sh
# checks its own manifest:
#
#   * a manifest entry naming a workflow or job that does not exist fails
#   * a manifest timeout that disagrees with the YAML fails
#   * a job in .github/workflows/ that is in neither the manifest nor the
#     UNTRACKED list below fails
#   * a job declaring no `timeout-minutes:` that is not in NO_TIMEOUT fails
#
# The two lists are the same idiom as test-coverage.sh's UNCOVERED: a gap is
# allowed, but it has to be written down with its reason rather than arrived at
# by absence. They are also checked for rot in the other direction — an entry
# whose job has since gained a timeout, or has since been added to the
# manifest, fails and asks to be removed. That is what makes this test useful
# for the case it was written for: it cannot add a `timeout-minutes:` to
# status-badges.yml itself, because a change under .github/workflows/ needs a
# maintainer, but the moment one lands the anti-rot check goes red and asks for
# the entry to be moved into the manifest.
#
# The YAML is read with an indentation-anchored parser rather than a real one,
# for the reason tests/test-ci-workflows.sh gives: CONTRIBUTING.md asks for a
# conversation before adding a dependency, and the structure needed here is two
# levels deep. The risk of hand-parsing is silent under-extraction — a
# reformat the parser cannot follow yields nothing, and an assertion over
# nothing passes — so the parser is exercised against a fixture with a known
# answer first, and every real extraction is checked for emptiness.
#
# Job identity here is the *display* name (`name:`), not the YAML key, because
# that is what auto-qa.yml matches against: it selects `.jobs[] | select(.name
# == $job)` from the API. A job with no `name:` is reported by the API under
# its key, so the parser falls back to the key.

set -uo pipefail

TEST_NAME="test-auto-qa-tuning"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

CONFIG="${REPO_ROOT}/.github/auto-qa-tuning.json"
WORKFLOW_DIR="${REPO_ROOT}/.github/workflows"

# workflow file <TAB> job display name <TAB> reason.
#
# Jobs that declare no timeout-minutes: at all, and so inherit GitHub's
# 360-minute default.
NO_TIMEOUT=$(
    cat <<'EOF'
status-badges.yml	Publish status badges	Declares no timeout-minutes, so it inherits the 360-minute default. Its work is two skopeo inspects and a git push, and it holds contents: write; a hung registry call occupies a write-capable runner until the cap. Adding the number is a maintainer change under .github/workflows/ — see issue #94, which proposes 15 to match nightly-compliance.yml's Published image job.
EOF
)

# workflow file <TAB> job display name <TAB> reason.
#
# Jobs deliberately outside the duration manifest, and therefore never sampled
# by auto-qa.yml.
UNTRACKED=$(
    cat <<'EOF'
ai-fix.yml	Check credentials and target	Bounded at 5 minutes and does no work that grows: it checks credentials and resolves a target. Nothing here tracks an upstream that moves on its own, which is the drift auto-qa.yml exists to catch.
ai-fix.yml	Run the agent	Bounded at 30 minutes, but its duration is set by the model rather than by code in this repository. Sampling it would report movement that no change here caused and no change here can fix.
auto-qa.yml	Compare timeouts against observed durations	Bounded at 10 minutes. This is the comparison job itself; its duration tracks the number of manifest entries and the GitHub API, not this repository's build.
status-badges.yml	Publish status badges	Absent from the manifest as well as from the YAML, so auto-qa.yml neither samples it nor has a number to compare against. Both halves are issue #94; the manifest entry should land with the timeout.
EOF
)

# --- parser -----------------------------------------------------------------
#
# One extractor. Workflows are written with two-space indents, so a job key
# sits at column 2 under the top-level `jobs:` and its scalar keys at column 4.
# Step names live at column 6 or deeper and are not job names.

# workflow_jobs <file>
#
# Prints one line per job: key <TAB> display name <TAB> timeout-minutes.
# The display name falls back to the key when no `name:` is declared, matching
# what the Actions API reports. The timeout field is empty when the job
# declares none.
workflow_jobs() {
    local file=$1
    awk '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }

        # The scalar after the first colon, unquoted. A "#" starts a comment
        # only outside quotes and only after whitespace, so the unquoted branch
        # strips it and the quoted branches do not.
        function value(line,   v) {
            sub(/^[^:]*:/, "", line)
            v = trim(line)
            if (v ~ /^"/) {
                sub(/^"/, "", v)
                sub(/".*$/, "", v)
            } else if (v ~ /^\047/) {
                sub(/^\047/, "", v)
                sub(/\047.*$/, "", v)
            } else {
                sub(/[[:space:]]+#.*$/, "", v)
                v = trim(v)
            }
            return v
        }

        function emit() {
            if (job != "") {
                printf "%s\t%s\t%s\n", job, (name != "" ? name : job), timeout
            }
            job = ""; name = ""; timeout = ""
        }

        # YAML ignores comment indentation, so a comment must never be read as
        # a structural key.
        /^[[:space:]]*#/      { next }
        /^jobs:[[:space:]]*$/ { emit(); in_jobs = 1; next }
        /^[^[:space:]#]/      { emit(); in_jobs = 0; next }

        !in_jobs { next }

        # A column-2 key under jobs: is a job.
        /^  [^[:space:]]/ {
            emit()
            job = $0
            sub(/^  /, "", job)
            sub(/:[[:space:]]*$/, "", job)
            gsub(/["\047]/, "", job)
            next
        }

        job == "" { next }

        /^    ["\047]?name["\047]?[[:space:]]*:/            { name = value($0); next }
        /^    ["\047]?timeout-minutes["\047]?[[:space:]]*:/ { timeout = value($0); next }

        END { emit() }
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
  first:
    name: First job  # trailing comment
    runs-on: ubuntu-24.04
    timeout-minutes: 7
    steps:
      - name: Not a job name
        run: ./marker.sh
  second:
    runs-on: ubuntu-24.04
    steps:
      - name: Also not a job name
        timeout-minutes: 99
        run: ./marker.sh
  third:
    name: "Third job"
    timeout-minutes: 11
    steps:
      - run: ./marker.sh
FIXTURE

assert_eq "parser reads name and timeout, ignoring a trailing comment" \
    "first|First job|7" "$(workflow_jobs "${fixture}" | awk -F'\t' '$1=="first"{print $1"|"$2"|"$3}')"
assert_eq "parser falls back to the job key and reports no timeout" \
    "second|second|" "$(workflow_jobs "${fixture}" | awk -F'\t' '$1=="second"{print $1"|"$2"|"$3}')"
assert_eq "parser unquotes a quoted job name" \
    "third|Third job|11" "$(workflow_jobs "${fixture}" | awk -F'\t' '$1=="third"{print $1"|"$2"|"$3}')"
assert_eq "parser reads step names as neither jobs nor job timeouts" \
    "3" "$(workflow_jobs "${fixture}" | wc -l | tr -d ' ')"

# The parser is only half of it: the loop below reads these lines with a tab
# IFS, which collapses runs of delimiters. A job with no timeout produces a
# trailing empty field, and the same shape read one field wider would report
# the *next* column as its timeout — silently turning "no bound at all" into a
# pass. So the read path is exercised here, not just the extraction.
missing_timeout=""
while IFS=$'\t' read -r key name timeout; do
    [[ "${key}" == "second" ]] && missing_timeout="name=${name} timeout=${timeout}"
done < <(workflow_jobs "${fixture}")
assert_eq "a job with no timeout survives the tab-separated read as empty" \
    "name=second timeout=" "${missing_timeout}"

# --- the manifest is readable and its policy is intact ----------------------

assert_file_exists "the duration manifest exists" "${CONFIG}"
if [[ ! -f "${CONFIG}" ]]; then
    finish
    exit
fi

if jq -e . "${CONFIG}" >/dev/null 2>&1; then
    _pass "the duration manifest is valid JSON"
else
    _fail "the duration manifest is valid JSON" \
        "jq could not parse ${CONFIG#"${REPO_ROOT}"/}; auto-qa.yml reads it with jq and would fail at the first call"
    finish
    exit
fi

# auto-qa.yml reads all three of these before it samples anything. A missing or
# non-numeric one makes the comparison silently meaningless rather than loud.
for key in sample_size at_risk_ratio loose_ratio; do
    value=$(jq -r --arg k "${key}" '.policy[$k] // empty' "${CONFIG}")
    if [[ -n "${value}" ]] && awk -v v="${value}" 'BEGIN { exit !(v + 0 > 0) }'; then
        _pass "policy.${key} is a positive number"
    else
        _fail "policy.${key} is a positive number" \
            "found: ${value:-<absent>}" \
            "auto-qa.yml reads it into a shell arithmetic or awk comparison"
    fi
done

at_risk=$(jq -r '.policy.at_risk_ratio // empty' "${CONFIG}")
loose=$(jq -r '.policy.loose_ratio // empty' "${CONFIG}")
if [[ -n "${at_risk}" && -n "${loose}" ]] &&
    awk -v a="${at_risk}" -v l="${loose}" 'BEGIN { exit !(l + 0 < a + 0 && a + 0 <= 1) }'; then
    _pass "loose_ratio is below at_risk_ratio, which is at most 1"
else
    _fail "loose_ratio is below at_risk_ratio, which is at most 1" \
        "at_risk_ratio=${at_risk:-<absent>}, loose_ratio=${loose:-<absent>}" \
        "auto-qa.yml tests at_risk first and loose second; overlapping ratios make" \
        "the advisory verdict unreachable, or an at-risk job report as loose"
fi

manifest=$(jq -r '.jobs[] | [.workflow, .job, (.timeout_minutes | tostring)] | @tsv' "${CONFIG}")
if [[ -z "${manifest}" ]]; then
    _fail "the manifest lists at least one job" \
        "'.jobs[]' extracted nothing; auto-qa.yml would sample nothing and report success"
    finish
    exit
fi
_pass "the manifest lists at least one job"

manifest_keys=$(cut -f1,2 <<<"${manifest}")
duplicates=$(sort <<<"${manifest_keys}" | uniq -d)
if [[ -z "${duplicates}" ]]; then
    _pass "no workflow/job pair is listed twice"
else
    _fail "no workflow/job pair is listed twice" \
        "duplicated: ${duplicates//$'\n'/, }" \
        "auto-qa.yml would sample it twice and report two rows for one job"
fi

# --- every workflow parses, and its jobs are collected ----------------------

all_jobs=""
parse_failed=0
while IFS= read -r path; do
    [[ -z "${path}" ]] && continue
    file=$(basename "${path}")
    jobs=$(workflow_jobs "${path}")
    if [[ -z "${jobs}" ]]; then
        _fail "${file}: jobs are readable" \
            "extracted no jobs at all; either the file declares none (in which case" \
            "remove it) or the parser can no longer follow its indentation"
        parse_failed=1
        continue
    fi
    _pass "${file}: jobs are readable"
    # The timeout stays the last field on every line here and in the two lists
    # below, and no earlier field is ever empty. `read` with a whitespace IFS
    # collapses runs of delimiters, so a middle field that can be empty would
    # shift every field after it — the timeout of a job that declares none
    # would arrive as the value of the next column.
    while IFS=$'\t' read -r key name timeout; do
        all_jobs+="${file}"$'\t'"${name}"$'\t'"${timeout}"$'\n'
    done <<<"${jobs}"
done < <(find "${WORKFLOW_DIR}" -maxdepth 1 -name '*.yml' -type f | sort)

if [[ -z "${all_jobs}" ]]; then
    _fail "the workflow directory contains jobs" \
        "found no jobs under ${WORKFLOW_DIR#"${REPO_ROOT}"/}"
    finish
    exit
fi
all_jobs=${all_jobs%$'\n'}

job_pairs=$(cut -f1,2 <<<"${all_jobs}")

# job_timeout <workflow file> <display name>
#
# Prints the declared timeout, or nothing. Exit status distinguishes a job that
# does not exist (1) from one that exists with no timeout (0, empty output).
job_timeout() {
    local wf=$1 name=$2
    awk -F'\t' -v wf="${wf}" -v name="${name}" '
        $1 == wf && $2 == name { print $3; found = 1 }
        END { exit !found }
    ' <<<"${all_jobs}"
}

# --- direction 1: every manifest entry still names a real job, with the
# ---              number the YAML actually declares --------------------------

while IFS=$'\t' read -r wf job timeout_min; do
    [[ -z "${wf}" ]] && continue

    if [[ ! -f "${WORKFLOW_DIR}/${wf}" ]]; then
        _fail "manifest entry ${wf} / ${job} names an existing workflow" \
            "no such file under .github/workflows/" \
            "auto-qa.yml requests runs for this workflow by filename and would sample nothing"
        continue
    fi
    _pass "manifest entry ${wf} / ${job} names an existing workflow"

    if ! declared=$(job_timeout "${wf}" "${job}"); then
        _fail "manifest entry ${wf} / ${job} names an existing job" \
            "no job with that display name in ${wf}" \
            "auto-qa.yml matches the API's job .name; a renamed job is sampled as nothing" \
            "and reported as '_no successful runs sampled_' rather than as an error"
        continue
    fi
    _pass "manifest entry ${wf} / ${job} names an existing job"

    if [[ -z "${declared}" ]]; then
        _fail "${wf} / ${job}: the YAML declares the manifest's timeout" \
            "the manifest says ${timeout_min}m; the job declares no timeout-minutes at all" \
            "so the real cap is GitHub's 360-minute default and the comparison is against a number nothing enforces"
    elif [[ "${declared}" == "${timeout_min}" ]]; then
        _pass "${wf} / ${job}: the YAML declares the manifest's timeout"
    else
        _fail "${wf} / ${job}: the YAML declares the manifest's timeout" \
            "manifest: ${timeout_min}m, workflow: ${declared}m" \
            "auto-qa.yml compares observed durations against the manifest number," \
            "so it measures a cap that is not the one enforcing anything"
    fi
done <<<"${manifest}"

# --- direction 2: every job is either tracked, or listed with a reason -------

no_timeout_keys=$(cut -f1,2 <<<"${NO_TIMEOUT}")
untracked_keys=$(cut -f1,2 <<<"${UNTRACKED}")

while IFS=$'\t' read -r wf name timeout; do
    [[ -z "${wf}" ]] && continue
    pair="${wf}"$'\t'"${name}"

    if [[ -n "${timeout}" ]]; then
        _pass "${wf} / ${name}: declares a timeout-minutes"
    elif grep -qxF "${pair}" <<<"${no_timeout_keys}"; then
        _pass "${wf} / ${name}: declares no timeout, and says why in NO_TIMEOUT"
    else
        _fail "${wf} / ${name}: declares a timeout-minutes" \
            "the job inherits GitHub's 360-minute default" \
            "add timeout-minutes: to the job, or add it to NO_TIMEOUT in this file with the reason"
    fi

    if grep -qxF "${pair}" <<<"${manifest_keys}"; then
        _pass "${wf} / ${name}: is sampled by auto-qa.yml"
    elif grep -qxF "${pair}" <<<"${untracked_keys}"; then
        _pass "${wf} / ${name}: is outside the manifest, and says why in UNTRACKED"
    else
        _fail "${wf} / ${name}: is sampled by auto-qa.yml" \
            "the job is in neither .github/auto-qa-tuning.json nor UNTRACKED in this file," \
            "so its timeout is compared against nothing and its drift is reported nowhere"
    fi
done <<<"${all_jobs}"

# --- and the two lists cannot rot -------------------------------------------
#
# Without this, a NO_TIMEOUT entry survives the change that fixes it: the job
# gains a timeout, the entry keeps excusing a gap that closed, and the number
# never reaches the manifest.

while IFS=$'\t' read -r wf name reason; do
    [[ -z "${wf}" ]] && continue

    if ! declared=$(job_timeout "${wf}" "${name}"); then
        _fail "NO_TIMEOUT entry ${wf} / ${name} still exists" \
            "no job with that display name in ${wf}; remove the stale entry"
        continue
    fi
    _pass "NO_TIMEOUT entry ${wf} / ${name} still exists"

    if [[ -n "${declared}" ]]; then
        _fail "NO_TIMEOUT entry ${wf} / ${name} still has no timeout" \
            "the job now declares timeout-minutes: ${declared}" \
            "drop this entry, and add the job to .github/auto-qa-tuning.json with the same number"
    else
        _pass "NO_TIMEOUT entry ${wf} / ${name} still has no timeout"
    fi

    if [[ -n "${reason// /}" ]]; then
        _pass "NO_TIMEOUT entry ${wf} / ${name} states a reason"
    else
        _fail "NO_TIMEOUT entry ${wf} / ${name} states a reason" \
            "an entry that excuses a missing bound must say why"
    fi
done <<<"${NO_TIMEOUT}"

while IFS=$'\t' read -r wf name reason; do
    [[ -z "${wf}" ]] && continue
    pair="${wf}"$'\t'"${name}"

    if grep -qxF "${pair}" <<<"${job_pairs}"; then
        _pass "UNTRACKED entry ${wf} / ${name} still exists"
    else
        _fail "UNTRACKED entry ${wf} / ${name} still exists" \
            "no job with that display name in ${wf}; remove the stale entry"
        continue
    fi

    if grep -qxF "${pair}" <<<"${manifest_keys}"; then
        _fail "UNTRACKED entry ${wf} / ${name} is still outside the manifest" \
            "the job is now listed in .github/auto-qa-tuning.json; remove this entry," \
            "which now excuses a gap that no longer exists"
    else
        _pass "UNTRACKED entry ${wf} / ${name} is still outside the manifest"
    fi

    if [[ -n "${reason// /}" ]]; then
        _pass "UNTRACKED entry ${wf} / ${name} states a reason"
    else
        _fail "UNTRACKED entry ${wf} / ${name} states a reason" \
            "an entry that excuses an unsampled job must say why"
    fi
done <<<"${UNTRACKED}"

# --- auto-qa.yml still reads the file this test polices ---------------------
#
# Every assertion above is about a manifest that matters only because one
# workflow reads it. Point auto-qa.yml at another path, or drop the jq call
# that iterates .jobs[], and all of it keeps passing over a file nothing uses.

AUTO_QA="${WORKFLOW_DIR}/auto-qa.yml"
if [[ ! -f "${AUTO_QA}" ]]; then
    _fail "auto-qa.yml exists" "the workflow that reads this manifest is gone; so is the reason for the manifest"
else
    assert_contains "auto-qa.yml reads .github/auto-qa-tuning.json" \
        "$(cat "${AUTO_QA}")" "CONFIG: .github/auto-qa-tuning.json"
    assert_contains "auto-qa.yml iterates the manifest's jobs" \
        "$(cat "${AUTO_QA}")" '.jobs[] | [.workflow, .job, .timeout_minutes] | @tsv'
fi

if [[ "${parse_failed}" -eq 1 ]]; then
    printf '  note: at least one workflow yielded no jobs; assertions about it did not run\n'
fi

finish
