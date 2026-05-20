#!/usr/bin/bash
# Replace Aurora's base kernel with the selected Universal Blue akmods kernel,
# then install matching NVIDIA Open and ZFS kmods during the image build.

set -eoux pipefail

### aurora 02-install-common-kernel-akmods.sh ###

# Replace base-image kernel RPMs with the kernel from the selected akmods stream.
for pkg in kernel kernel{-core,-modules,-modules-core,-modules-extra}; do
    rpm --erase "${pkg}" --nodeps
done

# Remove kmods compiled for the base-image kernel; matching versions are installed below.
for pkg in kmod-xone xone-kmod-common kmod-v4l2loopback v4l2loopback kmod-nvidia; do
    if rpm -q "${pkg}" >/dev/null 2>&1; then
        rpm --erase "${pkg}" --nodeps
    fi
done

# Remove any inherited ZFS RPMs before deleting /usr/lib/modules. If the base
# image already has ZFS installed, removing the module tree without erasing the
# RPM first leaves rpmdb entries behind but no zfs.ko/spl.ko files. A later
# `dnf5 install` then reports kmod-zfs as "already installed" and does not
# restore the missing modules.
mapfile -t EXISTING_ZFS_PACKAGES < <(
    rpm -qa \
        'kmod-zfs' \
        'zfs' \
        'libnvpair*' \
        'libuutil*' \
        'libzfs*' \
        'libzpool*' \
        'python3-pyzfs' \
        | sort -u
)
if [[ "${#EXISTING_ZFS_PACKAGES[@]}" -gt 0 ]]; then
    rpm --erase "${EXISTING_ZFS_PACKAGES[@]}" --nodeps
fi

rm -rf /usr/lib/modules

dnf5 -y install \
    /tmp/kernel-rpms/kernel-[0-9]*.rpm \
    /tmp/kernel-rpms/kernel-core-*.rpm \
    /tmp/kernel-rpms/kernel-modules-*.rpm

# Prevent later updates from replacing the kernel without matching kmods.
dnf5 versionlock add kernel kernel-devel kernel-devel-matched kernel-core kernel-modules kernel-modules-core kernel-modules-extra

