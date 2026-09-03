#!/usr/bin/env bash
#
# Static checks over every shell script in the repository.
#
# `bash -n` is always run: it costs nothing and catches the class of typo that
# would otherwise only surface halfway through a 40-minute image build, or on
# the daily badge run where nobody is watching.
#
# The shellcheck pass runs when the tool is installed and is skipped otherwise,
# so the suite stays usable on a machine without it. Making it a hard
# requirement belongs in CI, not here.

set -uo pipefail

TEST_NAME="test-shell-syntax"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

scripts=()
while IFS= read -r file; do
    scripts+=("${file}")
done < <(
    find "${REPO_ROOT}" -path "${REPO_ROOT}/.git" -prune -o -name '*.sh' -type f -print | sort
)

if [[ "${#scripts[@]}" -eq 0 ]]; then
    _fail "found shell scripts to check" "no *.sh files under ${REPO_ROOT}"
    finish
    exit
fi

for script in "${scripts[@]}"; do
    rel="${script#"${REPO_ROOT}"/}"
    output="$(bash -n "${script}" 2>&1)"
    assert_eq "bash -n accepts ${rel}" "" "${output}"
done

# Every executed script needs an interpreter line; the Containerfile runs the
# build_files scripts by path, and the workflow runs ci/write-badges.sh by path.
for script in "${scripts[@]}"; do
    rel="${script#"${REPO_ROOT}"/}"
    [[ "${rel}" == tests/lib/* ]] && continue # sourced, never executed
    assert_contains "${rel} starts with a shebang" "$(head -1 "${script}")" "#!"
    if [[ -x "${script}" ]]; then
        _pass "${rel} is executable"
    else
        _fail "${rel} is executable" "chmod +x ${rel}"
    fi
done

if command -v shellcheck >/dev/null 2>&1; then
    for script in "${scripts[@]}"; do
        rel="${script#"${REPO_ROOT}"/}"
        output="$(cd "${REPO_ROOT}" && shellcheck -x "${rel}" 2>&1)"
        assert_eq "shellcheck is clean for ${rel}" "" "${output}"
    done
else
    printf '  skip shellcheck (not installed)\n'
fi

finish
