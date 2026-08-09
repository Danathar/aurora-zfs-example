#!/usr/bin/env bash
#
# Writes the shields.io endpoint-badge JSON files behind the README status
# badges.
#
# Two questions a reader should be able to answer from the README alone:
#
#   1. Is there a usable image, and how old is it?  -> last-good-build badge,
#      read straight off the published `:latest` image's Created timestamp.
#   2. If the build is red, why?                    -> openzfs/kernel badge,
#      derived from the two upstream akmods images' `ostree.linux` labels.
#
# Note (2) does not look at build logs at all. This repo does not compile ZFS —
# it assembles prebuilt akmods artifacts — so the dominant failure mode is
# visible in the upstream labels *before* a build ever runs. This is the same
# check AGENTS.md documents as the "60-second diagnosis", just automated. It
# also means the badge goes green again on its own the moment upstream
# re-converges, without waiting for the Sunday build to prove it.
#
# Refusing to guess is a deliberate property: if an input cannot be read, the
# corresponding badge is left at its last known value rather than overwritten
# with something wrong. A stale-but-true badge beats a fresh-but-invented one.

set -euo pipefail

OUT_DIR="${OUT_DIR:-artifacts}"
CONTAINERFILE="${CONTAINERFILE:-Containerfile}"
ARCH="${ARCH:-x86_64}"
AKMODS_STREAM="${AKMODS_STREAM:-coreos-stable}"

mkdir -p "$OUT_DIR"

set_output() {
  [ -n "${GITHUB_OUTPUT:-}" ] && printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
  return 0
}

write_badge() {
  local path="$1" label="$2" message="$3" color="$4"
  jq -n --arg l "$label" --arg m "$message" --arg c "$color" \
    '{schemaVersion: 1, label: $l, message: $m, color: $c}' >"$path"
  echo "Wrote ${path}: ${message}"
}

# Empty output (rather than a hard failure) when the image cannot be read, so a
# transient registry error degrades to "leave the badge alone".
#
# JSON rather than --format: skopeo's Go templates render .Created via Go's
# default time formatting ("2026-07-19 06:04:15.123 +0000 UTC"), which is not
# what `date -d` wants. The JSON field is plain ISO 8601.
inspect_json() {
  local ref="$1"
  shift
  skopeo inspect "$@" "docker://${ref}" 2>/dev/null || true
}

# 7.1.4-200.fc44.x86_64 -> 7.1.4-200. The Fedora release and arch are constant
# across the comparison and only cost badge width.
short_kernel() { printf '%s' "${1%%.fc*}"; }

# ---------------------------------------------------------------------------
# Badge 1: openzfs/kernel compatibility
# ---------------------------------------------------------------------------

# Read the Fedora major from the Containerfile so this never drifts from what
# the build actually pulls.
FEDORA_VERSION="${FEDORA_VERSION:-$(sed -n 's/^ARG FEDORA_VERSION=\([0-9][0-9]*\).*/\1/p' "$CONTAINERFILE" | head -1)}"
if [ -z "$FEDORA_VERSION" ]; then
  echo "Could not read ARG FEDORA_VERSION from ${CONTAINERFILE}" >&2
  exit 1
fi
echo "Fedora version: ${FEDORA_VERSION}"

ostree_linux_of() {
  printf '%s' "$1" | jq -r '.Labels["ostree.linux"] // empty' 2>/dev/null || true
}

akmods_tag="${AKMODS_STREAM}-${FEDORA_VERSION}-${ARCH}"
kernel_akmods="$(ostree_linux_of "$(inspect_json "ghcr.io/ublue-os/akmods:${akmods_tag}")")"
kernel_zfs="$(ostree_linux_of "$(inspect_json "ghcr.io/ublue-os/akmods-zfs:${akmods_tag}")")"

echo "akmods:     ${kernel_akmods:-<unreadable>}"
echo "akmods-zfs: ${kernel_zfs:-<unreadable>}"

if [ -z "$kernel_akmods" ] || [ -z "$kernel_zfs" ]; then
  echo "Could not read both akmods labels; leaving the openzfs/kernel badge as-is."
  set_output akmods_updated false
elif [ "$kernel_akmods" = "$kernel_zfs" ]; then
  write_badge "${OUT_DIR}/akmods-badge.json" \
    "openzfs/kernel" \
    "in sync ($(short_kernel "$kernel_akmods"))" \
    "brightgreen"
  set_output akmods_updated true
else
  write_badge "${OUT_DIR}/akmods-badge.json" \
    "openzfs/kernel" \
    "blocked: kernel $(short_kernel "$kernel_akmods"), ZFS kmod $(short_kernel "$kernel_zfs")" \
    "red"
  set_output akmods_updated true
fi

# ---------------------------------------------------------------------------
# Badge 2: age of the published :latest image
# ---------------------------------------------------------------------------

# `latest` only moves when a build actually publishes, so during an outage this
# is what tells a reader a working image still exists and how stale it is.
IMAGE_REF="${IMAGE_REF:-}"
if [ -z "$IMAGE_REF" ]; then
  owner="$(printf '%s' "${GITHUB_REPOSITORY_OWNER:?GITHUB_REPOSITORY_OWNER or IMAGE_REF required}" | tr '[:upper:]' '[:lower:]')"
  name="$(printf '%s' "${IMAGE_NAME:?IMAGE_NAME or IMAGE_REF required}" | tr '[:upper:]' '[:lower:]')"
  IMAGE_REF="ghcr.io/${owner}/${name}:latest"
fi

creds_args=()
if [ -n "${REGISTRY_ACTOR:-}" ] && [ -n "${REGISTRY_TOKEN:-}" ]; then
  creds_args=(--creds "${REGISTRY_ACTOR}:${REGISTRY_TOKEN}")
fi

created="$(printf '%s' "$(inspect_json "$IMAGE_REF" "${creds_args[@]}")" | jq -r '.Created // empty' 2>/dev/null || true)"
created_date="${created%%T*}"

# Compare whole days in UTC, matching how a reader reads the date on the badge.
created_epoch="$(date -u -d "$created_date" +%s 2>/dev/null || true)"

if [ -z "$created_date" ] || [ -z "$created_epoch" ]; then
  echo "Could not read a usable Created timestamp from ${IMAGE_REF} (got '${created}'); leaving the last-good-build badge as-is."
  set_output last_good_updated false
else
  today_epoch="$(date -u -d "$(date -u +%F)" +%s)"
  days=$(((today_epoch - created_epoch) / 86400))

  if [ "$days" -le 0 ]; then
    age="today"
  elif [ "$days" -eq 1 ]; then
    age="1 day ago"
  else
    age="${days} days ago"
  fi

  write_badge "${OUT_DIR}/last-good-build-badge.json" \
    "last good build" \
    "${created_date} (${age})" \
    "brightgreen"
  set_output last_good_updated true
fi
