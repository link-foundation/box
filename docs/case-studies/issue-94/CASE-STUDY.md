# Case Study: Issue #94 — dind-box nested daemon starts with an empty image store

## Executive Summary

Issue [#94](https://github.com/link-foundation/box/issues/94) reports the classic
Docker-in-Docker image-cache pitfall in the `konard/box-dind` family: the nested
`dockerd` started by [`dind-entrypoint.sh`](../../../ubuntu/24.04/dind/dind-entrypoint.sh)
boots with an **empty image store**. The first `docker run <image>` *inside* a
fresh container therefore reports `Unable to find image '<image>' locally` and
pulls a full copy from the registry — even when the **host** daemon already has
that exact image. For multi-GB images this re-download happens on every fresh
container and is pure waste.

The original `issue.md` is preserved [here](./issue.md). Downstream report:
[link-assistant/hive-mind#1879](https://github.com/link-assistant/hive-mind/issues/1879).

## 1. Why the inner store is empty (and why that is correct)

Each dind-box owns its **own** `dockerd` with its own `--data-root`
(`/var/lib/docker` inside the container). This is the deliberate isolation
property from issue #80: `docker ps -a` inside a box lists only that box's
children, and the inner daemon never touches the host image store or socket.

Isolation and cache-sharing are in tension. The inner daemon cannot see the host
images precisely because it is isolated. So the fix must be **opt-in seeding**,
not automatic socket/store sharing (which would re-introduce the
Docker-outside-of-Docker security problems the project already rejects — see the
issue #80 case study and the "Host Prerequisites" notes in `docs/dind/USAGE.md`).

This matches jpetazzo's well-known
[*"Using Docker-in-Docker for your CI… is it a good idea?"*](https://jpetazzo.github.io/2015/09/03/do-not-use-docker-in-docker-for-ci/),
which calls out the duplicated image cache as the canonical DinD gotcha.

## 2. Prior workaround (what downstream did)

Downstream seeded the nested daemon by streaming a host `docker save` into the
container's `docker load`, via a bespoke helper
([`preload-dind-isolation-image.mjs`](https://github.com/link-assistant/hive-mind/blob/main/scripts/preload-dind-isolation-image.mjs)).
That works but every consumer has to reinvent it; the issue asks to make image
reuse a first-class, documented capability of `box-dind`.

## 3. Solution — a documented startup preload hook (issue option 1)

The entrypoint now seeds the nested daemon **after dockerd is ready** and before
it hands off to the normal box entrypoint, driven by two environment variables:

| Variable | Behavior |
| --- | --- |
| `DIND_PRELOAD_TARBALL` | Space-separated list of `docker save` tarball files and/or directories. Each file is `docker load`-ed; each directory loads every `*.tar` inside. This is the zero-network path for reusing host images. |
| `DIND_PRELOAD_IMAGES` | Space-separated image references. Each is `docker pull`-ed, but only when `docker image inspect` shows it is not already present — so it is idempotent and free when a volume or tarball already provided the image. |

Design choices, all consistent with the existing entrypoint:

- **Non-fatal.** A bad path, an unreadable tarball, or a failed pull logs a
  `WARN` and continues; the user shell still starts. The entrypoint already
  treats dockerd startup failures the same way.
- **Daemon-gated.** Preload is attempted only when `docker info` succeeds, and is
  skipped entirely (with a warning) when `DIND_SKIP_DAEMON=1`, since there is no
  inner daemon to load into.
- **Order.** Tarballs load before registry pulls, so a tarball-provided image
  short-circuits the matching `DIND_PRELOAD_IMAGES` pull.
- **Bake or mount.** Operators can mount a tarball/directory at runtime, or
  `COPY` a tarball into a derived image and set `ENV DIND_PRELOAD_TARBALL=…` so
  every container starts warm.

## 4. Verification

- **Integration example:** [`tests/dind/example-preload-images.sh`](../../../tests/dind/example-preload-images.sh)
  builds an offline fixture image with `docker import` (no registry pull), saves
  it to a tarball, and asserts it is present in the **inner** daemon as soon as
  the container is ready — for both the single-file and directory forms — and
  that `DIND_PRELOAD_IMAGES` skips the redundant pull. Wired into the
  `pr-test-dind` CI job alongside the other documented dind examples.
- **Isolated unit test:** [`experiments/preload-unit-test.sh`](../../../experiments/preload-unit-test.sh)
  extracts the preload functions from the real entrypoint and drives them with a
  mock `docker`, covering load/pull/skip/daemon-down/no-op/missing-path branches.
  This runs anywhere (the CI sandbox only has the `vfs` storage driver, which
  cannot build the full overlay-backed dind image).

## 5. Files changed

- `ubuntu/24.04/dind/dind-entrypoint.sh` — preload hook + env documentation.
- `docs/dind/USAGE.md` — "Reusing Host Images (Preload)" section + env table rows.
- `README.md` — security-model note pointing at the preload section.
- `tests/dind/example-preload-images.sh` — executable example, run in CI.
- `experiments/preload-unit-test.sh` — isolated branch coverage.
