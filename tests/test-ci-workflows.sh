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
# One assertion here is about a different property than the rest: that no step
# splices a ${{ ... }} expression into the shell it runs. That is not a gating
# question, it is the same anti-rot question in the security direction -- the
# safe form and the injectable form look identical in review, so the difference
# has to be checked rather than remembered. See section 6.
#
# That section is written inside out, and the reason is worth reading before
# changing it. Its first version found the shell and checked it for
# expressions, which made every step the parser failed to recognise a step it
# silently skipped -- and review found six such spellings, one at a time, each
# leaving the assertion green. Enumerating YAML spellings is not a race this
# file can win. So it now finds the *expressions*, which is a lexical question,
# and requires each to be somewhere it provably cannot become shell; what cannot
# be placed fails. The unthought-of spelling lands in the failing bucket by
# default rather than the passing one.
#
# The YAML is read with an indentation-anchored parser rather than a real one:
# CONTRIBUTING.md asks for a conversation before adding a dependency, and the
# structure needed here is shallow. The risk of hand-parsing is silent
# under-extraction — a reformat the parser cannot follow yields an empty result,
# and an assertion over nothing passes. So every extraction is checked for
# emptiness first and fails loudly, and each parser helper is exercised against
# a fixture with a known answer before it is trusted against the real files.
#
# Section 6 goes one step further, because it is the one guarding a security
# property. Its classifier must account for exactly as many `${{` openers as a
# plain `grep -oF` finds in the same file. That counter understands no YAML at
# all, so a parser that read past part of a file cannot hide it: the failure
# stops being a silent pass and becomes an arithmetic disagreement.

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
        # YAML ignores comment indentation, so a comment must never look like a
        # structural key. build.yml has comment blocks at two spaces, exactly
        # where an event name sits.
        /^[[:space:]]*#/    { next }
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

