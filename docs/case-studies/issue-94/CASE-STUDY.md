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

## 3. Solution — explicit preload plus default-on host passthrough

The entrypoint now seeds the nested daemon **after dockerd is ready** and before
it hands off to the normal box entrypoint. There are two complementary paths.

### 3.1 Explicit preload (issue option 1)

Driven by two environment variables for operators who want to name exactly what
to seed:

| Variable | Behavior |
| --- | --- |
| `DIND_PRELOAD_TARBALL` | Space-separated list of `docker save` tarball files and/or directories. Each file is `docker load`-ed; each directory loads every `*.tar` inside. This is the zero-network path for reusing host images. |
| `DIND_PRELOAD_IMAGES` | Space-separated image references. Each is `docker pull`-ed, but only when `docker image inspect` shows it is not already present — so it is idempotent and free when a volume or tarball already provided the image. |

### 3.2 Host-image passthrough (issue follow-up: on by default, opt-out-able)

The issue follow-up asked to **"by default add host-image passthrough"**, make
it **"possible to turn it off"**, default to passing only images that are
**"available in docker hub and so on, so these are safe from tokens and baked in
configuration"**, and **"also have an option to pass through them all"**. That
maps directly onto three environment variables:

| Variable | Default | Behavior |
| --- | --- | --- |
| `DIND_HOST_PASSTHROUGH` | `public` | `public`: copy only host images carrying a `RepoDigest` from an allowlisted public registry. `all`: copy every tagged host image. `off`/`0`/`false`/`no`: disable. |
| `DIND_HOST_DOCKER_SOCK` | `/var/run/host-docker.sock` | Path inside the container to the mounted *host* Docker socket used to read host images. |
| `DIND_HOST_PASSTHROUGH_REGISTRIES` | `docker.io ghcr.io quay.io gcr.io registry.k8s.io public.ecr.aws mcr.microsoft.com` | Registries treated as "public" in `public` mode. |

The key isolation-preserving decision: passthrough reads the host socket from a
**non-default path** (`/var/run/host-docker.sock`), mounted read-only, used only
to `docker save | docker load` images at startup. The inner daemon keeps its own
`/var/run/docker.sock` and stays the container's isolated runtime — so the
per-container `docker ps` property from issue #80 is preserved and the host
socket is never mounted at the default path (which would be Docker-outside-of-
Docker; see §1 and `docs/dind/USAGE.md` "Host Prerequisites").

Why `public` is the safe default: a `RepoDigest` only exists once an image has
been pulled from (or pushed to) a registry, and we additionally require that
registry to be on the public allowlist. Such an image is freely re-pullable by
anyone, so copying it into the inner daemon leaks **no** local build secrets and
needs **no** registry credential. Locally-built images (which have no
`RepoDigest`) and private-registry images are excluded unless the operator
explicitly opts into `all`. This is exactly the "safe from tokens and baked in
configuration" property the issue asked for.

Because the default is on but a no-op without a mounted host socket, the normal
`docker run --privileged konard/box-dind` is unchanged: passthrough activates
only when the operator opts in by mounting the host socket.

### 3.3 Shared design choices

All consistent with the existing entrypoint:

- **Non-fatal.** A bad path, an unreadable tarball, a failed pull, or a single
  un-copyable host image logs a `WARN` and continues; the user shell still
  starts. The entrypoint already treats dockerd startup failures the same way.
- **Daemon-gated.** Seeding is attempted only when `docker info` succeeds, and is
  skipped entirely (with a warning) when `DIND_SKIP_DAEMON=1`, since there is no
  inner daemon to load into.
- **Idempotent.** Every path skips an image that is already present in the inner
  daemon, so volumes, tarballs, pulls, and passthrough compose without
  duplicating work.
- **Order.** Tarballs load first, then host passthrough, then registry pulls, so
  an already-seeded image short-circuits the later, more expensive steps.
- **Bake or mount.** Operators can mount tarballs/sockets at runtime, or `COPY` a
  tarball into a derived image and set `ENV DIND_PRELOAD_TARBALL=…` so every
  container starts warm.

## 4. Verification

- **Integration example:** [`tests/dind/example-preload-images.sh`](../../../tests/dind/example-preload-images.sh)
  builds an offline fixture image with `docker import` (no registry pull), saves
  it to a tarball, and asserts it is present in the **inner** daemon as soon as
  the container is ready — for both the single-file and directory forms — and
  that `DIND_PRELOAD_IMAGES` skips the redundant pull. Wired into the
  `pr-test-dind` CI job alongside the other documented dind examples.
- **Isolated unit test:** [`experiments/preload-unit-test.sh`](../../../experiments/preload-unit-test.sh)
  sources the real entrypoint (via `DIND_ENTRYPOINT_SOURCE_ONLY=1`) and drives
  its functions with a mock `docker` and a real AF_UNIX socket, covering
  load/pull/skip/daemon-down/no-op/missing-path **and** the passthrough branches:
  no-socket no-op, `public` mode passing a Docker Hub image while skipping a
  local one, `all` mode, already-present skip, `off`, and the registry-detection
  helpers. This runs anywhere (the CI sandbox only has the `vfs` storage driver,
  which cannot build the full overlay-backed dind image).

## 5. Files changed

- `ubuntu/24.04/dind/dind-entrypoint.sh` — preload hook, host passthrough, env documentation.
- `docs/dind/USAGE.md` — "Reusing Host Images (Preload)" and "Host-Image Passthrough" sections + env table rows.
- `README.md` — security-model note pointing at the preload and passthrough sections.
- `tests/dind/example-preload-images.sh` — executable example, run in CI.
- `experiments/preload-unit-test.sh` — isolated branch coverage (preload + passthrough).
