#!/usr/bin/bash
# Install matching ZFS kmods/userspace packages after the replacement kernel is
# installed, then build the final initramfs.

set -eoux pipefail

KERNEL=$(basename "$(find /usr/lib/modules -maxdepth 1 -mindepth 1 -type d | sort -V | tail -n 1)")

if [[ -z "${KERNEL}" ]]; then
    echo "ERROR: No kernel directory found in /usr/lib/modules" >&2
    exit 1
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

# Register modules and build an initramfs for the replacement kernel after all
# kmods, including NVIDIA from nvidia.sh, have been installed.
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
