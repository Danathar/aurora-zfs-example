#!/usr/bin/bash
# Validate that the finished image contains a coherent kernel, ZFS, and NVIDIA
# stack before CI publishes it.

set -euo pipefail

log() {
    printf 'post-check: %s\n' "$*"
}

fail() {
    printf 'post-check: ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    local cmd=$1
    command -v "${cmd}" >/dev/null 2>&1 || fail "required command not found: ${cmd}"
}

require_file() {
    local path=$1
    [[ -e "${path}" ]] || fail "required file not found: ${path}"
}

require_glob() {
    local description=$1
    local pattern=$2

    if ! compgen -G "${pattern}" >/dev/null; then
        fail "required ${description} not found matching: ${pattern}"
    fi
}

require_rpm() {
    local pkg=$1
    rpm -q "${pkg}" >/dev/null 2>&1 || fail "required RPM is not installed: ${pkg}"
}

require_rpm_glob() {
    local description=$1
    local pattern=$2
    local matches

    matches=$(rpm -qa "${pattern}")
    if [[ -z "${matches}" ]]; then
        fail "required RPM not installed for ${description}: ${pattern}"
    fi
}

require_ldd_resolved() {
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
    local pkg=$1
    local verify_output
    local line
    local flags

    # rpm-ostree/bootc images can normalize ownership, group, or timestamps in
    # ways that make plain `rpm -V` too noisy. Treat missing files, content
    # changes, mode changes, symlink changes, device changes, and capability
    # changes as failures, but ignore owner/group/timestamp-only differences.
    verify_output=$(rpm -V "${pkg}" 2>&1 || true)
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue

        if [[ "${line}" == missing* ]]; then
            printf '%s\n' "${verify_output}" >&2
            fail "RPM verification found missing files for ${pkg}"
        fi

        flags=${line:0:9}
        if [[ "${flags}" =~ [SM5DLP] ]]; then
            printf '%s\n' "${verify_output}" >&2
            fail "RPM verification found payload changes for ${pkg}"
        fi
    done <<<"${verify_output}"
}

require_single_rpm_version() {
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

log "checking kernel module tree"
mapfile -t KERNEL_DIRS < <(find /usr/lib/modules -maxdepth 1 -mindepth 1 -type d | sort -V)
if [[ "${#KERNEL_DIRS[@]}" -ne 1 ]]; then
    printf 'post-check: kernel module directories found:\n' >&2
    printf '  %s\n' "${KERNEL_DIRS[@]}" >&2
    fail "expected exactly one kernel module directory, found ${#KERNEL_DIRS[@]}"
fi

KERNEL=$(basename "${KERNEL_DIRS[0]}")
log "selected kernel: ${KERNEL}"

require_rpm "kernel-core"
require_rpm "kernel-modules"
require_rpm "kernel-modules-core"
require_rpm "kernel-modules-extra"

if [[ "$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core)" != "${KERNEL}" ]]; then
    fail "kernel-core RPM does not match /usr/lib/modules kernel ${KERNEL}"
fi

log "checking ZFS kernel modules and userspace"
require_rpm "zfs"
require_rpm "kmod-zfs"
require_rpm "python3-pyzfs"
require_rpm_glob "libnvpair" "libnvpair*"
require_rpm_glob "libuutil" "libuutil*"
require_rpm_glob "libzfs" "libzfs*"
require_rpm_glob "libzpool" "libzpool*"

mapfile -t ZFS_VERSIONED_PACKAGES < <(
    {
        printf '%s\n' kmod-zfs zfs python3-pyzfs
        rpm -qa 'libnvpair[0-9]*' 'libuutil[0-9]*' 'libzfs[0-9]*' 'libzpool[0-9]*'
    } | sort -u
)
require_single_rpm_version "ZFS" "${ZFS_VERSIONED_PACKAGES[@]}"

require_glob "spl kernel module" "/usr/lib/modules/${KERNEL}/extra/zfs/spl.ko*"
require_glob "zfs kernel module" "/usr/lib/modules/${KERNEL}/extra/zfs/zfs.ko*"

depmod -a "${KERNEL}"
modinfo -k "${KERNEL}" spl >/dev/null 2>&1 || fail "modinfo cannot find spl for ${KERNEL}"
modinfo -k "${KERNEL}" zfs >/dev/null 2>&1 || fail "modinfo cannot find zfs for ${KERNEL}"

require_command "zfs"
require_command "zpool"
require_command "zdb"
require_command "zed"
# Do not run `zfs --version` or `zpool --version` here. OpenZFS version
# commands can try to query the kernel module version, but the image build
# container is not booted with this image's kernel modules loaded. Package,
# binary, library, module-file, and `modinfo -k` checks are the build-safe
# userspace validation.

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

log "checking NVIDIA kernel modules and userspace"
require_rpm "kmod-nvidia"
require_rpm "nvidia-driver"
require_rpm "nvidia-driver-libs"
require_rpm "nvidia-driver-cuda"
require_rpm "nvidia-driver-cuda-libs"
require_rpm "nvidia-kmod-common"
require_rpm "nvidia-modprobe"
require_rpm "nvidia-persistenced"
require_rpm "libnvidia-ml"

require_single_rpm_version \
    "NVIDIA driver" \
    kmod-nvidia \
    libnvidia-ml \
    nvidia-driver \
    nvidia-driver-libs \
    nvidia-driver-cuda \
    nvidia-driver-cuda-libs \
    nvidia-kmod-common \
    nvidia-modprobe \
    nvidia-persistenced

for module in nvidia nvidia-drm nvidia-modeset nvidia-uvm; do
    require_glob "${module} kernel module" "/usr/lib/modules/${KERNEL}/extra/nvidia/${module}.ko*"
    modinfo -k "${KERNEL}" "${module}" >/dev/null 2>&1 || fail "modinfo cannot find ${module} for ${KERNEL}"
done

require_command "nvidia-smi"
require_command "nvidia-modprobe"
# Do not run `nvidia-smi` here. The image build container does not have a real
# NVIDIA device or this image's NVIDIA kernel modules loaded, so nvidia-smi can
# fail even when the userspace binary and libraries are correctly installed.

require_ldd_resolved "$(command -v nvidia-smi)"
require_ldd_resolved "$(command -v nvidia-modprobe)"
require_glob "libnvidia-ml" "/usr/lib64/libnvidia-ml.so*"
require_glob "libcuda" "/usr/lib64/libcuda.so*"

NVIDIA_DRACUT_CONF=/usr/lib/dracut/dracut.conf.d/99-nvidia.conf
require_file "${NVIDIA_DRACUT_CONF}"
grep -q force_drivers "${NVIDIA_DRACUT_CONF}" || fail "${NVIDIA_DRACUT_CONF} does not force-load NVIDIA drivers"
grep -q 'i915 amdgpu nvidia' "${NVIDIA_DRACUT_CONF}" || fail "${NVIDIA_DRACUT_CONF} does not preload i915/amdgpu before NVIDIA"

require_file "/usr/lib/modules/${KERNEL}/initramfs.img"
INITRAMFS_LIST=$(lsinitrd "/usr/lib/modules/${KERNEL}/initramfs.img")
grep -q 'zfs\.ko' <<<"${INITRAMFS_LIST}" || fail "initramfs does not contain zfs.ko"
grep -q 'nvidia\.ko' <<<"${INITRAMFS_LIST}" || fail "initramfs does not contain nvidia.ko"

log "checking RPM file verification for critical kmods"
verify_rpm_payload "kmod-zfs"
verify_rpm_payload "kmod-nvidia"

log "all checks passed"
