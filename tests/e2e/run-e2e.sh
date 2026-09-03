#!/usr/bin/env bash
#
# End-to-end verification: build the real image and check the real artifact.
#
# The rest of tests/ runs against stubs on the host in seconds. This does not.
# It runs podman, builds the whole Containerfile, and takes tens of minutes and
# a lot of disk. It is deliberately not part of ./tests/run-tests.sh — that
# runner globs tests/test-*.sh at maxdepth 1, so nothing here is picked up by
# accident.
#
# WHAT IT ADDS OVER CI
#
# The `Build container image` workflow already builds the image on every pull
# request, and build_files/post-check.sh runs inside that build. So a plain
# --build-only run here is a local rehearsal of something CI does anyway.
#
# The --rechunk mode is the part CI does not do. post-check.sh and `bootc
# container lint` are RUN steps in the Containerfile, so they validate the image
# *before* the workflow hands it to Chunkah. Chunkah then re-layers it, and the
# archive that comes back out is loaded, tagged, pushed and signed with neither
# check running again. `Verify pushed tags share one digest` proves every tag
# resolves to one manifest; it says nothing about what that manifest contains.
#
# --rechunk closes that loop locally: rechunk exactly as the workflow does, then
# run post-check.sh again inside the result. If Chunkah ever drops or mangles
# something on the way through, this is what notices.
#
# STORAGE
#
# Every image this creates is tagged under one unique, timestamped name, and
# --clean removes only those exact tags. Nothing here prunes, and nothing here
# touches an image it did not create.
#
#   ./tests/e2e/run-e2e.sh                 # build, then verify
#   ./tests/e2e/run-e2e.sh --rechunk       # build, rechunk, verify the rechunked image
#   ./tests/e2e/run-e2e.sh --clean         # also remove the images it made
#   ./tests/e2e/run-e2e.sh --keep-going    # report every failed check, not just the first

set -euo pipefail

E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${E2E_DIR}/../.." && pwd)"

# Matches the workflow's pin. Kept in sync by hand; the workflow is the source
# of truth and this only affects --rechunk.
CHUNKAH_IMAGE="${CHUNKAH_IMAGE:-quay.io/coreos/chunkah:v0.6.0}"

RECHUNK=0
CLEAN=0
KEEP_GOING=0

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --rechunk) RECHUNK=1 ;;
        --clean) CLEAN=1 ;;
        --keep-going) KEEP_GOING=1 ;;
        -h | --help)
            sed -n '2,40p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *)
            printf 'run-e2e: unknown option: %s\n' "$1" >&2
            exit 2
            ;;
    esac
    shift
done

STAMP="$(date -u +%Y%m%d-%H%M%S)"
BUILD_TAG="localhost/aurora-zfs-simple-e2e:${STAMP}"
CHUNKED_TAG="localhost/aurora-zfs-simple-e2e:${STAMP}-chunked"
CREATED_TAGS=()

FAILURES=0
CHECKS=0

pass() {
    CHECKS=$((CHECKS + 1))
    printf '  ok   %s\n' "$1"
}

fail() {
    CHECKS=$((CHECKS + 1))
    FAILURES=$((FAILURES + 1))
    printf '  FAIL %s\n' "$1"
    shift
    local detail
    for detail in "$@"; do
        printf '       %s\n' "${detail}"
    done
    if [[ "${KEEP_GOING}" -eq 0 ]]; then
        printf '\nStopping at first failure. Re-run with --keep-going to see them all.\n' >&2
        exit 1
    fi
}

step() { printf '\n==> %s\n' "$1"; }

