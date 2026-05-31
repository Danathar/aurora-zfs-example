#!/usr/bin/bash
# Purpose:
#   Validate that the finished image contains a coherent kernel and ZFS stack
#   before CI publishes it. Any failure here should block publishing.
#
# Scope:
#   This script intentionally runs inside the image build, not on a booted
#   machine. It can inspect the assembled filesystem, RPM database, module tree,
#   generated initramfs, and userspace binaries, but it must not depend on
#   runtime hardware or loaded kernel modules.
#
# Not tested here:
#   Real ZFS pool import, `zpool status`, and `zfs --version`. Those belong in
#   post-rebase checks on the actual booted machine.
#
# Execution order is defined in main() at the bottom of the file:
# 1. check_kernel_tree
# 2. check_zfs_packages
# 3. check_zfs_modules
# 4. check_zfs_userspace
# 5. check_initramfs
# 6. check_rpm_payloads

set -euo pipefail

KERNEL=""
INITRAMFS_LIST=""

log() {
    # Use a stable prefix so failures are easy to find in GitHub Actions logs.
    printf 'post-check: %s\n' "$*"
}

fail() {
    # Print failures to stderr and stop the build immediately. Any failure here
    # means the image should not be published.
    printf 'post-check: ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    # Verify an expected userspace command exists somewhere in PATH.
    local cmd=$1
    command -v "${cmd}" >/dev/null 2>&1 || fail "required command not found: ${cmd}"
}

require_file() {
    # Verify an exact path exists.
    local path=$1
    [[ -e "${path}" ]] || fail "required file not found: ${path}"
}

require_glob() {
    # Verify at least one path matches a shell glob. This handles module files
    # that may be compressed or uncompressed, e.g. .ko, .ko.xz, or .ko.zst.
    local description=$1
    local pattern=$2

    if ! compgen -G "${pattern}" >/dev/null; then
        fail "required ${description} not found matching: ${pattern}"
    fi
}

require_rpm() {
    # Verify the RPM database says an exact package name is installed.
    local pkg=$1
    rpm -q "${pkg}" >/dev/null 2>&1 || fail "required RPM is not installed: ${pkg}"
}

require_rpm_glob() {
    # Verify the RPM database has at least one installed package matching a name
    # glob. This is useful for libraries whose ABI number is part of the package
    # name, such as libzfs6 or libnvpair3.
    local description=$1
    local pattern=$2
    local matches

    matches=$(rpm -qa "${pattern}")
    if [[ -z "${matches}" ]]; then
        fail "required RPM not installed for ${description}: ${pattern}"
    fi
}

require_ldd_resolved() {
    # Verify a dynamically linked executable has no missing shared libraries.
    # This is a build-safe userspace check because it only reads the binary and
    # dynamic linker metadata; it does not execute the tool's real functionality.
    local binary=$1
    local ldd_output

    require_file "${binary}"
    ldd_output=$(ldd "${binary}")
    if grep -q 'not found' <<<"${ldd_output}"; then
        printf '%s\n' "${ldd_output}" >&2
        fail "unresolved shared library dependency for ${binary}"
    fi
}

verify_rpm_payload() {
    # Verify critical kmod RPM payloads are not missing or content-modified.
    # Plain `rpm -V` is too strict for rpm-ostree/bootc images because file
    # owner, group, and timestamps may be normalized during image assembly.
    local pkg=$1
    local verify_output
    local line
    local flags

    verify_output=$(rpm -V "${pkg}" 2>&1 || true)
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue

        if [[ "${line}" == missing* ]]; then
            printf '%s\n' "${verify_output}" >&2
            fail "RPM verification found missing files for ${pkg}"
        fi

        # The first nine characters are rpm's verification flags. Example:
        # ".....UGT." means only user/group/time differ, which is acceptable here.
        flags=${line:0:9}
        if [[ "${flags}" =~ [SM5DLP] ]]; then
            printf '%s\n' "${verify_output}" >&2
            fail "RPM verification found payload changes for ${pkg}"
        fi
    done <<<"${verify_output}"
}

require_single_rpm_version() {
    # Verify a group of RPMs all report the same VERSION-RELEASE. This catches
    # split stacks like kmod-zfs from one OpenZFS release but libzfs/zfs from
    # another.
    local description=$1
    shift
    local versions

    mapfile -t versions < <(rpm -q --qf '%{VERSION}-%{RELEASE}\n' "$@" | sort -u)
    if [[ "${#versions[@]}" -ne 1 ]]; then
        printf 'post-check: %s versions found:\n' "${description}" >&2
        printf '  %s\n' "${versions[@]}" >&2
        fail "expected exactly one ${description} version"
    fi
}

