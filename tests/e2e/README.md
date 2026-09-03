# End-to-end tests

One script, `run-e2e.sh`. It builds the actual image with podman and checks the
actual artifact. Everything in `tests/` above this directory runs against stubs
in seconds; this takes tens of minutes and about 40G.

It is not wired into `./tests/run-tests.sh`. That runner globs `test-*.sh` at
`maxdepth 1`, so nothing here can be picked up by accident.

```bash
./tests/e2e/run-e2e.sh              # build, then verify
./tests/e2e/run-e2e.sh --rechunk    # build, rechunk, verify the rechunked image
./tests/e2e/run-e2e.sh --clean      # also remove the images it created
./tests/e2e/run-e2e.sh --keep-going # report every failed check, not just the first
```

## What it is actually for

The plain run is a local rehearsal. CI already builds this image on every pull
request, and `build_files/post-check.sh` runs inside that build, so a green
`Build container image` tells you the same thing without occupying your machine.
Useful when you are iterating on the `Containerfile` and do not want to push to
find out.

`--rechunk` is the mode that tests something nothing else does.

`post-check.sh` and `bootc container lint` are `RUN` steps in the
`Containerfile`. They validate the image **before** the workflow hands it to
Chunkah. Chunkah then re-layers it, and the archive that comes back out is
loaded, tagged, pushed and signed without either check running again. The
`Verify pushed tags share one digest` step proves every published tag resolves
to one manifest — it says nothing about what is *in* that manifest.

So there is no validation on the far side of the rechunk. `--rechunk` closes
that loop locally: it rechunks with the same pinned Chunkah image and the same
`--config-str` workaround the workflow uses, then runs `post-check.sh` again
inside the result. `post-check.sh` is not copied into the image, so it is
mounted in read-only. Both `Containerfile` checks are re-run, not just one:
`post-check.sh` covers kernel and ZFS content, and `bootc container lint`
covers the filesystem invariants a re-layering could plausibly disturb while
leaving every module in place.

If Chunkah ever drops, reorders or mangles something — a module, a udev rule, a
systemd unit — this is what notices. Worth running after a Chunkah version bump,
which is the moment that risk is real.

## What it checks

| Check                                          | Notes                                                                                                                  |
| ---------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| The build completes                            | Implies the in-build `post-check.sh` and `bootc container lint` passed                                                 |
| `post-check.sh` against the final image        | The whole point under `--rechunk`                                                                                      |
| `bootc container lint` against the final image | The other half — a re-layering can disturb a bootc filesystem invariant while leaving every kernel and ZFS file intact |
| Exactly one kernel module tree                 |                                                                                                                        |
| `zpool` and `zfs` on `PATH`                    | ZFS userspace survived                                                                                                 |
| `containers.bootc=1` label                     | Informational — the workflow sets this, a local build does not                                                         |

## Storage

Every image is tagged under one timestamped name
(`localhost/aurora-zfs-simple-e2e:<stamp>`), and `--clean` removes exactly those
tags and nothing else. The script never prunes and never touches an image it did
not create. Without `--clean` it prints the `podman rmi` line for you to run
yourself.

The `--rechunk` archive is different: it is this script's own temporary file, so
it is removed unconditionally on exit, `--clean` or not. Otherwise a rechunk
that died on a full disk would leave several more gigabytes behind on the disk
that was already full.

It is written beside podman's storage rather than to `TMPDIR`, and `podman load`
is pointed at the same place. This matters more here than it would elsewhere:
Aurora **is** a Fedora Atomic desktop, so anyone running this has a tmpfs
`/tmp`. On the machine this was written on that is 31G of RAM, against 532G of
disk shared by `/var/tmp` and podman's storage. Both the archive and the load's
unpack are measured in gigabytes, so the default would have failed on a host
with hundreds of free gigabytes.

`podman load` needs this separately from the archive, because it expands the
archive into `TMPDIR` before applying it — the same reason `build.yml` runs it
as `TMPDIR=/mnt/tmp podman load`.

Set `E2E_ARCHIVE_DIR` to move both; `/var/tmp` is the other sensible choice on
an Atomic host.

The free-space check follows the same reasoning: it probes the filesystems that
actually receive data (podman's graph root, and the archive directory under
`--rechunk`), deduplicated by device, rather than the checkout. Checking the
checkout would let a run pass its own up-front check on a host with hundreds of
free gigabytes and then die tens of minutes later.

## Requirements

`podman`, about 40G free on each filesystem that receives data (checked up
front, before the long part), and network access for the base and akmods images. `--rechunk` additionally
pulls the Chunkah image pinned in `run-e2e.sh`, which tracks the one in
`.github/workflows/build.yml` by hand.
