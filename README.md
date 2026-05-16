# aurora-zfs-example

GitHub Actions workflow: `build.yml`

This is a small, GitHub-built Aurora NVIDIA Open image that adds ZFS back using
upstream Universal Blue akmods artifacts.

It is intended for users who already understand ZFS and kernel-module matching.
It does not include local build helpers, input-check scripts, ISOs, qcow2 files,
or raw disk images. The expected install path is to rebase an existing Aurora
install to the published container image.

[Discussion](https://github.com/ublue-os/aurora/issues/1765)

## What It Uses

- base image: `ghcr.io/ublue-os/aurora-nvidia-open:stable`
- kernel RPMs: `ghcr.io/ublue-os/akmods`
- ZFS RPMs: `ghcr.io/ublue-os/akmods-zfs`
- NVIDIA Open RPMs: `ghcr.io/ublue-os/akmods-nvidia-open`

## Important Design Detail

This image does not keep Aurora's original kernel packages.

`build_files/zfs.sh` removes the base kernel and installs the kernel from the
selected Universal Blue `akmods` stream. It then installs matching ZFS and
NVIDIA Open kmods from the corresponding upstream akmods images.

The Fedora release is controlled here:

```Dockerfile
ARG FEDORA_VERSION=44
```

The base image intentionally tracks Aurora stable:

```Dockerfile
ARG AURORA_IMAGE=ghcr.io/ublue-os/aurora-nvidia-open
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

If you do not need NVIDIA, make this a plain Aurora + ZFS image:

1. In `Containerfile`, change the base image:

   ```Dockerfile
   ARG AURORA_IMAGE=ghcr.io/ublue-os/aurora
   ```

2. Remove the NVIDIA Open akmods stage:

   ```Dockerfile
   FROM ghcr.io/ublue-os/akmods-nvidia-open:coreos-stable-"${FEDORA_VERSION}"-x86_64 AS akmods-nvidia-open
   ```

3. Remove the two NVIDIA mount lines from the first `RUN`:

   ```Dockerfile
   --mount=type=bind,from=akmods-nvidia-open,src=/rpms/kmods,dst=/tmp/rpms/nvidia-kmods \
   --mount=type=bind,from=akmods-nvidia-open,src=/rpms/nvidia,dst=/tmp/rpms/nvidia \
   ```

4. In `build_files/zfs.sh`, remove `kmod-nvidia` from the package-removal loop
   and remove the NVIDIA Open install block.

After that, the only release-readiness inputs you need to check are:

```text
ghcr.io/ublue-os/aurora:stable
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