# Reinstall common akmods for the replacement kernel.
dnf5 -y install /tmp/rpms/{common,kmods}/*xone*.rpm
dnf5 -y install /tmp/rpms/{kmods,common}/*v4l2loopback*.rpm

# Install the ublue akmods Secure Boot public key.
mkdir -p /etc/pki/akmods/certs
curl -f "https://github.com/ublue-os/akmods/raw/refs/heads/main/certs/public_key.der" --retry 3 -Lo /etc/pki/akmods/certs/akmods-ublue.der
### aurora 02-install-common-kernel-akmods.sh ###

KERNEL=$(basename "$(find /usr/lib/modules -maxdepth 1 -mindepth 1 -type d | sort -V | tail -n 1)")

if [[ -z "${KERNEL}" ]]; then
    echo "ERROR: No kernel directory found in /usr/lib/modules" >&2
    exit 1
fi

# Install NVIDIA Open kmods and userspace packages from the matching akmods image.
if compgen -G "/tmp/rpms/nvidia-kmods/kmod-nvidia-${KERNEL}*.rpm" >/dev/null; then
    dnf5 -y install \
        /tmp/rpms/nvidia-kmods/kmod-nvidia-"${KERNEL}"*.rpm \
        /tmp/rpms/nvidia/*.x86_64.rpm \
        /tmp/rpms/nvidia/*.noarch.rpm

    if compgen -G "/tmp/rpms/ublue-os/*.rpm" >/dev/null; then
        dnf5 -y install /tmp/rpms/ublue-os/*.rpm
    fi

    # Core NVIDIA userspace packages should match kmod-nvidia exactly.
    mapfile -t NVIDIA_KMOD_VERSIONS < <(rpm -q --qf '%{VERSION}-%{RELEASE}\n' kmod-nvidia | sort -u)
    if [[ "${#NVIDIA_KMOD_VERSIONS[@]}" -ne 1 ]]; then
        printf 'ERROR: expected exactly one kmod-nvidia version, found:\n' >&2
        printf '  %s\n' "${NVIDIA_KMOD_VERSIONS[@]}" >&2
        exit 1
    fi
    NVIDIA_DRIVER_VERSION="${NVIDIA_KMOD_VERSIONS[0]}"

    NVIDIA_DRIVER_PACKAGES=(
        libnvidia-cfg
        libnvidia-fbc
        libnvidia-gpucomp
        libnvidia-ml
        nvidia-driver
        nvidia-driver-cuda
        nvidia-driver-cuda-libs
        nvidia-driver-libs
        nvidia-kmod-common
        nvidia-libXNVCtrl
        nvidia-modprobe
        nvidia-persistenced
        nvidia-settings
        nvidia-xconfig
        xorg-x11-nvidia
    )

    for pkg in "${NVIDIA_DRIVER_PACKAGES[@]}"; do
        if rpm -q "${pkg}" >/dev/null 2>&1; then
            mapfile -t pkg_versions < <(rpm -q --qf '%{VERSION}-%{RELEASE}\n' "${pkg}" | sort -u)
            if [[ "${#pkg_versions[@]}" -ne 1 || "${pkg_versions[0]}" != "${NVIDIA_DRIVER_VERSION}" ]]; then
                printf 'ERROR: %s does not match kmod-nvidia version %s\n' "${pkg}" "${NVIDIA_DRIVER_VERSION}" >&2
                printf '  %s versions found:\n' "${pkg}" >&2
                printf '    %s\n' "${pkg_versions[@]}" >&2
                exit 1
            fi
        fi
    done

    # Aurora's NVIDIA install flow edits the RPM-owned dracut config so the
    # NVIDIA driver is force-loaded into the generated initramfs. Reinstalling
    # the NVIDIA RPMs above can restore the package default (`omit_drivers`),
    # so reapply only those upstream dracut edits before the final
    # dracut build below. Other Aurora NVIDIA integration is inherited from the
    # base image and is not re-run here.
    NVIDIA_DRACUT_CONF=/usr/lib/dracut/dracut.conf.d/99-nvidia.conf
    if [[ ! -f "${NVIDIA_DRACUT_CONF}" ]]; then
        printf 'ERROR: expected NVIDIA dracut config at %s\n' "${NVIDIA_DRACUT_CONF}" >&2
        exit 1
    fi

    sed -i 's@omit_drivers@force_drivers@g' "${NVIDIA_DRACUT_CONF}"
    if ! grep -q 'i915 amdgpu nvidia' "${NVIDIA_DRACUT_CONF}"; then
        sed -i 's@ nvidia @ i915 amdgpu nvidia @g' "${NVIDIA_DRACUT_CONF}"
    fi

    if ! grep -q force_drivers "${NVIDIA_DRACUT_CONF}"; then
        printf 'ERROR: %s does not force-load NVIDIA drivers\n' "${NVIDIA_DRACUT_CONF}" >&2
        exit 1
    fi
    if ! grep -q 'i915 amdgpu nvidia' "${NVIDIA_DRACUT_CONF}"; then
        printf 'ERROR: %s does not preload i915/amdgpu before NVIDIA\n' "${NVIDIA_DRACUT_CONF}" >&2
        exit 1
    fi
fi

# Install ZFS kmod and userspace packages for the replacement kernel.
ZFS_RPMS=(
    /tmp/rpms/kmods/zfs/kmod-zfs-"${KERNEL}"*.rpm
    /tmp/rpms/kmods/zfs/libnvpair[0-9]-*.rpm
    /tmp/rpms/kmods/zfs/libuutil[0-9]-*.rpm
    /tmp/rpms/kmods/zfs/libzfs[0-9]-*.rpm
    /tmp/rpms/kmods/zfs/libzpool[0-9]-*.rpm
    /tmp/rpms/kmods/zfs/python3-pyzfs-*.rpm
    /tmp/rpms/kmods/zfs/zfs-*.rpm
    pv
)

dnf5 -y install "${ZFS_RPMS[@]}"

# Register modules and build an initramfs for the replacement kernel.
depmod -a -v "${KERNEL}"

ZFS_MODULE_DIR="/usr/lib/modules/${KERNEL}/extra/zfs"
for module in spl zfs; do
    if ! compgen -G "${ZFS_MODULE_DIR}/${module}.ko*" >/dev/null; then
        printf 'ERROR: expected %s module under %s after installing kmod-zfs\n' "${module}" "${ZFS_MODULE_DIR}" >&2
        rpm -ql kmod-zfs >&2 || true
        exit 1
    fi

    if ! modinfo -k "${KERNEL}" "${module}" >/dev/null 2>&1; then
        printf 'ERROR: modinfo cannot find %s for kernel %s after depmod\n' "${module}" "${KERNEL}" >&2
        exit 1
    fi
done

echo "zfs" >/usr/lib/modules-load.d/zfs.conf

export DRACUT_NO_XATTR=1
/usr/bin/dracut --no-hostonly --kver "${KERNEL}" --reproducible -v --add "ostree fido2 tpm2-tss pkcs11 pcsc" -f "/lib/modules/${KERNEL}/initramfs.img"
chmod 0600 "/lib/modules/${KERNEL}/initramfs.img"
