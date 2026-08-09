# Aurora developer image with ZFS

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/Danathar/aurora-zfs-simple)

[![build](https://github.com/danathar/aurora-zfs-simple/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/danathar/aurora-zfs-simple/actions/workflows/build.yml)

> [!NOTE]
> `main` is now the maintained AMD/non-NVIDIA branch. The previous NVIDIA Open
> version was moved to the
> [`nvidia-legacy`](https://github.com/Danathar/aurora-zfs-simple/tree/nvidia-legacy)
> branch and tagged
> `nvidia-last-known-good-2026-05-31`. That NVIDIA branch is unmaintained; it
> worked the last time it was used, but it may stop building or working as
> upstream Aurora, kernel, ZFS, or NVIDIA inputs change.

This is a small, GitHub-built Aurora DX developer image that adds ZFS back using
upstream Universal Blue akmods artifacts.

It is intended for users who already understand ZFS and kernel-module matching.
The expected install path is to rebase an existing Aurora install to the
published container image.

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

If your host's container signature policy is configured to trust your fork's
signing key, prefer enforcing it during the switch:

```bash
sudo bootc switch --enforce-container-sigpolicy ghcr.io/<owner>/<repo>:latest
```

Reboot after switching.

## Switching Back To Upstream

To go back to upstream Aurora DX stable:

```bash
sudo bootc switch --enforce-container-sigpolicy ghcr.io/ublue-os/aurora-dx:stable
```

Reboot after switching back.

## What It Uses

- base image: `ghcr.io/ublue-os/aurora-dx:stable`
- kernel RPMs: `ghcr.io/ublue-os/akmods`
- ZFS RPMs: `ghcr.io/ublue-os/akmods-zfs`
- content-based image layering: [`coreos/chunkah`](https://github.com/coreos/chunkah)

This branch intentionally does not include the NVIDIA Open Aurora base image or
NVIDIA akmods.

## Important Design Detail

This image does not keep Aurora's original kernel packages.

`build_files/kernel-akmods.sh` removes the base kernel and installs the kernel
from the selected Universal Blue `akmods` stream. `build_files/zfs.sh` then
installs matching ZFS kmods and userspace packages from the corresponding
upstream akmods image. This ensures the kernel and ZFS module RPMs come from
matching Universal Blue akmods inputs.

The Fedora release is controlled here:

```Dockerfile
ARG FEDORA_VERSION=44
```

The base image intentionally tracks Aurora DX stable:

```Dockerfile
ARG AURORA_IMAGE=ghcr.io/ublue-os/aurora-dx
ARG AURORA_TAG=stable
```

The `Containerfile` has a guard that fails the build if the stable base image's
Fedora version does not match `FEDORA_VERSION`.

For the manual release-readiness checklist, see
[`docs/manual-input-check.md`](docs/manual-input-check.md).

## If The Kernel Moves Ahead Of Aurora

The kernel comes from the selected Universal Blue `akmods` stream, not directly
from the Aurora base image. That means this image can temporarily carry a newer
kernel than upstream Aurora stable when the akmods stream has moved ahead.

That is expected for this design, but ZFS must have a matching prebuilt kmod for
the same kernel. The build fails if the kernel and ZFS module stack do not line
up.

## Pinning The Kernel If Needed

If a new kernel lands before ZFS is ready or before you want to move, pin all
akmods inputs to the same full kernel tag. For example:

```Dockerfile
FROM ghcr.io/ublue-os/akmods:coreos-stable-44-6.19.14-101.fc44.x86_64 AS akmods
FROM ghcr.io/ublue-os/akmods-zfs:coreos-stable-44-6.19.14-101.fc44.x86_64 AS akmods-zfs
```

Pin both inputs together. Do not pin only one of them.

When a build has already failed this way, [`AGENTS.md`](AGENTS.md) has the
step-by-step diagnosis: how to confirm the skew, how to trace it back to the
upstream `ublue-os/akmods` job and the OpenZFS kernel-version gate, and how to
pick between waiting, pinning, and switching streams.

## Repository Layout

```text
AGENTS.md                             agent notes: build-failure diagnosis and upstream tracing
CLAUDE.md                             pointer to AGENTS.md
Containerfile                         image build definition
build_files/build.sh                  package and service customization inside the image
build_files/kernel-akmods.sh          kernel replacement and common akmods installation
build_files/post-check.sh             final image validation for kernel and ZFS
build_files/zfs.sh                    ZFS RPM installation and final initramfs generation
.github/workflows/build.yml           build and publish the container image
.github/renovate.json5                dependency and pinned Chunkah release updates
docs/manual-input-check.md            Fedora release input-check notes
```

## Build And Publish

This repo is built by GitHub Actions.

Manual workflow run:

```bash
gh workflow run build.yml
```

The workflow also runs on the default branch according to `.github/workflows/build.yml`.
It builds the complete image, post-processes it with Chunkah, publishes a
single tag, copies that exact manifest to the remaining tags, verifies every
published tag resolves to one manifest digest, and then signs that digest on
default-branch non-PR runs.

Chunkah runs after the kernel and ZFS changes have been applied. It rebuilds the
final root filesystem into content-based layers, including both the inherited
Aurora content and this image's replacement kernel and ZFS files. This improves
layer reuse and update resumability; it does not change the files installed in
the image.

The workflow uses an explicit stable Chunkah version and immutable image digest,
for example `v0.6.0@sha256:...`, instead of the floating `latest` tag. Renovate's
custom manager in `.github/renovate.json5` tracks newer stable `vX.Y.Z` releases
and updates the version and digest together.

Scheduled builds run weekly on Sunday morning at 05:00 UTC, which is about
1:00 AM Eastern during daylight time. This keeps the image refreshed before a
typical early-morning systemd pull timer without staging a new deployment every
day.

If Aurora or the upstream Universal Blue akmods images publish an important
update during the week, deciding whether to run an out-of-schedule manual build
is up to you.

## Build-Time Validation

Before `bootc container lint`, the `Containerfile` runs
`build_files/post-check.sh`. This is a fail-fast consistency check for the final
image. It is intended to catch cases where RPM metadata says something is
installed but the files needed at boot are missing.

The post-check verifies:

- exactly one kernel module tree exists under `/usr/lib/modules`
- the kernel RPM and module tree agree on the selected kernel version
- ZFS RPMs, userspace commands, shared libraries, systemd units, udev rules, and
  module-load config are present
- ZFS kmod, userspace, and libraries report one OpenZFS version/release
- `spl.ko` and `zfs.ko` exist for the selected kernel
- `modinfo -k <kernel> spl` and `modinfo -k <kernel> zfs` work after `depmod`
- `spl` and `zfs` module vermagic matches the selected kernel
- the generated initramfs contains `zfs.ko` and `spl.ko`
- critical ZFS kmod RPM payload files are not missing or content-modified, while
  harmless rpm-ostree/bootc ownership/group/timestamp normalization is ignored

These checks do not prove that a real pool imports because the GitHub runner
does not provide those host devices to the image build. They do verify that the
image contains the expected kernel modules, userspace tools, libraries, and boot
integration before it is published.

## Rebase An Existing Aurora Install

After your image is published to GHCR, rebase an existing Aurora install to the
custom image. Replace the owner and repository with your fork.

```bash
sudo bootc switch ghcr.io/<owner>/<repo>:latest
```

If the target host has a container signature policy configured for your fork's
signing key, prefer:

```bash
sudo bootc switch --enforce-container-sigpolicy ghcr.io/<owner>/<repo>:latest
```

Reboot after the switch, then validate ZFS as you normally would.

Useful post-rebase checks:

```bash
cat /proc/cmdline
lsmod | grep -E 'zfs|spl'
zpool status
```

Your ZFS pools should import normally.

## Signature Verification

```bash
cosign verify --key cosign.pub ghcr.io/danathar/aurora-zfs-simple:latest
```

## References

- Aurora repo: https://github.com/ublue-os/aurora
- Aurora discussion: https://github.com/ublue-os/aurora/issues/1765
- Universal Blue akmods repo: https://github.com/ublue-os/akmods
- Universal Blue akmods issues: https://github.com/ublue-os/akmods/issues
- Chunkah repo: https://github.com/coreos/chunkah
