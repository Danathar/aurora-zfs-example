#!/usr/bin/bash
# Validate that the finished image contains a coherent kernel, ZFS, and NVIDIA
# stack before CI publishes it.
#
# This script intentionally runs inside the image build, not on a booted machine.
# That means it can inspect the assembled filesystem, RPM database, module tree,
# generated initramfs, and userspace binaries, but it must not depend on runtime
# hardware or loaded kernel modules. In particular, avoid commands like
# `zpool status`, `zfs --version`, or `nvidia-smi` because those can query the
# running build container's kernel/devices rather than the image being produced.
#
# Execution order is defined in main() at the bottom of the file:
# 1. check_kernel_tree
# 2. check_zfs_packages
# 3. check_zfs_modules
# 4. check_zfs_userspace
# 5. check_nvidia_packages
# 6. check_nvidia_modules
# 7. check_nvidia_userspace
# 8. check_nvidia_dracut_config
# 9. check_initramfs
# 10. check_rpm_payloads

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
    # This only checks presence; runtime behavior may still require real devices
    # or loaded kernel modules and is intentionally left for post-rebase checks.
    local cmd=$1
    command -v "${cmd}" >/dev/null 2>&1 || fail "required command not found: ${cmd}"
}

require_file() {
    # Verify an exact path exists. This is used for files that should have a
    # stable location in the final image, such as systemd units or initramfs.
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
    #
    # Plain `rpm -V` is too strict for rpm-ostree/bootc images because file
    # owner, group, and timestamps may be normalized during image assembly. Those
    # differences are noisy and not evidence that a module is broken.
    #
    # We do fail on:
    # - missing files
    # - size changes (S)
    # - mode changes (M)
    # - checksum/content changes (5)
    # - device major/minor changes (D)
    # - symlink target changes (L)
    # - capabilities changes (P)
    #
    # We ignore:
    # - user owner differences (U)
    # - group owner differences (G)
    # - mtime differences (T)
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
    # another, or kmod-nvidia/userspace driver skew.
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

    # Use the module directory as the source of truth for the kernel version that
    # dracut and modinfo should validate.
    KERNEL=$(basename "${kernel_dirs[0]}")
    log "selected kernel: ${KERNEL}"

    # These are the core Fedora kernel packages expected after zfs.sh replaces the
    # base image kernel with the selected Universal Blue akmods kernel.
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

    # Required ZFS packages. The exact ABI-numbered library package names can change
    # over time, so libraries are checked with RPM globs below.
    require_rpm "zfs"
    require_rpm "kmod-zfs"
    require_rpm "python3-pyzfs"
    require_rpm_glob "libnvpair" "libnvpair*"
    require_rpm_glob "libuutil" "libuutil*"
    require_rpm_glob "libzfs" "libzfs*"
    require_rpm_glob "libzpool" "libzpool*"

    # Confirm all ZFS components come from one OpenZFS VERSION-RELEASE. This is
    # mostly defensive because zfs.sh installs them from the same akmods-zfs artifact,
    # but it catches stale or mixed RPMs if upstream contents or local globs change.
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

    # Check that the actual ZFS module files exist for the selected kernel. This
    # catches the earlier bug where RPM metadata said kmod-zfs was installed but
    # zfs.ko/spl.ko had been deleted with /usr/lib/modules.
    require_glob "spl kernel module" "/usr/lib/modules/${KERNEL}/extra/zfs/spl.ko*"
    require_glob "zfs kernel module" "/usr/lib/modules/${KERNEL}/extra/zfs/zfs.ko*"

    # Rebuild module dependency metadata and verify modinfo can resolve the ZFS
    # modules for the image kernel. `modinfo -k` is safe at build time because it
    # reads module files for the named kernel; it does not load the module.
    depmod -a "${KERNEL}"
    modinfo -k "${KERNEL}" spl >/dev/null 2>&1 || fail "modinfo cannot find spl for ${KERNEL}"
    modinfo -k "${KERNEL}" zfs >/dev/null 2>&1 || fail "modinfo cannot find zfs for ${KERNEL}"
}

