#!/usr/bin/env bash
#
# Asserts that every repo path the docs name actually exists.
#
# README.md's "Repository Layout" block and the inline path references scattered
# through it and AGENTS.md are load-bearing: AGENTS.md tells an agent
# mid-incident to trust them. They drifted before — the layout block advertised
# `.github/renovate.json5` while the file was `renovate.json` at the repo root,
# and nothing failed — so this test makes that a red suite instead of a reader's
# problem.
#
# Two passes, because the two kinds of reference fail differently:
#
#   1. the layout block, where the first field of every line is a path, and
#   2. inline `code spans`, filtered down to the ones that look like repo paths.
#
# The filter for (2) is deliberately conservative. A span only has to exist if
# it is unambiguously a path into this repo: no absolute paths (those are inside
# the built image, e.g. /usr/lib/modules), no registry references, no globs.
# A missed reference is a gap; a false positive would make the suite lie.

set -uo pipefail

TEST_NAME="test-docs-paths"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/assert.sh
source "${TEST_DIR}/lib/assert.sh"

# A path may be a file or a directory; the layout block lists both.
assert_path_exists() {
    local description=$1 path=$2
    if [[ -e "${REPO_ROOT}/${path}" ]]; then
        _pass "${description}"
    else
        _fail "${description}" "no such path in repo: ${path}"
    fi
}

# --- 1. README.md "Repository Layout" block ---------------------------------
#
# Bounded by the ```text fence that follows the heading. Each line is
# "<path><spaces><description>", so the first field is the path.

layout=$(
    awk '
        /^## Repository Layout$/ { in_section = 1; next }
        in_section && /^```/     { fence++; next }
        in_section && fence == 1 { print }
        fence == 2               { exit }
    ' "${REPO_ROOT}/README.md"
)

if [[ -z "${layout}" ]]; then
    _fail "README.md has a Repository Layout block" \
        "no fenced block found under the '## Repository Layout' heading"
else
    _pass "README.md has a Repository Layout block"
    while IFS= read -r line; do
        [[ -z "${line// }" ]] && continue
        path="${line%% *}"
        # Directory entries are written with a trailing slash.
        assert_path_exists "layout entry exists: ${path}" "${path%/}"
    done <<<"${layout}"
fi

# --- 2. inline code spans in README.md and AGENTS.md ------------------------
#
# Anchored on what the repo actually contains, which is what keeps the filter
# from firing on things that merely look like paths:
#
#   * a span with a separator is checked only when its first segment is a
#     real top-level entry here. That admits `.github/workflows/build.yml` and
#     would have caught `.github/renovate.json5`, while skipping the GitHub
#     org/repo references (`ublue-os/akmods`, `coreos/chunkah`) that share the
#     same shape.
#   * a span without one is matched by basename, because both docs refer to
#     `zfs.sh` and `post-check.sh` without their directory.

top_level=()
while IFS= read -r entry; do
    top_level+=("${entry}")
done < <(cd "${REPO_ROOT}" && git ls-files | cut -d/ -f1 | sort -u)

basenames=()
while IFS= read -r entry; do
    basenames+=("${entry}")
done < <(cd "${REPO_ROOT}" && git ls-files | xargs -n1 basename | sort -u)

in_list() {
    local needle=$1 item
    shift
    for item in "$@"; do
        [[ "${item}" == "${needle}" ]] && return 0
    done
    return 1
}

for doc in README.md AGENTS.md; do
    # SC2016: the backticks are the Markdown code-span delimiters being matched,
    # not a command substitution, so they have to stay literal.
    # shellcheck disable=SC2016
    spans=$(grep -oE '`[^`]+`' "${REPO_ROOT}/${doc}" | tr -d '`' | sort -u)

    checked=0
    while IFS= read -r span; do
        [[ -z "${span}" ]] && continue
        # Relative, no shell metacharacters, no scheme.
        [[ "${span}" =~ ^[A-Za-z0-9_.][A-Za-z0-9_./-]*$ ]] || continue

        if [[ "${span}" == */* ]]; then
            in_list "${span%%/*}" "${top_level[@]}" || continue
            checked=$((checked + 1))
            assert_path_exists "${doc} names an existing path: ${span}" "${span%/}"
        else
            # Only filenames, and only ones whose extension we own. A bare word
            # like `main` or `latest` is not a claim about a file.
            case "${span}" in
                *.md | *.sh | *.json | *.yml | Containerfile) ;;
                *) continue ;;
            esac
            checked=$((checked + 1))
            if in_list "${span}" "${basenames[@]}"; then
                _pass "${doc} names an existing file: ${span}"
            else
                _fail "${doc} names an existing file: ${span}" \
                    "no tracked file in the repo is named ${span}"
            fi
        fi
    done <<<"${spans}"

    if [[ "${checked}" -gt 0 ]]; then
        _pass "${doc} yielded ${checked} path reference(s) to check"
    else
        _fail "${doc} yielded path reference(s) to check" \
            "the code-span filter matched nothing, so this file is unverified"
    fi
done

finish
