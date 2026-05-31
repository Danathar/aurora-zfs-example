#!/usr/bin/bash
# Replace Aurora's base kernel with the selected Universal Blue akmods kernel,
# then reinstall common akmods that must match that kernel.

set -eoux pipefail

### aurora 02-install-common-kernel-akmods.sh ###

# Replace base-image kernel RPMs with the kernel from the selected akmods stream.
# Include kernel-devel packages so developer tooling does not keep stale headers
# from the Aurora base image after the runtime kernel has been replaced.
for pkg in kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra kernel-devel kernel-devel-matched; do
    if rpm -q "${pkg}" >/dev/null 2>&1; then
        rpm --erase "${pkg}" --nodeps
    fi
done

# Remove kmods compiled for the base-image kernel; matching versions are installed below
# or by the dedicated ZFS script that runs after the replacement kernel is in place.
for pkg in kmod-xone xone-kmod-common kmod-v4l2loopback v4l2loopback; do
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
    /tmp/kernel-rpms/kernel-devel-[0-9]*.rpm \
    /tmp/kernel-rpms/kernel-devel-matched-*.rpm \
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
