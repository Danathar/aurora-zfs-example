# Aurora developer image with ZFS and NVIDIA

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/Danathar/aurora-zfs-simple)

[![build](https://github.com/danathar/aurora-zfs-simple/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/danathar/aurora-zfs-simple/actions/workflows/build.yml)

This is a small, GitHub-built Aurora DX NVIDIA Open developer image that adds ZFS back using
upstream Universal Blue akmods artifacts.

It is intended for users who already understand ZFS and kernel-module matching.
The expected install path is to rebase an existing Aurora
install to the published container image.

[Discussion](https://github.com/ublue-os/aurora/issues/1765)

## Switching To This Image

After the GitHub Actions workflow publishes your fork's image, switch an
existing Aurora install to it:

```bash
sudo bootc switch ghcr.io/<owner>/<repo>:latest
```

For this repository, that would be:

```bash
sudo bootc switch ghcr.io/danathar/aurora-zfs-simple:latest
```

Reboot after switching.

## Switching Back To Upstream

To go back to upstream Aurora DX NVIDIA Open stable:

```bash
sudo bootc switch ghcr.io/ublue-os/aurora-dx-nvidia-open:stable
```

Reboot after switching back.

## What It Uses

- base image: `ghcr.io/ublue-os/aurora-dx-nvidia-open:stable`
- kernel RPMs: `ghcr.io/ublue-os/akmods`
- ZFS RPMs: `ghcr.io/ublue-os/akmods-zfs`
- NVIDIA Open RPMs: `ghcr.io/ublue-os/akmods-nvidia-open`

## Important Design Detail

This image does not keep Aurora's original kernel packages.

`build_files/zfs.sh` removes the base kernel and installs the kernel from the
selected Universal Blue `akmods` stream. It then installs matching ZFS and
NVIDIA Open kmods from the corresponding upstream akmods images. These usually
line up with the base image already, but reinstalling them from the selected
stream ensures the kernel, ZFS, and NVIDIA Open module RPMs all come from the
same matching Universal Blue akmods inputs.

For NVIDIA Open builds, the build also verifies that the core NVIDIA userspace
driver packages match the installed `kmod-nvidia` version. NVIDIA-adjacent
packages with unrelated versioning, such as firmware or container-toolkit
packages, are not part of that version check.

The Fedora release is controlled here:

```Dockerfile
ARG FEDORA_VERSION=44
```

The base image intentionally tracks Aurora DX NVIDIA Open stable:

```Dockerfile
ARG AURORA_IMAGE=ghcr.io/ublue-os/aurora-dx-nvidia-open
ARG AURORA_TAG=stable
```

The `Containerfile` has a guard that fails the build if the stable base image's
Fedora version does not match `FEDORA_VERSION`.

For the manual release-readiness checklist, see
[`docs/manual-input-check.md`](./docs/manual-input-check.md).

## Before Moving Fedora Releases

Do not change `FEDORA_VERSION` just because a new Fedora release exists.

Before moving to the next major Fedora release, confirm the matching upstream
akmods, ZFS, and NVIDIA Open tags exist and publish modules for the same kernel.
The checklist lives in [`docs/manual-input-check.md`](./docs/manual-input-check.md).

## Non-NVIDIA Users

If you do not need NVIDIA but still want the developer image, make this an Aurora DX + ZFS image:

1. In `Containerfile`, change the base image:

   ```Dockerfile
   ARG AURORA_IMAGE=ghcr.io/ublue-os/aurora-dx
   ```

2. Remove the NVIDIA Open akmods stage:

   ```Dockerfile
   FROM ghcr.io/ublue-os/akmods-nvidia-open:coreos-stable-"${FEDORA_VERSION}"-x86_64 AS akmods-nvidia-open
   ```

3. Remove the NVIDIA mount lines from the first `RUN`:

   ```Dockerfile
   --mount=type=bind,from=akmods-nvidia-open,src=/rpms/kmods,dst=/tmp/rpms/nvidia-kmods \
   --mount=type=bind,from=akmods-nvidia-open,src=/rpms/nvidia,dst=/tmp/rpms/nvidia \
   --mount=type=bind,from=akmods-nvidia-open,src=/rpms/ublue-os,dst=/tmp/rpms/ublue-os \
   ```

4. In `build_files/zfs.sh`, remove `kmod-nvidia` from the package-removal loop
   and remove the NVIDIA Open install block.

After that, the only release-readiness inputs you need to check are:

```text
ghcr.io/ublue-os/aurora-dx:stable
ghcr.io/ublue-os/akmods:coreos-stable-N-x86_64
ghcr.io/ublue-os/akmods-zfs:coreos-stable-N-x86_64
```

## Repository Layout

```text
Containerfile                         image build definition
build_files/build.sh                  package and service customization inside the image
build_files/zfs.sh                    kernel, NVIDIA Open, and ZFS RPM installation logic
.github/workflows/build.yml           build and publish the container image
docs/manual-input-check.md            Fedora release input-check notes
```

## Build And Publish

This repo is built by GitHub Actions.

Manual workflow run:

```bash
gh workflow run build.yml
```

The workflow also runs on the default branch according to `.github/workflows/build.yml`.
It builds and publishes the container image, then signs it on default-branch
non-PR runs.

Scheduled builds run weekly on Sunday morning at 05:00 UTC, which is about
1:00 AM Eastern during daylight time. This keeps the image refreshed before a
typical early-morning systemd pull timer without staging a new deployment every
day.

If Aurora or the upstream Universal Blue akmods images publish an important
update during the week, deciding whether to run an out-of-schedule manual build
is up to you.

## Rebase An Existing Aurora Install

After your image is published to GHCR, rebase an existing Aurora install to the
custom image. Replace the owner and repository with your fork.

```bash
sudo bootc switch ghcr.io/<owner>/<repo>:latest
```

Reboot after the switch, then validate ZFS and NVIDIA as you normally would.

## Signature Verification

```bash
cosign verify --key cosign.pub ghcr.io/danathar/aurora-zfs-example:latest
```

## References

- Aurora discussion: https://github.com/ublue-os/aurora/issues/1765
- Universal Blue akmods repo: https://github.com/ublue-os/akmods
- Universal Blue akmods issues: https://github.com/ublue-os/akmods/issues