check_zfs_userspace() {
    log "checking ZFS userspace and integration files"

    # ZFS userspace commands should be present. Do not execute commands that query
    # pool or kernel state; the build container is not the final booted system.
    require_command "zfs"
    require_command "zpool"
    require_command "zdb"
    require_command "zed"
    # Do not run `zfs --version` or `zpool --version` here. OpenZFS version
    # commands can try to query the kernel module version, but the image build
    # container is not booted with this image's kernel modules loaded. Package,
    # binary, library, module-file, and `modinfo -k` checks are the build-safe
    # userspace validation.

    # Verify key ZFS binaries can find their shared libraries.
    require_ldd_resolved "$(command -v zfs)"
    require_ldd_resolved "$(command -v zpool)"

    # Check the boot/integration files that should be present after installing ZFS.
    # These checks do not guarantee a real pool imports, but they catch missing units,
    # udev rules, or module-load config before publishing the image.
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

check_nvidia_packages() {
    log "checking NVIDIA packages"

    # Required core NVIDIA Open driver packages. This intentionally checks only the
    # driver stack packages with matching driver version semantics, not unrelated
    # NVIDIA-adjacent packages such as firmware or container-toolkit pieces.
    require_rpm "kmod-nvidia"
    require_rpm "nvidia-driver"
    require_rpm "nvidia-driver-libs"
    require_rpm "nvidia-driver-cuda"
    require_rpm "nvidia-driver-cuda-libs"
    require_rpm "nvidia-kmod-common"
    require_rpm "nvidia-modprobe"
    require_rpm "nvidia-persistenced"
    require_rpm "libnvidia-ml"

    # Verify the core NVIDIA userspace packages match the installed kmod-nvidia
    # VERSION-RELEASE. A mismatch here can produce a working-looking image where
    # nvidia-smi, CUDA, or the kernel driver fail after boot.
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
}

check_nvidia_modules() {
    log "checking NVIDIA kernel modules"

    # Check NVIDIA module files and module metadata for the selected image kernel.
    # As with ZFS, modinfo reads metadata and does not require a GPU or loaded module.
    local module
    for module in nvidia nvidia-drm nvidia-modeset nvidia-uvm; do
        require_glob "${module} kernel module" "/usr/lib/modules/${KERNEL}/extra/nvidia/${module}.ko*"
        modinfo -k "${KERNEL}" "${module}" >/dev/null 2>&1 || fail "modinfo cannot find ${module} for ${KERNEL}"
    done
}

check_nvidia_userspace() {
    log "checking NVIDIA userspace"

    # NVIDIA userspace commands should exist, but do not run nvidia-smi in the build.
    require_command "nvidia-smi"
    require_command "nvidia-modprobe"
    # Do not run `nvidia-smi` here. The image build container does not have a real
    # NVIDIA device or this image's NVIDIA kernel modules loaded, so nvidia-smi can
    # fail even when the userspace binary and libraries are correctly installed.

    # Verify key NVIDIA binaries and libraries exist and link correctly.
    require_ldd_resolved "$(command -v nvidia-smi)"
    require_ldd_resolved "$(command -v nvidia-modprobe)"
    require_glob "libnvidia-ml" "/usr/lib64/libnvidia-ml.so*"
    require_glob "libcuda" "/usr/lib64/libcuda.so*"
}

check_nvidia_dracut_config() {
    log "checking NVIDIA dracut config"

    # The NVIDIA RPM-owned dracut config can be reset by reinstalling packages.
    # zfs.sh should reapply Aurora/Universal Blue's desired behavior: force-load
    # NVIDIA and preload integrated GPU drivers first.
    local nvidia_dracut_conf=/usr/lib/dracut/dracut.conf.d/99-nvidia.conf
    require_file "${nvidia_dracut_conf}"
    grep -q force_drivers "${nvidia_dracut_conf}" || fail "${nvidia_dracut_conf} does not force-load NVIDIA drivers"
    grep -q 'i915 amdgpu nvidia' "${nvidia_dracut_conf}" || fail "${nvidia_dracut_conf} does not preload i915/amdgpu before NVIDIA"
}

check_initramfs() {
    log "checking initramfs contents"

    # Verify the initramfs was generated and contains both stacks. This catches cases
    # where RPMs and modules exist on disk but the boot image would be missing them.
    require_file "/usr/lib/modules/${KERNEL}/initramfs.img"
    INITRAMFS_LIST=$(lsinitrd "/usr/lib/modules/${KERNEL}/initramfs.img")
    grep -q 'zfs\.ko' <<<"${INITRAMFS_LIST}" || fail "initramfs does not contain zfs.ko"
    grep -q 'nvidia\.ko' <<<"${INITRAMFS_LIST}" || fail "initramfs does not contain nvidia.ko"
}

check_rpm_payloads() {
    log "checking RPM file verification for critical kmods"

    # Final payload sanity check for the two kmod RPMs that matter most to this repo.
    # This catches missing or altered module files even if earlier path/glob checks
    # accidentally missed a future packaging layout change.
    verify_rpm_payload "kmod-zfs"
    verify_rpm_payload "kmod-nvidia"
}

main() {
    check_kernel_tree

    check_zfs_packages
    check_zfs_modules
    check_zfs_userspace

    check_nvidia_packages
    check_nvidia_modules
    check_nvidia_userspace
    check_nvidia_dracut_config

    check_initramfs
    check_rpm_payloads

    log "all checks passed"
}

main "$@"
