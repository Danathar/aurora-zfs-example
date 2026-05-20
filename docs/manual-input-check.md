# Fedora Release Input Check

This repo intentionally does not include scripts or local build helpers for
checking upstream inputs. Before moving to the next Fedora major release, check
the Universal Blue package tags yourself.

## What Must Match

For a Fedora release `N`, these inputs need to exist and line up:

```text
ghcr.io/ublue-os/aurora-dx-nvidia-open:stable
ghcr.io/ublue-os/akmods:coreos-stable-N-x86_64
ghcr.io/ublue-os/akmods-zfs:coreos-stable-N-x86_64
ghcr.io/ublue-os/akmods-nvidia-open:coreos-stable-N-x86_64
```

The kernel provided by `akmods:coreos-stable-N-x86_64` must have matching ZFS
and NVIDIA Open kmods in the corresponding `akmods-zfs` and
`akmods-nvidia-open` images.

ZFS userspace RPMs are installed from the same `akmods-zfs` artifact as
`kmod-zfs`, so they should match automatically. If manually inspecting the
artifact, check that it contains one coherent OpenZFS release for `kmod-zfs`,
`zfs`, `libzfs`, `libzpool`, `libnvpair`, `libuutil`, and `python3-pyzfs`.

NVIDIA userspace RPMs are installed from the same `akmods-nvidia-open` artifact
as `kmod-nvidia`. The build already verifies that the core NVIDIA userspace
packages match the installed `kmod-nvidia` version, but when manually checking a
new Fedora release, confirm the artifact appears to contain one coherent NVIDIA
driver release.

## How To Check The Inputs

These checks can be run from any shell where you have `skopeo` and `podman`
available. They inspect upstream Universal Blue artifact images before you edit
`Containerfile` and push a Fedora release bump to GitHub; they do not require a
local clone of this repository.

Set the Fedora release you want to inspect:

```bash
FEDORA_VERSION=45
AKMODS_TAG="coreos-stable-${FEDORA_VERSION}-x86_64"
```

Check that the expected artifact tags exist:

```bash
skopeo inspect "docker://ghcr.io/ublue-os/akmods:${AKMODS_TAG}" >/dev/null
skopeo inspect "docker://ghcr.io/ublue-os/akmods-zfs:${AKMODS_TAG}" >/dev/null
skopeo inspect "docker://ghcr.io/ublue-os/akmods-nvidia-open:${AKMODS_TAG}" >/dev/null
```

Check the kernel version published by the base akmods artifact:

```bash
podman run --rm --pull=always \
  --entrypoint /usr/bin/bash \
  "ghcr.io/ublue-os/akmods:${AKMODS_TAG}" \
  -lc 'rpm -qp --qf "%{VERSION}-%{RELEASE}.%{ARCH}\n" /kernel-rpms/kernel-core-*.rpm'
```

Save that value as the kernel you expect ZFS and NVIDIA to match. For example:

```bash
KERNEL="6.19.14-101.fc44.x86_64"
```

Check that the ZFS artifact has a kmod for that exact kernel and one coherent
OpenZFS userspace release:

```bash
podman run --rm --pull=always \
  --entrypoint /usr/bin/bash \
  "ghcr.io/ublue-os/akmods-zfs:${AKMODS_TAG}" \
  -lc '
    echo "ZFS kmods:"
    for rpm in /rpms/kmods/zfs/kmod-zfs-*.rpm; do
      basename "${rpm}"
      rpm -qp --qf "  %{NAME} %{VERSION}-%{RELEASE}\n" "${rpm}"
      rpm -qpl "${rpm}" | grep "/lib/modules/"
    done

    echo
    echo "ZFS userspace:"
    rpm -qp --qf "%{NAME} %{VERSION}-%{RELEASE}\n" \
      /rpms/kmods/zfs/zfs-*.rpm \
      /rpms/kmods/zfs/libzfs*.rpm \
      /rpms/kmods/zfs/libzpool*.rpm \
      /rpms/kmods/zfs/libnvpair*.rpm \
      /rpms/kmods/zfs/libuutil*.rpm \
      /rpms/kmods/zfs/python3-pyzfs-*.rpm \
      | sort -u
  '
```

Good signs:

- the `kmod-zfs` RPM filename includes the expected kernel version
- `kmod-zfs`, `zfs`, the ZFS libraries, and `python3-pyzfs` show the same
  OpenZFS version/release
- there is not a mixture of old and new OpenZFS releases in the same artifact

Check that the NVIDIA Open artifact has a kmod for that exact kernel and one
coherent NVIDIA driver release:

```bash
podman run --rm --pull=always \
  --entrypoint /usr/bin/bash \
  "ghcr.io/ublue-os/akmods-nvidia-open:${AKMODS_TAG}" \
  -lc '
    echo "NVIDIA kmods:"
    for rpm in /rpms/kmods/kmod-nvidia-*.rpm; do
      basename "${rpm}"
      rpm -qp --qf "  %{NAME} %{VERSION}-%{RELEASE}\n" "${rpm}"
      rpm -qpl "${rpm}" | grep "/lib/modules/"
    done

    echo
    echo "NVIDIA userspace:"
    rpm -qp --qf "%{NAME} %{VERSION}-%{RELEASE}\n" \
      /rpms/nvidia/libnvidia-*.rpm \
      /rpms/nvidia/nvidia-*.rpm \
      /rpms/nvidia/xorg-x11-nvidia*.rpm \
      | sort -u
  '
```

Good signs:

- the `kmod-nvidia` RPM filename includes the expected kernel version
- core NVIDIA userspace packages show the same NVIDIA driver version/release as
  `kmod-nvidia`
- there is not a mixture of old and new NVIDIA driver releases in the same
  artifact

After these manual checks, still let GitHub Actions build the image. The build's
`post-check.sh` performs the final validation against the actual assembled image
before it is published.

## When Fedora `N+1` Is Released

Do not immediately change `FEDORA_VERSION`.

First check that the next-release tags exist. For example, before moving from
Fedora 44 to Fedora 45, check for:

```text
ghcr.io/ublue-os/akmods:coreos-stable-45-x86_64
ghcr.io/ublue-os/akmods-zfs:coreos-stable-45-x86_64
ghcr.io/ublue-os/akmods-nvidia-open:coreos-stable-45-x86_64
```

Then check that ZFS and NVIDIA Open have kmods for the same kernel release that
`akmods` is publishing. Userspace should come from those same ZFS and NVIDIA
artifact images and should represent the same ZFS/NVIDIA releases as their
matching kmods.

If they line up, update the `Containerfile`:

```Dockerfile
ARG FEDORA_VERSION=45
```

If they do not line up, leave `FEDORA_VERSION` alone and stay on the last
working image.

## Base Image Guard

The base image tracks Aurora DX NVIDIA Open stable:

```Dockerfile
ARG AURORA_IMAGE=ghcr.io/ublue-os/aurora-dx-nvidia-open
ARG AURORA_TAG=stable
```

The `Containerfile` fails the build if `aurora-dx-nvidia-open:stable` has moved to
a different Fedora release than `FEDORA_VERSION`. That prevents accidentally
building a mixed-release image while still allowing stable-channel updates.