check_kernel_tree() {
    log "checking kernel module tree"

    # The image should contain exactly one kernel module tree. Multiple trees can
    # hide accidental old kernel/kmod leftovers; zero means the kernel install failed.
    local kernel_dirs
    mapfile -t kernel_dirs < <(find /usr/lib/modules -maxdepth 1 -mindepth 1 -type d | sort -V)
    if [[ "${#kernel_dirs[@]}" -ne 1 ]]; then
        printf 'post-check: kernel module directories found:\n' >&2
        printf '  %s\n' "${kernel_dirs[@]}" >&2
        fail "expected exactly one kernel module directory, found ${#kernel_dirs[@]}"
    fi

    KERNEL=$(basename "${kernel_dirs[0]}")
    log "selected kernel: ${KERNEL}"

    require_rpm "kernel-core"
    require_rpm "kernel-modules"
    require_rpm "kernel-modules-core"
    require_rpm "kernel-modules-extra"

    # Make sure the kernel-core RPM agrees with /usr/lib/modules. If this mismatches,
    # the image can boot one kernel while carrying modules for another.
    if [[ "$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core)" != "${KERNEL}" ]]; then
        fail "kernel-core RPM does not match /usr/lib/modules kernel ${KERNEL}"
    fi
}

check_zfs_packages() {
    log "checking ZFS packages"

    require_rpm "zfs"
    require_rpm "kmod-zfs"
    require_rpm "python3-pyzfs"
    require_rpm_glob "libnvpair" "libnvpair*"
    require_rpm_glob "libuutil" "libuutil*"
    require_rpm_glob "libzfs" "libzfs*"
    require_rpm_glob "libzpool" "libzpool*"

    # Confirm all ZFS components come from one OpenZFS VERSION-RELEASE.
    local zfs_versioned_packages
    mapfile -t zfs_versioned_packages < <(
        {
            printf '%s\n' kmod-zfs zfs python3-pyzfs
            rpm -qa 'libnvpair[0-9]*' 'libuutil[0-9]*' 'libzfs[0-9]*' 'libzpool[0-9]*'
        } | sort -u
    )
    require_single_rpm_version "ZFS" "${zfs_versioned_packages[@]}"
}

check_zfs_modules() {
    log "checking ZFS kernel modules"

    require_glob "spl kernel module" "/usr/lib/modules/${KERNEL}/extra/zfs/spl.ko*"
    require_glob "zfs kernel module" "/usr/lib/modules/${KERNEL}/extra/zfs/zfs.ko*"

    # `modinfo -k` is safe at build time because it reads module files for the
    # named kernel; it does not load the module.
    depmod -a "${KERNEL}"
    modinfo -k "${KERNEL}" spl >/dev/null 2>&1 || fail "modinfo cannot find spl for ${KERNEL}"
    modinfo -k "${KERNEL}" zfs >/dev/null 2>&1 || fail "modinfo cannot find zfs for ${KERNEL}"
}

check_zfs_userspace() {
    log "checking ZFS userspace and integration files"

    require_command "zfs"
    require_command "zpool"
    require_command "zdb"
    require_command "zed"
    # Do not run `zfs --version` or `zpool --version` here. OpenZFS version
    # commands can try to query the kernel module version, but the image build
    # container is not booted with this image's kernel modules loaded.

    require_ldd_resolved "$(command -v zfs)"
    require_ldd_resolved "$(command -v zpool)"

    require_file "/usr/lib/modules-load.d/zfs.conf"
    grep -qx 'zfs' /usr/lib/modules-load.d/zfs.conf || fail "/usr/lib/modules-load.d/zfs.conf does not contain exactly 'zfs'"
    require_file "/usr/lib/systemd/system-generators/zfs-mount-generator"
    require_file "/usr/lib/systemd/system/zfs-import.target"
    require_file "/usr/lib/systemd/system/zfs-import-cache.service"
    require_file "/usr/lib/systemd/system/zfs-import-scan.service"
    require_file "/usr/lib/systemd/system/zfs-mount.service"
    require_file "/usr/lib/systemd/system/zfs-zed.service"
    require_file "/usr/lib/udev/rules.d/90-zfs.rules"
}

check_initramfs() {
    log "checking initramfs contents"

    # Verify the initramfs was generated and contains ZFS. This catches cases
    # where RPMs and modules exist on disk but the boot image would be missing them.
    require_file "/usr/lib/modules/${KERNEL}/initramfs.img"
    INITRAMFS_LIST=$(lsinitrd "/usr/lib/modules/${KERNEL}/initramfs.img")
    grep -q 'zfs\.ko' <<<"${INITRAMFS_LIST}" || fail "initramfs does not contain zfs.ko"
}

check_rpm_payloads() {
    log "checking RPM file verification for critical kmods"

    verify_rpm_payload "kmod-zfs"
}

main() {
    check_kernel_tree

    check_zfs_packages
    check_zfs_modules
    check_zfs_userspace

    check_initramfs
    check_rpm_payloads

    log "all checks passed"
}

main "$@"
