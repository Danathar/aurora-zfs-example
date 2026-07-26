# Agent Notes

Orientation for LLM agents (Claude Code, Codex, etc.) asked to investigate a
failed build in this repo. Read this before digging through logs — almost every
build failure here has the same shape, and the diagnosis is mechanical.

Companion doc: [`docs/manual-input-check.md`](docs/manual-input-check.md) covers
*pre-flight* checks before a Fedora major-release bump. This file covers
*post-mortem* diagnosis of a build that already broke.

## What this image is

A thin derivative of Aurora DX that adds ZFS back. It does not compile ZFS. It
assembles three prebuilt Universal Blue artifacts, and its correctness depends
entirely on those three agreeing about one thing: **the kernel version**.

## The three upstream inputs

| Input | Referenced at | Provides |
|---|---|---|
| `ghcr.io/ublue-os/aurora-dx:stable` | [`Containerfile`](Containerfile) `AURORA_IMAGE`/`AURORA_TAG` | The base OS. Its own kernel is discarded. |
| `ghcr.io/ublue-os/akmods:coreos-stable-<N>-x86_64` | [`Containerfile`](Containerfile) `FROM ... AS akmods` | `/kernel-rpms` (**the kernel actually shipped**) plus common kmods (xone, v4l2loopback). |
| `ghcr.io/ublue-os/akmods-zfs:coreos-stable-<N>-x86_64` | [`Containerfile`](Containerfile) `FROM ... AS akmods-zfs` | `/rpms/kmods/zfs` — `kmod-zfs` plus ZFS userspace. |

All three are built by **`ublue-os/akmods`** (not ucore — ucore is a separate
consumer of the same `akmods-zfs` artifacts). Both akmods tags are *floating*:
they are rebuilt on upstream's schedule and silently move to new kernels.

## Build pipeline

1. [`build_files/kernel-akmods.sh`](build_files/kernel-akmods.sh) erases
   Aurora's kernel RPMs and deletes `/usr/lib/modules` entirely, then installs
   the kernel from the **akmods** image and `versionlock`s it.
2. [`build_files/zfs.sh`](build_files/zfs.sh) derives `KERNEL` by reading back
   the single remaining directory under `/usr/lib/modules`, then installs
   `kmod-zfs-${KERNEL}*.rpm` from the **akmods-zfs** image, runs `depmod`, and
   rebuilds the initramfs.
3. [`build_files/build.sh`](build_files/build.sh) and
   [`build_files/post-check.sh`](build_files/post-check.sh) finish and validate.

The load-bearing consequence: `KERNEL` comes from the **akmods** image, but
`kmod-zfs` must come from the **akmods-zfs** image. Nothing forces those two
floating tags to agree.

## Dominant failure mode: kernel / ZFS akmod skew

### Symptom

The `Build and push image` step fails in `zfs.sh` with a glob that matched
nothing:

```
+ KERNEL=<new-kernel>
+ dnf5 -y install /tmp/rpms/kmods/zfs/kmod-zfs-<new-kernel>*.rpm ...
Failed to access RPM "/tmp/rpms/kmods/zfs/kmod-zfs-<new-kernel>*.rpm": No such file or directory
Error: building at STEP "RUN --mount=type=bind,... /ctx/kernel-akmods.sh && /ctx/zfs.sh"
```

The ZFS **userspace** RPMs in the same command resolve fine (`libnvpair*`,
`libzfs*`, `zfs-*`) — they are not kernel-versioned. Only `kmod-zfs` is. Seeing
userspace resolve while `kmod-zfs` fails is the signature of skew, not of a
missing or corrupt artifact.

### Why it happens

`akmods` tracks whatever kernel Fedora ships. `akmods-zfs` can only advance
when OpenZFS supports that kernel. OpenZFS hard-gates this in `configure` using
`Linux-Maximum` from its `META` file. When Fedora's kernel minor version
overtakes `Linux-Maximum` for the current OpenZFS release, upstream's ZFS build
job starts failing, `akmods-zfs` freezes on the last good kernel, `akmods`
keeps moving, and this repo breaks the next time it builds.

This is expected, recurring, and anticipated in the `Containerfile` comments —
it is the same reason Aurora dropped ZFS. It is not a regression in this repo.

### 60-second diagnosis

Confirm the skew first. If the three lines below do not all show the same
kernel, you already have your answer and can skip the logs:

```bash
FEDORA_VERSION=44
for img in akmods akmods-zfs; do
  printf '%-12s %s\n' "$img" "$(skopeo inspect --format '{{ index .Labels "ostree.linux" }}' \
    "docker://ghcr.io/ublue-os/${img}:coreos-stable-${FEDORA_VERSION}-x86_64")"
done
printf '%-12s %s\n' "aurora-dx" \
  "$(skopeo inspect --format '{{ index .Labels "ostree.linux" }}' docker://ghcr.io/ublue-os/aurora-dx:stable)"
```

The `ostree.linux` label is the authoritative kernel version for these images.

Then confirm the failure matches:

```bash
gh run list --limit 10
gh run view <run-id> --log-failed | grep -E "KERNEL=|Failed to access RPM|Error: building"
```

Note `gh run view --log-failed` on this workflow reports the step as
`UNKNOWN STEP` and dumps a lot of image-pull noise; grep is required.

