# Fedora Release Input Check

This repo intentionally does not include scripts or local build helpers for
checking upstream inputs. Before moving to the next Fedora major release, check
the Universal Blue package tags yourself.

## What Must Match

For a Fedora release `N`, these inputs need to exist and line up:

```text
ghcr.io/ublue-os/aurora-nvidia-open:stable
ghcr.io/ublue-os/akmods:coreos-stable-N-x86_64
ghcr.io/ublue-os/akmods-zfs:coreos-stable-N-x86_64
ghcr.io/ublue-os/akmods-nvidia-open:coreos-stable-N-x86_64
```

The kernel provided by `akmods:coreos-stable-N-x86_64` must have matching ZFS
and NVIDIA Open kmods in the corresponding `akmods-zfs` and
`akmods-nvidia-open` images.

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
`akmods` is publishing.

If they line up, update the `Containerfile`:

```Dockerfile
ARG FEDORA_VERSION=45
```

If they do not line up, leave `FEDORA_VERSION` alone and stay on the last
working image.

## Base Image Guard

The base image tracks Aurora stable:

```Dockerfile
ARG AURORA_IMAGE=ghcr.io/ublue-os/aurora-nvidia-open
ARG AURORA_TAG=stable
```

The `Containerfile` fails the build if `aurora-nvidia-open:stable` has moved to
a different Fedora release than `FEDORA_VERSION`. That prevents accidentally
building a mixed-release image while still allowing stable-channel updates.
