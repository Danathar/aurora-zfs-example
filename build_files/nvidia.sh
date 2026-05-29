#!/usr/bin/bash
# Install matching NVIDIA Open kmods/userspace packages and restore Aurora's
# NVIDIA dracut configuration after the replacement kernel is installed.

set -eoux pipefail

KERNEL=$(basename "$(find /usr/lib/modules -maxdepth 1 -mindepth 1 -type d | sort -V | tail -n 1)")

if [[ -z "${KERNEL}" ]]; then
    echo "ERROR: No kernel directory found in /usr/lib/modules" >&2
    exit 1
fi

# Install NVIDIA Open kmods and userspace packages from the matching akmods image.
if ! compgen -G "/tmp/rpms/nvidia-kmods/kmod-nvidia-${KERNEL}*.rpm" >/dev/null; then
    printf 'ERROR: no NVIDIA Open kmod RPM found for kernel %s\n' "${KERNEL}" >&2
    find /tmp/rpms/nvidia-kmods -maxdepth 1 -type f -name 'kmod-nvidia-*.rpm' -print >&2 || true
    exit 1
fi

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
    nvidia-driver-common
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
# so reapply only those upstream dracut edits before the final dracut build.
# Other Aurora NVIDIA integration is inherited from the base image and is not
# re-run here.
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