cleanup() {
    [[ "${CLEAN}" -eq 1 ]] || return 0
    [[ "${#CREATED_TAGS[@]}" -gt 0 ]] || return 0
    step "Removing only the images this run created"
    local tag
    for tag in "${CREATED_TAGS[@]}"; do
        printf '  rmi %s\n' "${tag}"
        podman rmi -f "${tag}" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT

# --- prerequisites ----------------------------------------------------------

step "Checking prerequisites"

if ! command -v podman >/dev/null 2>&1; then
    printf 'run-e2e: podman is required\n' >&2
    exit 1
fi
printf '  podman %s\n' "$(podman --version | awk '{print $3}')"

avail_kb="$(df -Pk "${REPO_ROOT}" | awk 'NR==2 {print $4}')"
if [[ "${avail_kb}" -lt 41943040 ]]; then
    printf 'run-e2e: want at least 40G free near %s, found %sG\n' \
        "${REPO_ROOT}" "$((avail_kb / 1048576))" >&2
    printf 'run-e2e: the base image, akmods layers and the built image do not fit\n' >&2
    exit 1
fi
printf '  %sG free\n' "$((avail_kb / 1048576))"

# --- build ------------------------------------------------------------------

step "Building ${BUILD_TAG}"
printf '  this is the whole Containerfile: expect tens of minutes\n'

CREATED_TAGS+=("${BUILD_TAG}")
podman build --tag "${BUILD_TAG}" --file "${REPO_ROOT}/Containerfile" "${REPO_ROOT}"

# A green build already means post-check.sh and `bootc container lint` passed,
# since both are RUN steps. Say so rather than implying this script proved it.
pass "Containerfile built, so its in-build post-check.sh and bootc lint passed"

# --- rechunk, if asked ------------------------------------------------------

TARGET="${BUILD_TAG}"

if [[ "${RECHUNK}" -eq 1 ]]; then
    step "Rechunking with ${CHUNKAH_IMAGE}"

    # Same --config-str workaround the workflow documents: a full inspect
    # carries RootFS.Layers and History, which scale with the base image's layer
    # count and blow past MAX_ARG_STRLEN once it is large enough.
    export CHUNKAH_CONFIG_STR
    CHUNKAH_CONFIG_STR="$(podman inspect --format '{{json .Config}}' "${BUILD_TAG}")"

    archive="$(mktemp -t chunkah-e2e-XXXXXX.tar)"
    podman run --rm \
        --mount=type=image,src="${BUILD_TAG}",target=/chunkah \
        -e CHUNKAH_CONFIG_STR \
        "${CHUNKAH_IMAGE}" build \
        --verbose \
        --compressed \
        --max-layers 128 \
        --prune /sysroot/ \
        --label ostree.commit- \
        --label ostree.final-diffid- \
        --tag "${CHUNKED_TAG}" >"${archive}"

    CREATED_TAGS+=("${CHUNKED_TAG}")
    podman load -i "${archive}"
    rm -f "${archive}"

    TARGET="${CHUNKED_TAG}"
    pass "Chunkah produced a loadable image"
fi

# --- verify the artifact ----------------------------------------------------
#
# Re-running post-check.sh here is the point of --rechunk: it is the only place
# the re-layered image is checked at all. It is not copied into the image, so
# mount it in read-only and run it.

step "Verifying ${TARGET}"

if podman run --rm \
    -v "${REPO_ROOT}/build_files/post-check.sh:/post-check.sh:ro" \
    "${TARGET}" /post-check.sh; then
    pass "post-check.sh passes against the final image"
else
    fail "post-check.sh passes against the final image" \
        "image: ${TARGET}" \
        "if this failed only with --rechunk, the rechunk changed the image"
fi

# A handful of assertions post-check.sh does not make, about the shape of the
# thing a user would actually rebase onto.

kernel_count="$(podman run --rm "${TARGET}" sh -c 'ls -1 /usr/lib/modules | wc -l')"
if [[ "${kernel_count}" == "1" ]]; then
    pass "exactly one kernel module tree is present"
else
    fail "exactly one kernel module tree is present" "found ${kernel_count}"
fi

if podman run --rm "${TARGET}" sh -c 'command -v zpool && command -v zfs' >/dev/null; then
    pass "zpool and zfs are on PATH"
else
    fail "zpool and zfs are on PATH" "ZFS userspace missing from the final image"
fi

bootc_label="$(podman inspect --format '{{ index .Labels "containers.bootc" }}' "${TARGET}" 2>/dev/null || true)"
if [[ "${bootc_label}" == "1" ]]; then
    pass "containers.bootc=1 label survived"
else
    # The workflow applies this label at build time via docker/metadata-action,
    # so a local podman build legitimately will not have it. Only meaningful as
    # a rechunk regression check.
    if [[ "${RECHUNK}" -eq 1 ]]; then
        printf '  note containers.bootc label is %s; set by the workflow, not by a local build\n' \
            "${bootc_label:-unset}"
    fi
fi

# --- report -----------------------------------------------------------------

printf '\n'
if [[ "${FAILURES}" -gt 0 ]]; then
    printf 'e2e: %d check(s), %d failure(s)\n' "${CHECKS}" "${FAILURES}"
    exit 1
fi
printf 'e2e: %d check(s), all passed (%s)\n' "${CHECKS}" "${TARGET}"
if [[ "${CLEAN}" -eq 0 ]]; then
    printf 'e2e: images kept. Remove with: podman rmi %s\n' "${CREATED_TAGS[*]}"
fi
