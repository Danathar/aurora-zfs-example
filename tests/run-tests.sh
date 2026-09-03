#!/usr/bin/env bash
#
# Runs every tests/test-*.sh and exits non-zero if any of them fails.
#
#   ./tests/run-tests.sh                   # all tests
#   ./tests/run-tests.sh test-write-badges # one test, by name or path
#
# Requirements: bash 4+, jq, coreutils date. No test framework to install; the
# scripts under test are shell, so the tests are shell.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

missing=()
for tool in bash jq date sed; do
    command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
done
if [[ "${#missing[@]}" -gt 0 ]]; then
    printf 'run-tests: missing required tool(s): %s\n' "${missing[*]}" >&2
    exit 1
fi

files=()
if [[ "$#" -gt 0 ]]; then
    for arg in "$@"; do
        if [[ -f "${arg}" ]]; then
            files+=("${arg}")
        elif [[ -f "${TEST_DIR}/${arg}" ]]; then
            files+=("${TEST_DIR}/${arg}")
        elif [[ -f "${TEST_DIR}/${arg}.sh" ]]; then
            files+=("${TEST_DIR}/${arg}.sh")
        else
            printf 'run-tests: no such test: %s\n' "${arg}" >&2
            exit 1
        fi
    done
else
    while IFS= read -r file; do
        files+=("${file}")
    done < <(find "${TEST_DIR}" -maxdepth 1 -name 'test-*.sh' -type f | sort)
fi

if [[ "${#files[@]}" -eq 0 ]]; then
    printf 'run-tests: no tests found in %s\n' "${TEST_DIR}" >&2
    exit 1
fi

failed=()
for file in "${files[@]}"; do
    printf '\n== %s\n' "$(basename "${file}")"
    if ! bash "${file}"; then
        failed+=("$(basename "${file}")")
    fi
done

printf '\n'
if [[ "${#failed[@]}" -gt 0 ]]; then
    printf 'FAILED: %s\n' "${failed[*]}"
    exit 1
fi
printf 'All %d test file(s) passed.\n' "${#files[@]}"
