# Assertion helpers shared by the tests/test-*.sh files.
#
# Sourced, never executed. Each assertion increments a counter and prints one
# line; a failure records the reason and keeps going, so a single run reports
# every broken expectation rather than only the first.

TESTS_RUN=0
TESTS_FAILED=0

_pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    printf '  ok   %s\n' "$1"
}

_fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL %s\n' "$1"
    shift
    local detail
    for detail in "$@"; do
        printf '       %s\n' "${detail}"
    done
}

assert_eq() {
    local description=$1 expected=$2 actual=$3
    if [[ "${expected}" == "${actual}" ]]; then
        _pass "${description}"
    else
        _fail "${description}" "expected: ${expected}" "actual:   ${actual}"
    fi
}

assert_contains() {
    local description=$1 haystack=$2 needle=$3
    if [[ "${haystack}" == *"${needle}"* ]]; then
        _pass "${description}"
    else
        _fail "${description}" "expected to contain: ${needle}" "actual: ${haystack}"
    fi
}

assert_not_contains() {
    local description=$1 haystack=$2 needle=$3
    if [[ "${haystack}" != *"${needle}"* ]]; then
        _pass "${description}"
    else
        _fail "${description}" "expected NOT to contain: ${needle}" "actual: ${haystack}"
    fi
}

assert_file_exists() {
    local description=$1 path=$2
    if [[ -f "${path}" ]]; then
        _pass "${description}"
    else
        _fail "${description}" "no such file: ${path}"
    fi
}

assert_file_missing() {
    local description=$1 path=$2
    if [[ ! -e "${path}" ]]; then
        _pass "${description}"
    else
        _fail "${description}" "file should not exist: ${path}"
    fi
}

# Report the assertion tally to the runner. Sourced test files call this last.
finish() {
    printf '%s: %d assertion(s), %d failure(s)\n' "${TEST_NAME:-test}" "${TESTS_RUN}" "${TESTS_FAILED}"
    [[ "${TESTS_FAILED}" -eq 0 ]]
}