# event_has_key <file> <event> <key>
#
# True if `on: <event>:` declares <key> at all, in any YAML style. event_paths
# reads block sequences only, so an inline `types: [closed]` extracts nothing
# and is indistinguishable from an absent key — which matters wherever *absence*
# is the passing condition.
event_has_key() {
    local file=$1 event=$2 key=$3
    awk -v event="${event}" -v key="${key}" '
        # YAML ignores comment indentation, so a comment must never look like a
        # structural key. build.yml has comment blocks at two spaces, exactly
        # where an event name sits.
        /^[[:space:]]*#/    { next }
        /^on:[[:space:]]*$/ { in_on = 1; next }
        /^[^[:space:]#]/    { in_on = 0 }
        !in_on { next }
        /^  [^[:space:]]/ {
            in_event = ($0 ~ "^  " event ":[[:space:]]*$")
            next
        }
        # Quoted keys are valid YAML and mean the same thing. This matters here
        # and not in event_paths, because absence is the passing condition: a
        # spelling this cannot see reads as "not declared". The single quote is
        # written as \047 because this awk program is inside a single-quoted
        # shell string, where a literal one would end the program early.
        in_event && $0 ~ ("^    [\"\047]?" key "[\"\047]?[[:space:]]*:") { found = 1 }
        END { exit !found }
    ' "${file}"
}

# job_block <file> <job>
#
# Prints the body of one entry under the top-level `jobs:` key.
job_block() {
    local file=$1 job=$2
    awk -v job="${job}" '
        /^[[:space:]]*#/      { next }
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

# workflow_expressions <file>
#
# Prints "<line><TAB><verdict><TAB><count><TAB><content>" for every line
# carrying a ${{ ... }} expression, where <count> is how many openers the line
# holds and <verdict> is one of:
#
#   shell    the expression is executed -- a run: script, or a shell: key,
#            which GitHub renders into the command that launches the script
#   value    it is a YAML value in a mapping that is not run: -- safe
#   unknown  neither could be established
#
# The direction matters more than the mechanics, and it is the opposite of what
# this section did for its first six revisions. That version found the shell and
# checked it for expressions, so a step it could not recognise was a step it
# never examined, and the assertion went green over it. Six such spellings were
# found in review, one at a time: a comment after a block indicator, a comment
# after `steps:`, a quoted `run` key, a flow scalar continued onto a second
# line, a flow-mapping step, and a file named .yaml. Patching each one cannot
# terminate, because the set of YAML spellings is not something this file can
# enumerate in advance.
#
# So this finds the *expressions* -- which is a lexical question, not a YAML one
# -- and requires each to be somewhere it provably cannot become shell. What the
# classifier cannot place is `unknown`, and unknown fails. A spelling nobody has
# thought of now lands in the failing bucket by default instead of the passing
# one, which is the property the previous design could not have at any level of
# effort.
#
# Two consequences worth stating, because they are what make the class closed
# rather than merely narrowed:
#
#   * Block scalars are tracked by their key name, whatever the key is, so a
#     run: body is recognised without knowing anything about `steps:`. Removing
#     the `steps:` rule entirely still catches every case above -- verified.
#     `steps:` now decides one thing only: whether a bare `run: ${{ ... }}` is a
#     step or a job output, and ai-fix.yml declares an output named `run`.
#   * Inside a block scalar nothing is interpreted as structure. A heredoc line
#     such as `name: ${{ github.actor }}` inside a run: body is shell, and is
#     classified by the block it is in rather than by how it looks.
workflow_expressions() {
    local file=$1
    awk '
        # Blank lines carry no expression, and a blank inside a block scalar
        # does not end it.
        /^[[:space:]]*$/ { next }

        {
            match($0, /^[[:space:]]*/)
            ws = RLENGTH
            # Counting the opener is deliberate: an expression may be written
            # across lines, but `${{` is one token on one line, and this count
            # is reconciled against a plain grep below.
            n = split($0, _parts, /\$[{][{]/) - 1
        }

        # --- inside a block scalar: opaque text, judged by whose value it is --
        in_block && ws <= block_indent { in_block = 0 }
        in_block {
            if (n > 0) print FNR "\t" (block_key == "run" ? "shell" : "value") "\t" n "\t" $0
            next
        }

        # A YAML comment is not executed. Inside a block scalar this line is
        # never reached, because there a leading # is shell.
        /^[[:space:]]*#/ { if (n > 0) print FNR "\tvalue\t" n "\t" $0; next }

        /^[[:space:]]*["\047]?steps["\047]?[[:space:]]*:[[:space:]]*(#.*)?$/ {
            steps_indent = ws
            in_steps = 1
            next
        }
        in_steps && ws <= steps_indent { in_steps = 0 }

        {
            key = ""
            # A block mapping key: optional list dash, optional quotes, then a
            # colon that must be followed by a space or end of line. That last
            # part is what keeps `docker://host/image` from reading as a key.
            if (match($0, /^[[:space:]]*(-[[:space:]]+)?["\047]?[A-Za-z_][A-Za-z0-9_.-]*["\047]?[[:space:]]*:([[:space:]]|$)/)) {
                head = substr($0, 1, RSTART + RLENGTH - 1)

                key = head
                sub(/^[[:space:]]*(-[[:space:]]+)?/, "", key)
                sub(/[[:space:]]*:[[:space:]]*$/, "", key)
                gsub(/["\047]/, "", key)

                # The column of the key itself, so a sibling key closes the
                # block even in the `- run: |` form where the dash is left of it.
                prefix = head
                sub(/["\047]?[A-Za-z_][A-Za-z0-9_.-]*["\047]?[[:space:]]*:[[:space:]]*$/, "", prefix)
                key_indent = length(prefix)

                value = substr($0, RSTART + RLENGTH)
                sub(/^[[:space:]]*/, "", value)
            }

            if (key == "") {
                if (n > 0) print FNR "\tunknown\t" n "\t" $0
                next
            }

            # A block scalar indicator, with its chomping and indentation
            # modifiers and an optional comment. Everything below belongs to
            # this key.
            if (value ~ /^[|>][-+0-9]*[[:space:]]*(#.*)?$/) {
                in_block = 1
                block_key = key
                block_indent = key_indent
                if (n > 0) print FNR "\t" (key == "run" ? "shell" : "value") "\t" n "\t" $0
                next
            }

            # `run` is the script. `shell` is executed too: GitHub renders it
            # into the command line that launches the temporary script, so
            # `shell: ${{ ... }} {0}` runs before the body does. Vouching for
            # every key that is not `run` missed that.
            executable = (key == "run" || key == "shell")

            if (n > 0) {
                if (!executable) {
                    print FNR "\tvalue\t" n "\t" $0
                } else if (key == "run" && !in_steps && value ~ /^["\047]?\$[{][{][^{}]*[}][}]["\047]?$/) {
                    # Outside a steps: block, and nothing but the expression:
                    # a job output, which is a value. A script that is nothing
                    # but an expression is an injection, so this narrow shape is
                    # the only run: key that reads as safe.
                    print FNR "\tvalue\t" n "\t" $0
                } else {
                    print FNR "\tshell\t" n "\t" $0
                }
            }

            # A non-empty value is a scalar, and a scalar does not have to end
            # on its own line: YAML folds every following line indented past
            # the key into it, quoted or not. So
            #
            #     run: "echo start
            #       name: ${{ github.event.issue.title }}"
            #
            # is one command, and reading that second line as a fresh `name:`
            # key vouched for an expression that is spliced straight into shell.
            # The continuation is delimited exactly like a block scalar body, so
            # it is tracked as one -- which is also why plain (unquoted) folds
            # are covered without a separate rule for quoting.
            #
            # An empty value opens a nested mapping or sequence instead, whose
            # children are keys in their own right and must keep being read as
            # such. A value that is only a comment is empty.
            value_body = value
            sub(/^#.*$/, "", value_body)
            if (value_body != "") {
                in_block = 1
                block_key = key
                block_indent = key_indent
            }
            next
        }
    ' "${file}"
}

# refused_yaml_forms <file>
#
# Prints "<line><TAB><reason><TAB><content>" for YAML this test declines to
# reason about rather than guess at:
#
#   flow-step   `steps: [ ... ]`, or a `- { name: x, run: y }` item
#   anchor      a YAML anchor or alias
#
# Both are valid YAML, and both would let content reach a run: script by a route
# the classifier above does not model -- a flow mapping puts the run key
# mid-line, and an alias carries a value from somewhere else in the file
# entirely. A parser for either means nested braces, quoting, merge keys and
# line continuations, and being quietly wrong about any of them puts back
# exactly the silent hole the classifier was rewritten to close.
#
# Refusing costs this repo nothing. Every step here is block style already, and
# GitHub Actions does not support anchors at all, so the second is a form that
# cannot appear in a working workflow. If either ever needs to be used, the
# honest move is a real YAML parser and the dependency conversation
# CONTRIBUTING.md asks for -- not a cleverer regex.
refused_yaml_forms() {
    local file=$1
    awk '
        /^[[:space:]]*$/ { next }
        { match($0, /^[[:space:]]*/); ws = RLENGTH }

        # Inside a block scalar everything is text: shell `&&`, a brace in a
        # ${{ }} expression, a `*` glob. None of it is YAML structure.
        in_block && ws <= block_indent { in_block = 0 }
        in_block { next }
        /^[[:space:]]*#/ { next }

        match($0, /^[[:space:]]*(-[[:space:]]+)?["\047]?[A-Za-z_][A-Za-z0-9_.-]*["\047]?[[:space:]]*:[[:space:]]*[|>][-+0-9]*[[:space:]]*(#.*)?$/) {
            prefix = $0
            sub(/["\047]?[A-Za-z_][A-Za-z0-9_.-]*["\047]?[[:space:]]*:.*$/, "", prefix)
            block_indent = length(prefix)
            in_block = 1
            next
        }

        # An anchor definition or an alias reference, in a value position.
        #
        # The name is matched as "not whitespace, and not a second & or *"
        # rather than as an identifier: YAML anchor names are not identifiers,
        # and `&1` / `*1` are valid. Accepting only [A-Za-z_] let
        # `SCRIPT: &1 ${{ ... }}` in env: pass as an ordinary value while
        # `run: *1` pulled it in as the script -- found in review, and the
        # reason this class is refused wholesale rather than reasoned about.
        #
        # The two exclusions are what keep real files quiet: `&&` in a
        # single-line shell condition, and a `**` glob in a paths: list. Both
        # would otherwise read as a sigil.
        /(:|-)[[:space:]]+[&*][^[:space:]&*]/ { print FNR "\tanchor\t" $0; next }

        # `steps: [ ... ]` -- a flow sequence, which opens no block below.
        /^[[:space:]]*["\047]?steps["\047]?[[:space:]]*:[[:space:]]*\[/ {
            print FNR "\tflow-step\t" $0
            next
        }

        /^[[:space:]]*["\047]?steps["\047]?[[:space:]]*:[[:space:]]*(#.*)?$/ {
            steps_indent = ws
            in_steps = 1
            next
        }
        in_steps && ws <= steps_indent { in_steps = 0 }
        !in_steps { next }

        # `- { ... }` -- a flow mapping step. Anchored on the dash so a brace in
        # shell, or in a ${{ }}, is not mistaken for one.
        /^[[:space:]]*-[[:space:]]*\{/ { print FNR "\tflow-step\t" $0 }
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
  third:
    outputs:
      run: ${{ steps.somewhere.outputs.run }}
    steps:
      - name: Block scalar
        run: |
          echo in-the-body "${{ github.actor }}"
        env:
          NOT_THE_BODY: ${{ github.actor }}
      - name: Block scalar with a comment after the indicator
        run: |- # valid YAML, and easy to parse past
          echo commented-indicator "${{ github.actor }}"
        env:
          STILL_NOT_THE_BODY: yes
      - run: |
          echo dash-form-body "${{ github.actor }}"
        env:
          ALSO_NOT_THE_BODY: yes
      - "run": echo quoted-key-script "${{ github.actor }}"
      - name: A flow scalar continued onto a second line
        run: "echo first-half ${{ github.actor }}
          && echo second-half ${{ github.actor }}"
        env:
          NOT_THE_CONTINUATION: yes
  fourth:
    steps:
      - { name: Flow mapping, run: 'echo flow-mapping-script ${{ github.actor }}' }
  fifth:
    # a-comment-not-a-script ${{ github.actor }}
    steps:
      - name: A heredoc whose lines look like YAML keys
        run: |
          cat > cfg.yml <<'EOF'
          heredoc-key: ${{ github.actor }}
          EOF
      - name: A folded scalar
        run: >
          echo folded-body ${{ github.actor }}
  sixth: &an_anchor
    steps:
      - run: echo anchored
  seventh:
    env:
      NUMERIC_ANCHOR: &1 ${{ github.actor }}
    steps:
      - run: *1
  eighth:
    steps:
      - name: A quoted scalar folded onto a mapping-shaped line
        run: "echo start
          folded-onto-a-key: ${{ github.actor }}"
      - name: A plain scalar folded the same way
        run: echo start
          plain-folded-key: ${{ github.actor }}
      - name: An expression in the shell key
        shell: ${{ github.actor }} {0}
        run: echo hi
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

# The classifier, against a fixture holding every shape review has turned up.
# Each is asserted by verdict, so a future change that quietly reclassifies one
# as safe fails here rather than in production.
verdict_for() {
    workflow_expressions "${fixture}" | awk -F'\t' -v want="$1" '$4 ~ want { print $2; exit }'
}

assert_eq "an expression in a run: body is shell" "shell" "$(verdict_for in-the-body)"
assert_eq "a body whose indicator carries a comment is still shell" \
    "shell" "$(verdict_for commented-indicator)"
assert_eq "a dash-form body is shell" "shell" "$(verdict_for dash-form-body)"
assert_eq "a quoted run key is shell" "shell" "$(verdict_for quoted-key-script)"
assert_eq "the first line of a flow scalar is shell" "shell" "$(verdict_for first-half)"
# Tracking scalar continuations upgraded this from "unknown" to "shell": the
# line is not merely unplaceable, it is part of the command.
assert_eq "its continuation is read as part of the same command" \
    "shell" "$(verdict_for second-half)"
assert_eq "a heredoc line shaped like a YAML key is still shell" \
    "shell" "$(verdict_for heredoc-key)"
assert_eq "a folded run: scalar is shell" "shell" "$(verdict_for folded-body)"
# YAML folds any line indented past the key into the same scalar, so a
# continuation that happens to look like `key: value` is still the command.
assert_eq "a quoted scalar folded onto a mapping-shaped line is shell" \
    "shell" "$(verdict_for folded-onto-a-key)"
assert_eq "and an unquoted one, which needs no separate rule" \
    "shell" "$(verdict_for plain-folded-key)"
# GitHub renders shell: into the command that launches the script, so an
# expression there runs before the body does.
assert_eq "an expression in the shell: key is executable, not data" \
    "shell" "$(verdict_for 'shell: ')"

assert_eq "a step's env: value is a value, not shell" "value" "$(verdict_for NOT_THE_BODY)"
assert_eq "a job output named run is a value, not a script" \
    "value" "$(verdict_for somewhere.outputs.run)"
assert_eq "a YAML comment is not executed" "value" "$(verdict_for a-comment-not-a-script)"

# The property that ends the class: the classifier must account for every
# opener a plain grep can find. An expression it fails to place cannot be
# skipped in silence, because a dumber counter knows how many there are.
fixture_seen=$(workflow_expressions "${fixture}" | awk -F'\t' '{s+=$3} END{print s+0}')
# shellcheck disable=SC2016 # the literal Actions opener, not a shell expansion
fixture_actual=$(grep -oF '${{' "${fixture}" | wc -l)
assert_eq "the classifier accounts for every expression in the fixture" \
    "${fixture_actual}" "${fixture_seen}"

assert_contains "refused forms include the flow-mapping step" \
    "$(refused_yaml_forms "${fixture}")" "flow-mapping-script"
assert_contains "and a YAML anchor" \
    "$(refused_yaml_forms "${fixture}")" "anchor"
# A numeric anchor name is valid YAML and is not an identifier. Accepting only
# [A-Za-z_] let &1 / *1 route an env: value into a run: script unseen.
assert_contains "including one whose name is a number" \
    "$(refused_yaml_forms "${fixture}")" "NUMERIC_ANCHOR"
assert_contains "and the alias that pulls it into a script" \
    "$(refused_yaml_forms "${fixture}")" "run: *1"
assert_eq "and nothing in ordinary block-style steps" "" \
    "$(refused_yaml_forms "${fixture}" | grep -vE 'flow-mapping-script|anchor' || true)"

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

    # The value is compared, not searched for. `run: ./tests/run-tests.sh || true`
    # contains the command, passes a substring test and the continue-on-error
    # check, and still returns success from a failing suite. Arguments are
    # refused for the same reason: run-tests.sh takes a subset of the files.
    suite_line=$(grep -E '^[[:space:]]+["'"'"']?run["'"'"']?[[:space:]]*:' <<<"${block}" |
        grep -F 'run-tests.sh' | head -1)
    suite_cmd=${suite_line#*:}
    suite_cmd=${suite_cmd#"${suite_cmd%%[![:space:]]*}"}
    suite_cmd=${suite_cmd%"${suite_cmd##*[![:space:]]}"}
    if [[ "${suite_cmd}" == "./tests/run-tests.sh" ]]; then
        _pass "${label} runs the shell suite"
    else
        _fail "${label} runs the shell suite" \
            "expected the step to run exactly ./tests/run-tests.sh" \
            "found: ${suite_cmd:-<no run: step invoking run-tests.sh>}" \
            "a suffix such as '|| true' returns success from a failing suite;" \
            "an argument runs only part of it"
    fi
    assert_contains "${label} installs shellcheck" "${block}" "apt-get install -y shellcheck"

    # Running the suite is not the same as being gated by it. `continue-on-error`
    # leaves a red suite in a green job, and an `if:` on the step or the job can
    # skip it outright — both leave every assertion above satisfied.
    if grep -qE '^[[:space:]]+["'"'"']?continue-on-error["'"'"']?[[:space:]]*:' <<<"${block}"; then
        _fail "${label}'s tests job fails when the suite fails" \
            "continue-on-error is set somewhere in the job; a red suite would leave it green"
    else
        _pass "${label}'s tests job fails when the suite fails"
    fi

    if grep -qE '^[[:space:]]+["'"'"']?if["'"'"']?[[:space:]]*:' <<<"${block}"; then
        _fail "${label}'s tests job is unconditional" \
            "an if: condition appears in the job; the suite can be skipped without failing" \
            "if the condition is deliberate, update this test to say so"
    else
        _pass "${label}'s tests job is unconditional"
    fi

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

    # Parsed rather than substring-matched: "needs: tests" is a prefix of
    # "needs: tests_bypass", and a commented-out line contains it too. Both
    # spellings GitHub accepts are read — a scalar and a list — because the
    # assertion is about the dependency, not about how it is written.
    needs_line=$(grep -m1 -E '^    ["'"'"']?needs["'"'"']?[[:space:]]*:' <<<"${build_push}")
    needs_deps=""
    if [[ -z "${needs_line}" ]]; then
        _fail "build_push needs the tests job" \
            "build_push declares no needs: at all; a red suite would not block the build"
    else
        needs_value=${needs_line#*:}
        needs_value=${needs_value#"${needs_value%%[![:space:]]*}"}
        if [[ -z "${needs_value}" ]]; then
            # Block list: the entries follow on their own lines.
            needs_deps=$(sed -n '/^    ["'"'"']\?needs["'"'"']\?[[:space:]]*:[[:space:]]*$/,/^    [^ ]/p' <<<"${build_push}" |
                sed -nE 's/^      -[[:space:]]+["'"'"']?([A-Za-z0-9_-]+)["'"'"']?[[:space:]]*$/\1/p')
        else
            # Scalar or inline flow list.
            needs_deps=$(tr -d '[]"'"'"'' <<<"${needs_value}" | tr ',' '\n' |
                sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | grep -v '^$')
        fi

        if grep -qxF 'tests' <<<"${needs_deps}"; then
            _pass "build_push needs the tests job"
        else
            _fail "build_push needs the tests job" \
                "parsed dependencies: ${needs_deps//$'\n'/, }" \
                "'tests' is not among them, so a red suite would not block the build"
        fi
    fi

    # `needs:` alone is not a gate. A job-level `if:` — always() being the usual
    # one — makes a job run even when the job it needs failed.
    if grep -qE '^    ["'"'"']?if["'"'"']?[[:space:]]*:' <<<"${build_push}"; then
        _fail "build_push has no job-level if: overriding needs" \
            "a job-level if: can run build_push even when tests failed (e.g. always());" \
            "step-level if: is fine and not what this checks"
    else
        _pass "build_push has no job-level if: overriding needs"
    fi
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

# --- 4. the filters that decide whether any of the above runs at all --------
#
# Every assertion above reasons about path filters, and none of them notices if
# a workflow stops matching the *branch* or the *activity* instead. The two are
# not interchangeable: point build.yml's pull_request at another branch and it
# no longer runs on pull requests to main, while coverage-gate.yml keeps running
# (the change touches .github/workflows/**, which it triggers on) and every
# assertion here still passes. Merge that and a source-only pull request — one
# touching neither docs nor workflows — runs no suite at all, which is the same
# hole the path checks exist to close, reached by a different door.
#
# 'main' must appear rather than be the whole list: adding a second branch
# widens what is covered and breaks nothing. Removing the filter entirely also
# widens it, but it reads identically to a parser failure here, so it fails and
# says so rather than being guessed at.

check_triggers() {
    local label=$1 file=$2 event
    for event in pull_request push; do
        local branches
        branches=$(event_paths "${file}" "${event}" branches)
        # Ordered negation applies here exactly as it does to paths: `- main`
        # followed by `- '!main'` leaves main excluded, and a membership test
        # sees only the positive entry.
        if negated=$(grep -- '^!' <<<"${branches}"); then
            _fail "${label}: ${event} branch filter uses no '!' negation" \
                "found: ${negated//$'\n'/, }" \
                "GitHub applies these in order, so a later negation can exclude main" \
                "while the membership check below still sees it"
            continue
        fi
        _pass "${label}: ${event} branch filter uses no '!' negation"
        if grep -qxF 'main' <<<"${branches}"; then
            _pass "${label}: ${event} still targets main"
        else
            _fail "${label}: ${event} still targets main" \
                "extracted branches: ${branches//$'\n'/, }" \
                "if the filter was widened or removed on purpose, update this test;" \
                "if it was narrowed, this workflow no longer runs on ${event} to main"
        fi
    done

    # No `types:` means the pull_request defaults — opened, synchronize,
    # reopened — which is what makes the suite run on a pull request and again
    # on every push to it. A narrower list is not necessarily wrong, but it is a
    # decision about when the gate applies, so it should not arrive silently.
    #
    # Tested for key *presence*, not for an empty extraction: `types: [closed]`
    # is valid YAML that event_paths cannot read, and treating that silence as
    # "no types declared" would turn the narrowest possible filter into a pass.
    if event_has_key "${file}" pull_request types; then
        _fail "${label}: pull_request uses the default activity types" \
            "a types: key is declared; confirm 'opened' and 'synchronize' are" \
            "still among them, then update this test"
    else
        _pass "${label}: pull_request uses the default activity types"
    fi
}

check_triggers "build.yml" "${BUILD_WF}"
check_triggers "coverage-gate.yml" "${COVERAGE_WF}"

# --- 5. status-badges.yml still skips pull requests -------------------------
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

    # The job-level condition is compared, not searched for. Broadening it to
    # `always() || github.event.workflow_run.event != 'pull_request'` still
    # contains the fragment while running the job after pull-request builds —
    # and this job holds contents: write and pushes to the status branch.
    badges_if=$(grep -m1 -E '^    ["'"'"']?if["'"'"']?[[:space:]]*:' <<<"${badges}")
    badges_cond=${badges_if#*:}
    badges_cond=${badges_cond#"${badges_cond%%[![:space:]]*}"}
    badges_cond=${badges_cond%"${badges_cond##*[![:space:]]}"}
    if [[ "${badges_cond}" == "github.event.workflow_run.event != 'pull_request'" ]]; then
        _pass "status-badges.yml still skips pull requests"
    else
        _fail "status-badges.yml still skips pull requests" \
            "expected exactly: github.event.workflow_run.event != 'pull_request'" \
            "found: ${badges_cond:-<no job-level if:>}" \
            "build.yml's tests job documents this skip as the reason it runs" \
            "write-badges.sh on every pull request; a broadened condition also lets" \
            "a job with contents: write push to the status branch from a PR build"
    fi
fi

# --- 6. every Actions expression is somewhere it cannot become shell -------
#
# ${{ ... }} is substituted at YAML-render time, before bash starts, so a value
# containing shell metacharacters arrives as syntax rather than as data. Passing
# it through `env:` and reading "${VAR}" hands bash a string instead.
#
# Nothing in this repo's expressions is attacker-controlled today: build.yml's
# tags come from `type=raw` values the workflow defines, and the digests come
# from a push it just performed. The assertion is about what a later change
# costs. Extending a `tags:` input with a branch name or a PR title is a one-line
# edit far from the loop that consumes it, and in a spliced loop that edit is a
# command injection nobody reviewing the tags block would see.
#
# On why this is written inside out, see workflow_expressions. In short: the
# first version of this section looked for the shell and checked it, so every
# spelling of a step it failed to recognise was a step it silently skipped, and
# review found six of those one at a time. This version looks for the
# expressions -- a lexical question -- and demands that each be provably
# harmless. Unknown fails.
#
# Three assertions, and the third is the one that closes the class:
#
#   * no expression sits in a run: script
#   * none is unclassifiable
#   * the classifier accounted for exactly as many openers as `grep -oF '${{'`
#     found, per file
#
# That last one cannot be satisfied by a parser that skipped something, because
# the counter it is checked against understands no YAML at all. Under-reading is
# no longer a silent pass; it is an arithmetic disagreement.

in_shell=()
unclassified=()
miscounted=()
refused=()
expressions_seen=0

while IFS= read -r workflow; do
    wf=$(basename "${workflow}")

    seen=0
    while IFS=$'\t' read -r lineno verdict count content; do
        [[ -z "${lineno}" ]] && continue
        seen=$((seen + count))
        case "${verdict}" in
            shell) in_shell+=("${wf}:${lineno}:${content}") ;;
            unknown) unclassified+=("${wf}:${lineno}:${content}") ;;
            value) ;;
            # A verdict this loop does not know is not a verdict it can trust.
            *) unclassified+=("${wf}:${lineno}: unrecognised verdict '${verdict}'") ;;
        esac
    done < <(workflow_expressions "${workflow}")

    # shellcheck disable=SC2016 # the literal Actions opener, not a shell expansion
    actual=$(grep -oF '${{' "${workflow}" | wc -l)
    expressions_seen=$((expressions_seen + actual))
    if [[ "${seen}" -ne "${actual}" ]]; then
        miscounted+=("${wf}: classified ${seen} of ${actual}")
    fi

    while IFS= read -r form; do
        [[ -z "${form}" ]] && continue
        refused+=("${wf}:${form}")
    done < <(refused_yaml_forms "${workflow}")
# GitHub loads .yaml as readily as .yml; a scan that saw only one of them would
# leave the other's expressions unchecked while Actions still ran the file.
done < <(find "${REPO_ROOT}/.github/workflows" -maxdepth 1 \
    \( -name '*.yml' -o -name '*.yaml' \) -type f | sort)

# Nothing below means anything if the workflows hold no expressions at all.
if [[ "${expressions_seen}" -gt 0 ]]; then
    _pass "the workflows carry ${expressions_seen} Actions expression(s) to account for"
else
    _fail "the workflows carry Actions expressions to account for" \
        "found none, so every assertion below is vacuous; check the file glob"
fi

if [[ "${#miscounted[@]}" -eq 0 ]]; then
    _pass "every expression was accounted for by the classifier"
else
    _fail "every expression was accounted for by the classifier" \
        "a plain grep found openers the classifier did not place, which means" \
        "it read past part of the file -- the exact failure this design exists" \
        "to make impossible to miss:" \
        "${miscounted[@]}"
fi

if [[ "${#in_shell[@]}" -eq 0 ]]; then
    _pass "no Actions expression is spliced into a run: script"
else
    _fail "no Actions expression is spliced into a run: script" \
        "pass the value through the step's env: and read it as \"\${VAR}\" instead" \
        "${in_shell[@]}"
fi

if [[ "${#unclassified[@]}" -eq 0 ]]; then
    _pass "every expression sits somewhere the classifier can vouch for"
else
    _fail "every expression sits somewhere the classifier can vouch for" \
        "these are not known to be safe, which is not the same as being known" \
        "to be unsafe -- put the value in a plain key: value or a block scalar," \
        "or extend workflow_expressions to recognise the form:" \
        "${unclassified[@]}"
fi

if [[ "${#refused[@]}" -eq 0 ]]; then
    _pass "no workflow uses a YAML form this test refuses to reason about"
else
    _fail "no workflow uses a YAML form this test refuses to reason about" \
        "flow-style steps and YAML anchors can route a value into a run: script" \
        "by a path the classifier does not model; see refused_yaml_forms:" \
        "${refused[@]}"
fi

finish
