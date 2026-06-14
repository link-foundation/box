---
bump: patch
---

dind-box: warn when the nested daemon runs on the `vfs` storage driver (issue
#104).

When the inner dockerd ends up on `vfs` — either pinned explicitly via
`DIND_STORAGE_DRIVER=vfs` (e.g. for overlay-on-overlay compatibility) or reached
as the last-resort auto-detect fallback — large images could fail to pull/run
with a cryptic `failed to register layer: no space left on device` and **no
hint** that the storage driver was the cause. `vfs` performs no copy-on-write: it
stores every image layer as a full, independent copy, so a multi-GB image's
on-disk footprint becomes the *sum* of all cumulative layer sizes (many times the
image size), and a >30 GB image can overflow a disk with far more than 30 GB free
(`link-assistant/hive-mind#1914`).

This is observability, not a default change — `vfs` stays the safe fallback. The
entrypoint now emits a single, actionable warning right after the daemon becomes
ready whenever the active driver is `vfs`, explaining the copy-on-write/disk
implication and naming the `DIND_STORAGE_DRIVER=fuse-overlayfs` remediation
(copy-on-write, works overlay-on-overlay, already shipped in the image). The
remediation line adapts to whether `/dev/fuse` is present, so when it is missing
it points at `--privileged` / `--device /dev/fuse` first. The
`DIND_STORAGE_DRIVER` doc comment now spells out the `vfs` disk amplification too.

Covered by a new unit test (`experiments/test-issue104-vfs-warning.sh`) and a new
assertion in the CI-run `tests/dind/example-storage-driver-vfs.sh`; documented in
`docs/dind/USAGE.md`.