### Tracing to the upstream root cause

Work outward in this order. Do not stop at "the tag is stale" — find the reason
it is stale, because that determines which fix is appropriate.

1. **Is upstream's build failing?**

   ```bash
   gh run list --repo ublue-os/akmods --limit 20
   ```

   Look for `Build COREOS-STABLE akmods`. Then identify the failing job:

   ```bash
   gh run view <run-id> --repo ublue-os/akmods
   ```

   The `Build zfs coreos-stable (<N>)` jobs are the relevant ones.

2. **Why is the ZFS job failing?** The kernel gate appears in the `Test Image`
   step:

   ```bash
   gh run view --repo ublue-os/akmods --job <job-id> --log \
     | grep -E "Cannot build against kernel|maximum supported kernel"
   ```

   Expected output when this is a version gate:

   ```
   *** Cannot build against kernel version <kernel>.
   *** The maximum supported kernel version is <X.Y>.
   ```

3. **Has OpenZFS raised the ceiling yet?**

   ```bash
   gh api repos/openzfs/zfs/contents/META --jq '.content' | base64 -d | grep Linux-
   gh api repos/openzfs/zfs/releases --jq '.[] | "\(.tag_name)\t\(.published_at)"' | head
   ```

   `master` usually raises `Linux-Maximum` well before it appears in a tagged
   release. What matters is whether a **tagged** release has it, since that is
   what upstream akmods builds against.

4. **What tags are actually available to pin to?**

   ```bash
   skopeo list-tags docker://ghcr.io/ublue-os/akmods     | grep coreos-stable-44 | sort -V
   skopeo list-tags docker://ghcr.io/ublue-os/akmods-zfs | grep coreos-stable-44 | sort -V
   ```

   Kernel-pinned tags look like `coreos-stable-44-7.0.12-201.fc44.x86_64`. A
   pin is only viable if the **same** kernel-pinned tag exists in *both*
   repositories.

5. **Upstream policy**, if the streams behave inconsistently:

   ```bash
   gh api repos/ublue-os/akmods/contents/images.yaml --jq '.content' | base64 -d | head -20
   ```

   The `zfs:` block sets `minor_version` and `linux_experimental` per kernel
   flavor. `coreos-testing` typically sets `linux_experimental: true`, which
   passes OpenZFS's `--enable-linux-experimental` and bypasses the
   `Linux-Maximum` check. That is why a `coreos-testing` ZFS build for a new
   kernel can exist while `coreos-stable` has none.

## Fix options

Listed in ascending order of risk.

**Wait.** Legitimate and usually correct. Upstream's stable ZFS job goes green
on its own once OpenZFS tags a release whose `Linux-Maximum` covers Fedora's
kernel; the floating tags then re-converge and this repo builds again with no
change. The cost is that the scheduled build fails daily in the meantime and
**no new image is published**, so the deployed system stops receiving Aurora
and security updates until it clears. Acceptable for a short gap; check step 3
above to estimate how short.

**Pin both images to the last matching kernel.** In the `Containerfile`,
replace *both* floating tags with the same kernel-pinned tag, e.g.
`coreos-stable-44-7.0.12-201.fc44.x86_64`. This restores builds immediately and
keeps Aurora userspace updates flowing. They must be pinned **together** — the
`Containerfile` comments say so, and pinning only one recreates the skew. Both
must be unpinned again later, or the image is frozen on an unpatched kernel;
leave a tracking note when doing this.

**Move to the `coreos-testing` stream.** Gets a current kernel immediately, but
its ZFS is built with `--enable-linux-experimental`, i.e. against a kernel
OpenZFS has not declared support for. This is a root filesystem. Treat as a
last resort.

Do not "fix" this by loosening the glob in `zfs.sh` or making the kmod install
non-fatal. A `kmod-zfs` built for a different kernel will not load, and the
failure would move from the build to the boot.

## Incident log

Keep this appended to; the recurrence pattern is the useful part.

### 2026-07-22 → present: Fedora kernel 7.1 vs OpenZFS 2.4.3

- Last green scheduled build 2026-07-19. First failure 2026-07-22 (PR run),
  then every scheduled run.
- `akmods:coreos-stable-44-x86_64` moved to `7.1.3-200.fc44.x86_64`;
  `akmods-zfs:coreos-stable-44-x86_64` stayed at `7.0.12-201.fc44.x86_64`.
  `aurora-dx:stable` was also still on `7.0.12-201.fc44.x86_64`, so the akmods
  stable stream had run ahead of Aurora itself.
- Upstream `Build COREOS-STABLE akmods` failing daily; `Build zfs
  coreos-stable (44)` died in `Test Image` with
  `*** The maximum supported kernel version is 7.0.`
- Cause: newest tagged OpenZFS was `zfs-2.4.3` (2026-06-12) with
  `Linux-Maximum: 7.0`. OpenZFS `master` (2.4.99) already had
  `Linux-Maximum: 7.1`, but no tagged 2.4.x release carried it.
- `akmods-zfs:coreos-testing-44-7.1.3-200.fc44.x86_64` did exist, via
  `linux_experimental: true` for `coreos-testing` (ublue-os/akmods PR #554).
- Viable pin at the time: `coreos-stable-44-7.0.12-201.fc44.x86_64`, present in
  both `akmods` and `akmods-zfs`.
