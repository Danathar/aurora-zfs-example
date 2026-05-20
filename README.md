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

The NVIDIA RPM reinstall can restore NVIDIA's RPM-owned dracut config to its
package default. Before generating the final initramfs, `build_files/zfs.sh`
reapplies Aurora/Universal Blue's NVIDIA dracut behavior so the NVIDIA driver is
force-loaded and the integrated GPU drivers are preloaded first. The build fails
if that dracut config is missing or does not contain the expected settings.

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

5. In `build_files/post-check.sh`, remove the NVIDIA validation block.

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
build_files/post-check.sh             final image validation for kernel, ZFS, and NVIDIA
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
- `spl.ko` and `zfs.ko` exist for the selected kernel
- `modinfo -k <kernel> spl` and `modinfo -k <kernel> zfs` work after `depmod`
- NVIDIA kernel modules, userspace packages, commands, and shared libraries are
  present
- `modinfo -k <kernel>` works for the NVIDIA modules
- the NVIDIA dracut config force-loads NVIDIA and preloads `i915 amdgpu nvidia`
- the generated initramfs contains ZFS and NVIDIA modules
- critical kmod RPM payload files are not missing or content-modified, while
  harmless rpm-ostree/bootc ownership/group/timestamp normalization is ignored

These checks do not prove that a real pool imports or a real GPU works because
the GitHub runner does not provide those host devices to the image build. They
do verify that the image contains the expected kernel modules, userspace tools,
libraries, and boot integration before it is published.

## Rebase An Existing Aurora Install

After your image is published to GHCR, rebase an existing Aurora install to the
custom image. Replace the owner and repository with your fork.

```bash
sudo bootc switch ghcr.io/<owner>/<repo>:latest
```

Reboot after the switch, then validate ZFS and NVIDIA as you normally would.

Useful post-rebase checks:

```bash
grep -E 'force_drivers|omit_drivers|i915|amdgpu|nvidia' /usr/lib/dracut/dracut.conf.d/99-nvidia.conf
cat /proc/cmdline
lsmod | grep -E 'nvidia|zfs'
nvidia-smi
zpool status
```

The dracut config should use `force_drivers` for NVIDIA and include
`i915 amdgpu nvidia`. NVIDIA modules should load, `nvidia-smi` should work, and
your ZFS pools should import normally.

If you rely on GPU containers or Flatpak NVIDIA apps, also check those workflows
after rebasing. This repo inherits Aurora's container and Flatpak NVIDIA
integration from the base image; it does not recreate those pieces during the
build.

### If GPU Containers Fail

First confirm the host NVIDIA driver works:

```bash
nvidia-smi
```

Then check the Universal Blue NVIDIA container CDI generation service:

```bash
systemctl status ublue-nvctk-cdi.service
journalctl -u ublue-nvctk-cdi.service -b --no-pager
test -s /etc/cdi/nvidia.yaml
grep -E 'nvidia.com/gpu|name:' /etc/cdi/nvidia.yaml
```

If `/etc/cdi/nvidia.yaml` is missing or stale, try regenerating it:

```bash
sudo systemctl restart ublue-nvctk-cdi.service
```

Then test a container directly. This may need to pull the CUDA test image; use a
newer known-good `nvidia/cuda` base image tag if this example tag is no longer
available:

```bash
podman run --rm --device nvidia.com/gpu=all docker.io/nvidia/cuda:12.6.0-base-ubuntu24.04 nvidia-smi
```

If host `nvidia-smi` works but the container test fails, the problem is likely
in the inherited NVIDIA container-toolkit/CDI integration rather than in ZFS or
the kernel module install. Check the service logs above first.

As a diagnostic only, if the failure looks like an SELinux device-access denial,
retry the same container command with `--security-opt=label=disable`. If that
works, check whether the inherited NVIDIA container SELinux policy is present
and loaded before using that flag as a long-term workaround:

```bash
semodule -l | grep -i nvidia
```

### If Flatpak NVIDIA Apps Fail

First confirm the host driver works:

```bash
nvidia-smi
```

Then check Aurora's inherited Flatpak NVIDIA runtime sync service and installed
Flatpak NVIDIA runtimes:

```bash
systemctl status ublue-nvidia-flatpak-runtime-sync.service
journalctl -u ublue-nvidia-flatpak-runtime-sync.service -b --no-pager
flatpak list --runtime | grep -i nvidia
```

The installed Flatpak NVIDIA runtime should correspond to the host NVIDIA driver
version. If it is missing or out of date, try:

```bash
sudo systemctl restart ublue-nvidia-flatpak-runtime-sync.service
flatpak update
```

If the service is missing or repeatedly fails, that points to Aurora's inherited
Flatpak NVIDIA integration rather than this repo's ZFS/kernel-module logic.
Check upstream Aurora or Universal Blue NVIDIA notes before adding more custom
logic here.

## NVIDIA Rant

I hate that all of this is necessary just to keep NVIDIA, the kernel, and ZFS in
sync. The whole point of this repo is to make sure the kernel module stack lines
up cleanly, and NVIDIA turns that into a delicate little dance between the base
image, the akmods images, the driver userspace packages, dracut, Secure Boot,
containers, Flatpak runtimes, and whatever else decides to care about the exact
driver version today.

I really appreciate how much the Universal Blue team does to orchestrate all of
this upstream. The fact that there are prebuilt akmods images, matching kernel
artifacts, NVIDIA Open variants, ZFS artifacts, signing, and all the surrounding
glue is doing a lot of heavy lifting here.

But still: I should have bought an AMD card.

## Signature Verification

```bash
cosign verify --key cosign.pub ghcr.io/danathar/aurora-zfs-example:latest
```

## References

- Aurora repo: https://github.com/ublue-os/aurora
- Aurora discussion: https://github.com/ublue-os/aurora/issues/1765
- Universal Blue akmods repo: https://github.com/ublue-os/akmods
- Universal Blue akmods issues: https://github.com/ublue-os/akmods/issues
- NVIDIA open GPU kernel modules repo: https://github.com/NVIDIA/open-gpu-kernel-modules
