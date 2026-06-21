# dind-box Usage

The `-dind` images are regular box images with Docker Engine added. They keep the
same user-facing default as the non-dind images: `docker exec` opens as `box`
with `HOME=/home/box`. The entrypoint starts the inner `dockerd` with a scoped
passwordless sudo rule, then hands off to the normal box entrypoint.

The runnable examples in this document live under `tests/dind/` and are executed
by pull request CI against the locally built `box-dind-js` image.

## Two Modes: DinD and DooD

One image, two runtimes — the mode is chosen entirely by the **run flags**, not
by a different build:

| | **Docker-in-Docker (DinD)** _(default)_ | **Docker-outside-of-Docker (DooD)** |
| --- | --- | --- |
| How to select | `--privileged` (or `--runtime=sysbox-runc`) | `-e DIND_SKIP_DAEMON=1` + `-v /var/run/docker.sock:/var/run/docker.sock` |
| Docker daemon | A **nested** `dockerd` started inside the container | The **host** daemon, reached through the mounted socket |
| Container view (`docker ps`) | Only containers this box created — isolated (issue #80) | The host's full container/image list — shared |
| Image cache | Empty at start; seed it with preload / passthrough (a **copy**) | The host's images are already there — **zero copy, zero extra disk** |
| Isolation | Strong: inner daemon can't see or touch host containers | Weak: in-container Docker can control the host daemon |
| Disk cost of reusing a host image | A full `docker save \| docker load` (doubles that image on disk) | None — same image store |
| Best for | Untrusted workloads, true nesting, per-box isolation | Trusted workloads that need the host's images/build cache with no duplication |

Rule of thumb: **DinD when you need isolation, DooD when you need the host's
images without copying them.** DooD is the only mode that adds **zero** disk for
image reuse — host-image passthrough in DinD is a deliberate copy (see
[Host-Image Passthrough](#host-image-passthrough-dind_host_passthrough) and
[Docker-outside-of-Docker (DooD)](#docker-outside-of-docker-dood) below).

## Runtime Flags

Use one of these host-side runtime modes when you need the inner Docker daemon:

```bash
docker run -d --privileged --name box-dind konard/box-dind sleep infinity
```

```bash
docker run -d --runtime=sysbox-runc --name box-dind konard/box-dind sleep infinity
```

`--privileged` is the default Docker-in-Docker mode. Sysbox is the preferred
mode for shared hosts when the `sysbox-runc` runtime is installed, because it is
designed for system containers without exposing the host Docker socket.

Without a runtime that lets the inner daemon create namespaces, mounts, and
cgroups, the container shell can still start but Docker commands normally fail:

```text
[dind-entrypoint] WARN: dockerd did not become ready within 30s
Cannot connect to the Docker daemon at unix:///var/run/docker.sock
```

The dockerd log path is controlled by `DIND_LOG_FILE` and defaults to
`/var/log/dockerd.log`.

## Basic Docker Use

This example starts the image, waits for the entrypoint to bring up the inner
daemon, and checks that `docker exec` still lands as `box`:

```bash
docker run -d --privileged --name box-dind konard/box-dind sleep infinity

until docker exec box-dind docker info >/dev/null 2>&1; do
  sleep 1
done

docker exec box-dind whoami
docker exec box-dind docker ps
docker exec box-dind pgrep -x dockerd
```

CI runs the same flow as an executable example:

```bash
DIND_IMAGE=box-dind-js tests/dind/example-basic-docker-ps.sh
```

## Runtime Environment

The entrypoint supports these environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `DIND_STORAGE_DRIVER` | auto | Override the inner dockerd storage driver. |
| `DIND_DATA_ROOT` | `/var/lib/docker` | Override the inner dockerd data root. |
| `DIND_LOG_FILE` | `/var/log/dockerd.log` | Write dockerd logs to this path. |
| `DIND_WAIT_SECONDS` | `30` | Wait this many seconds for dockerd readiness. |
| `DIND_SKIP_DAEMON` | `0` | Set to `1` to skip starting the nested dockerd. This is the supported Docker-outside-of-Docker (DooD) switch: mount the host socket at `/var/run/docker.sock` and the in-container CLI talks to the host daemon directly (see [Docker-outside-of-Docker (DooD)](#docker-outside-of-docker-dood)). Also used for setup/commit containers and Sysbox. |
| `DIND_READY_FILE` | `/tmp/box-dind-ready` | Path the entrypoint writes once the inner-daemon image preload/passthrough phase finishes (DinD only). Contains `complete` when every requested image seeded, or `warnings` when some did not. Lets a host poll readiness deterministically instead of racing `docker info` (see [Knowing When the Image Cache Is Ready](#knowing-when-the-image-cache-is-ready)). |
| `DIND_PRELOAD_TARBALL` | _(empty)_ | Space-separated `docker save` tarballs and/or directories of `*.tar` to `docker load` into the nested daemon once it is ready. |
| `DIND_PRELOAD_IMAGES` | _(empty)_ | Space-separated image references to `docker pull` into the nested daemon once it is ready, skipping any that are already present. |
| `DIND_HOST_PASSTHROUGH` | `public` | Copy images already present on the host into the nested daemon at startup when a host socket is mounted (see below). `public` only passes images with a RepoDigest from an allowlisted public registry; `all` passes every tagged image; `off` disables it. A quiet no-op when no host socket is mounted. |
| `DIND_HOST_DOCKER_SOCK` | `/var/run/host-docker.sock` | Path inside the container to the mounted *host* Docker socket used for passthrough. Deliberately **not** `/var/run/docker.sock`, so the inner daemon keeps its own isolated socket. |
| `DIND_HOST_PASSTHROUGH_REGISTRIES` | common public registries | Space-separated allowlist of registries treated as "public" in `DIND_HOST_PASSTHROUGH=public` mode (default: `docker.io ghcr.io quay.io gcr.io registry.k8s.io public.ecr.aws mcr.microsoft.com`). |
| `DIND_HOST_PASSTHROUGH_IMAGES` | _(empty)_ | Space-separated allowlist of image references / globs. When non-empty, only host images matching at least one entry are passed through, composed with the mode filter (so `public` still requires a public RepoDigest). Empty keeps the mode + registry filter only. One level finer than `DIND_HOST_PASSTHROUGH_REGISTRIES` — scope to specific repositories / image names. Each concrete entry (explicit tag/digest) is verified present in the nested daemon after passthrough; a missing one warns loudly instead of falsely reporting "complete" (issue #106). |

Use a named volume when the inner Docker state should survive container removal:

```bash
docker volume create box-dind-data
docker run -d --privileged \
  -v box-dind-data:/var/lib/docker \
  --name box-dind \
  konard/box-dind sleep infinity
```

## Reusing Host Images (Preload)

The nested daemon starts with an **empty image store**. By default a
`docker run <image>` *inside* the container reports
`Unable to find image '<image>' locally` and pulls a fresh copy from the
registry — even when the host daemon already has that exact image (issue #94).
This is the well-known [Docker-in-Docker image-cache pitfall][jpetazzo].

The entrypoint can seed the nested daemon at startup so no re-download happens.

### `DIND_PRELOAD_TARBALL` — load `docker save` tarballs (reuse host images)

On the host, save the image you already have to a tarball, mount it into the
container, and point `DIND_PRELOAD_TARBALL` at it. The entrypoint loads it with
`docker load` as soon as the inner daemon is ready, before your workload runs:

```bash
# Host already has the image; export it without a registry round-trip:
docker pull alpine:3.20
docker save alpine:3.20 -o /tmp/preload/alpine.tar

docker run -d --privileged \
  -v /tmp/preload:/preload:ro \
  -e DIND_PRELOAD_TARBALL=/preload/alpine.tar \
  --name box-dind \
  konard/box-dind sleep infinity

until docker exec box-dind docker info >/dev/null 2>&1; do sleep 1; done

# No "Unable to find image locally" — it was preloaded, not pulled:
docker exec box-dind docker run --rm alpine:3.20 echo hi
```

`DIND_PRELOAD_TARBALL` accepts a space-separated list. Any entry that is a
directory loads every `*.tar` file inside it, so you can mount a whole folder of
saved images:

```bash
docker run -d --privileged \
  -v /tmp/preload:/preload:ro \
  -e DIND_PRELOAD_TARBALL=/preload \
  --name box-dind \
  konard/box-dind sleep infinity
```

You can also bake a tarball into a derived image so every container starts warm:

```dockerfile
FROM konard/box-dind
USER root
COPY images.tar /opt/preload/images.tar
ENV DIND_PRELOAD_TARBALL=/opt/preload/images.tar
USER box
ENV HOME=/home/box
```

### `DIND_PRELOAD_IMAGES` — warm the cache from a registry

When the source is a registry or pull-through mirror rather than a tarball, list
the references in `DIND_PRELOAD_IMAGES`. The entrypoint pulls each one after the
daemon is ready, but skips any image that is already present (for example one a
mounted `/var/lib/docker` volume or a `DIND_PRELOAD_TARBALL` already provided):

```bash
docker run -d --privileged \
  -e DIND_PRELOAD_IMAGES="alpine:3.20 busybox:1.36" \
  --name box-dind \
  konard/box-dind sleep infinity
```

Preload failures are non-fatal: the entrypoint logs a warning and continues so
the container shell still starts. Preload is skipped entirely when
`DIND_SKIP_DAEMON=1`, since there is no inner daemon to load into.

CI covers this behavior here:

```bash
DIND_IMAGE=box-dind-js tests/dind/example-preload-images.sh
```

[jpetazzo]: https://jpetazzo.github.io/2015/09/03/do-not-use-docker-in-docker-for-ci/

## Host-Image Passthrough (`DIND_HOST_PASSTHROUGH`)

`DIND_PRELOAD_*` above are explicit: you name the tarballs or references to seed.
Passthrough is the **automatic** counterpart — when you mount the host Docker
socket into the container, the entrypoint copies images the host *already has*
into the nested daemon at startup, so the inner `docker run` does not re-pull
them. It is on by default (`public` mode) but a quiet no-op until a host socket
is mounted, so the standard `--privileged` run is unchanged.

Mount the host socket at `DIND_HOST_DOCKER_SOCK` (default
`/var/run/host-docker.sock`), read-only:

```bash
docker run -d --privileged \
  -v /var/run/docker.sock:/var/run/host-docker.sock:ro \
  --name box-dind \
  konard/box-dind sleep infinity

until docker exec box-dind docker info >/dev/null 2>&1; do sleep 1; done

# Public host images were copied into the inner daemon — no re-pull:
docker exec box-dind docker images
```

The mount path is deliberately **not** `/var/run/docker.sock`. The host socket is
read only at startup to *seed* images; the inner daemon keeps its own isolated
socket and remains the container's runtime. This preserves the per-container
Docker view from issue #80 — mounting the host socket at the default path would
switch the model to Docker-outside-of-Docker and expose host Docker control
(see [Host Prerequisites](#host-prerequisites)).

### Modes — and why `public` is the default

| Mode | What it copies |
| --- | --- |
| `public` _(default)_ | Only host images carrying a `RepoDigest` from an allowlisted public registry (`DIND_HOST_PASSTHROUGH_REGISTRIES`). A RepoDigest proves the image was pulled from that registry and is freely re-pullable, so copying it leaks **no** local build secrets and needs **no** registry credential. Locally-built images (no RepoDigest) and private-registry images are skipped. |
| `all` | Every tagged host image, including locally-built and private-registry images. Use only when you trust the inner workload with those images. |
| `off` (also `0`/`false`/`no`) | Disable passthrough entirely. |

```bash
# Pass through everything the host has, including local builds:
docker run -d --privileged \
  -v /var/run/docker.sock:/var/run/host-docker.sock:ro \
  -e DIND_HOST_PASSTHROUGH=all \
  --name box-dind \
  konard/box-dind sleep infinity

# Opt out completely:
docker run -d --privileged \
  -e DIND_HOST_PASSTHROUGH=off \
  --name box-dind \
  konard/box-dind sleep infinity
```

Passthrough is idempotent and additive: an image already present in the inner
daemon (from a volume, tarball, or earlier run) is skipped, and any single
image that fails to copy logs a warning and continues. Like preload, it is
skipped entirely when `DIND_SKIP_DAEMON=1`.

### Scoping to specific images (`DIND_HOST_PASSTHROUGH_IMAGES`)

The mode gate decides *whether* an image is safe to pass; the registry allowlist
narrows it *by registry host*. `DIND_HOST_PASSTHROUGH_IMAGES` is one level finer
— it scopes passthrough to **specific repositories / image names**. When it is
non-empty, a host image must match the mode filter **and** at least one
space-separated pattern; empty (the default) keeps the mode + registry behavior.

This is the precise fit for "seed the inner daemon with only the images I own"
rather than every public host image:

```bash
# Pass through only hive-mind's own images, nothing else on the host:
docker run -d --privileged \
  -v /var/run/docker.sock:/var/run/host-docker.sock:ro \
  -e DIND_HOST_PASSTHROUGH=public \
  -e DIND_HOST_PASSTHROUGH_IMAGES="konard/hive-mind konard/hive-mind-dind" \
  --name box-dind \
  konard/box-dind sleep infinity

# Globs and explicit tags / registry-qualified refs also work:
docker run -d --privileged \
  -v /var/run/docker.sock:/var/run/host-docker.sock:ro \
  -e DIND_HOST_PASSTHROUGH_IMAGES="docker.io/konard/hive-mind* konard/hive-mind-dind:latest" \
  --name box-dind \
  konard/box-dind sleep infinity
```

Patterns are matched against several normalized forms of each host image
reference, so a bare repository like `konard/hive-mind` matches the tagged
`konard/hive-mind:latest` and the registry-qualified
`docker.io/konard/hive-mind:latest` alike. Because it composes with the mode
gate, `public` mode still refuses a locally-built or private image even when it
matches a pattern — the allowlist only ever *narrows* the eligible set, it never
widens it past the security filter.

Setting `DIND_HOST_PASSTHROUGH_IMAGES` is an unambiguous "I expect these images
passed through" signal. So if it is set but **no host socket is mounted**, the
entrypoint no longer stays silent — it emits a single warning naming the
missing `-v /var/run/docker.sock:/var/run/host-docker.sock:ro` mount, because
the nested daemon will otherwise re-pull from the registry on the first
`docker run` with no hint as to why (issue #102). Plain `box-dind` containers
that never set an allowlist still see no extra noise when no socket is mounted.

### Verifying the copy actually happened (`issue #106`)

A warning about a forgotten mount only covers one failure mode. Passthrough can
also quietly seed *nothing* for other reasons — the host does not have the image
under that exact reference, the socket is present but unreachable, or `public`
mode filtered out a locally-built image (no RepoDigest). In every case the
entrypoint used to print `image preload/passthrough complete` regardless, and
the first nested `docker run` then silently re-pulled the multi-GB image from the
registry (~30 GB, ~1 h downstream — `link-assistant/hive-mind#1914`/`#1946`).

So after passthrough runs, each **concrete** `DIND_HOST_PASSTHROUGH_IMAGES`
entry — one with an explicit tag or digest, no glob — is verified to actually be
present in the nested daemon (`docker image inspect <ref>`). When one is
missing, the entrypoint:

- emits a loud, actionable warning naming the un-seeded image(s) and the likely
  cause (missing/unreachable socket, host lacks that exact ref, or the mode
  filter dropped it — with the `DIND_HOST_PASSTHROUGH=all` remedy for
  locally-built/private images), and
- ends the phase with `image preload/passthrough finished WITH WARNINGS`
  instead of the misleading `...complete`, so logs never claim success when
  nothing was copied.

Bare repositories (`konard/hive-mind`) and globs (`konard/hive-mind*`) are not
concrete — the host may hold them under any tag — so they are not individually
verified and never trigger a false alarm. To get this assertion for a specific
image, pin it in the allowlist with an explicit tag or digest, e.g.
`DIND_HOST_PASSTHROUGH_IMAGES=konard/hive-mind-dind:2.0.6`.

## Knowing When the Image Cache Is Ready

`docker info` (or `docker exec ... docker info`) starts succeeding the moment the
inner daemon's socket is up — which is **long before** a multi-GB host-image
passthrough or tarball preload has finished loading. A host that waits only on
`docker info` and then immediately runs a workload can therefore still hit a
re-pull, because the seeding copy was not done yet (issue #110, finding #2).

Passthrough/preload already runs **synchronously before the container hands off
to your workload**, so by the time your `CMD` runs the cache is seeded. The
`DIND_READY_FILE` sentinel exposes that same completion to the *host*, so an
external orchestrator can block on it deterministically:

```bash
docker run -d --privileged \
  -v /var/run/docker.sock:/var/run/host-docker.sock:ro \
  -e DIND_HOST_PASSTHROUGH_IMAGES=alpine:3.20 \
  --name box-dind \
  konard/box-dind sleep infinity

# Block until the preload/passthrough phase actually finished (not just dockerd):
until docker exec box-dind test -f /tmp/box-dind-ready; do sleep 1; done

# 'complete' = every requested image seeded; 'warnings' = some did not (see logs):
status="$(docker exec box-dind cat /tmp/box-dind-ready)"
echo "preload status: $status"
```

The file is written once, at the end of the preload phase, with `complete` when
every concrete requested image is present in the inner daemon, or `warnings` when
one or more were not seeded (the entrypoint logs the specifics, including the
inaccessible-socket and `--group-add` cases below). Point `DIND_READY_FILE` at a
different path, or at a mounted volume, to surface it wherever your tooling
expects. It is DinD-only — in DooD there is no nested daemon to seed, so nothing
is written.

## Docker-outside-of-Docker (DooD)

DooD is a **first-class, supported mode** of the same image: instead of starting
a nested daemon, the in-container Docker CLI talks to the **host** daemon through
its mounted socket. Reuse of host images is then automatic and free — there is no
copy and no extra disk, because there is only one image store (issue #110,
findings #3 and #4).

Select it with two run flags — set `DIND_SKIP_DAEMON=1` and mount the host socket
at the **real runtime path** `/var/run/docker.sock` (note: this is *not* the
passthrough path `/var/run/host-docker.sock`):

```bash
docker run -d \
  -e DIND_SKIP_DAEMON=1 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --group-add "$(stat -c '%g' /var/run/docker.sock)" \
  --name box-dood \
  konard/box-dind sleep infinity

# Talks to the HOST daemon — its images are already here, no copy, no re-pull:
docker exec box-dood docker images
docker exec box-dood docker ps        # shows the host's containers (shared view)
```

No `--privileged` is required for DooD: the container is not running its own
daemon, so it needs no extra kernel privileges — only access to the socket.

### The `--group-add` requirement

The host socket is owned by the host's `docker` group (for example GID `988`).
Inside the container, the box user is a member of the *image's* `docker` group
(a different GID, for example `995`), so by default it **cannot read the mounted
host socket** and every `docker` command fails with a permission error. A
supplementary group cannot be granted to an already-running process, so this must
be fixed at `docker run` time:

```bash
--group-add "$(stat -c '%g' /var/run/docker.sock)"
```

`stat -c '%g' /var/run/docker.sock` reads the host socket's owning GID on the
host; `--group-add` makes the box user a member of exactly that GID inside the
container. This is the correct fix — it grants access **without mutating the
shared host socket's group**.

The entrypoint **never `chgrp`s the host socket**, even when it is mounted
read-write. The host's `/var/run/docker.sock` is shared with every other process
on the host, so changing its group from inside the container would silently lock
other host users out of Docker. So when box is not already a member of the
socket's owning GID, the entrypoint does not try to "fix" the socket — it emits a
**loud error naming the exact GID and the `--group-add` value to use**, e.g.:

```text
[dind-entrypoint] WARN: the Docker socket at /var/run/docker.sock is owned by GID 988, which the in-container box user is not a member of, so box cannot access it.
[dind-entrypoint] WARN: re-run the container with --group-add 988 so box can read the socket, e.g.: docker run ... --group-add 988 ... (issue #110)
```

### Isolation trade-off (DooD vs DinD)

DooD deliberately gives up the per-container isolation that DinD provides. The
in-container Docker controls the **host** daemon: `docker ps` lists the host's
containers, and a `docker rm`/`docker run` from inside affects the host. Use DooD
only for workloads you trust with host Docker control. When you need a workload to
be unable to see or touch host containers, use DinD (the `--privileged` default)
and seed images with [passthrough](#host-image-passthrough-dind_host_passthrough)
or [preload](#reusing-host-images-preload) instead.

CI covers the DooD flow as an executable example:

```bash
DIND_IMAGE=box-dind-js tests/dind/example-dood-host-socket.sh
```

## Commit Cycles

`DIND_SKIP_DAEMON=1` is useful for setup containers where you want to install or
configure files before committing an image:

```bash
docker run -d --name box-dind-setup \
  -e DIND_SKIP_DAEMON=1 \
  konard/box-dind sleep infinity

docker exec box-dind-setup bash -lc 'echo setup complete'
docker commit --change 'ENV DIND_SKIP_DAEMON=0' box-dind-setup my-box-dind
docker run -d --privileged --name my-box-dind my-box-dind sleep infinity
```

The `--change 'ENV DIND_SKIP_DAEMON=0'` reset is intentional. Docker commit
preserves container environment, so committing a setup container that has
`DIND_SKIP_DAEMON=1` can produce an image that silently skips dockerd on later
runs.

CI covers this behavior here:

```bash
DIND_IMAGE=box-dind-js tests/dind/example-commit-cycle.sh
```

## Sudoers Contract

The image installs `/etc/sudoers.d/box-dind` with passwordless sudo for only the
root operations required by the DIND entrypoint:

```text
/usr/bin/dockerd
/usr/bin/chgrp
/usr/bin/chmod
/usr/bin/mkdir
```

Do not broaden this file into general passwordless sudo. If a derived image
needs one additional root capability, add a separate sudoers file with the exact
absolute binary path and validate it with `visudo`:

```dockerfile
FROM konard/box-dind

USER root
RUN printf '%s\n' 'box ALL=(root) NOPASSWD: /usr/bin/id' \
      | install -m 0440 -o root -g root /dev/stdin /etc/sudoers.d/box-dind-example-id && \
    visudo -cf /etc/sudoers.d/box-dind-example-id >/dev/null

USER box
ENV HOME=/home/box
```

CI builds and verifies that pattern:

```bash
DIND_IMAGE=box-dind-js tests/dind/example-sudoers-extension.sh
```

## Storage Driver

When `DIND_STORAGE_DRIVER` is empty, the entrypoint tries `overlay2` if the
host advertises overlay support, then `fuse-overlayfs` if it is installed, then
`vfs`. If a candidate makes `dockerd` exit before it is ready, the entrypoint
logs the failure and retries the next candidate. This covers nested runtimes
where overlay support is visible but overlay-backed Docker still cannot start.

Use the default for normal developer workflows. Pin `DIND_STORAGE_DRIVER=vfs`
when the host cannot run overlay-backed nested Docker reliably or when you need
the most conservative compatibility mode. The trade-off is disk use and
performance: `vfs` copies whole filesystem trees instead of using overlay
copy-on-write layers.

```bash
docker run -d --privileged \
  -e DIND_STORAGE_DRIVER=vfs \
  --name box-dind-vfs \
  konard/box-dind sleep infinity
```

Because that trade-off is easy to hit by accident, the entrypoint emits a
one-time warning whenever the **active** driver ends up being `vfs` — whether
pinned explicitly or reached as the last-resort fallback (issue #104). `vfs`
stores every image layer as a full, independent copy, so a multi-GB image's
on-disk footprint becomes the *sum* of all cumulative layer sizes — many times
the image size — and `docker pull`/`docker run` can fail with `failed to register
layer: no space left on device` on a disk far larger than the image. The warning
makes that failure traceable instead of looking like a generic "out of disk".

If your host supports it, prefer `DIND_STORAGE_DRIVER=fuse-overlayfs`: it is
copy-on-write **and** works overlay-on-overlay (the compatibility reason `vfs` is
sometimes chosen), is already shipped in the image, and needs `/dev/fuse`
(provided by `--privileged`). The warning's remediation line adapts to whether
`/dev/fuse` is present, so when it is missing it tells you to add `--privileged`
or `--device /dev/fuse` before switching.

```bash
docker run -d --privileged \
  -e DIND_STORAGE_DRIVER=fuse-overlayfs \
  --name box-dind-cow \
  konard/box-dind sleep infinity
```

CI verifies the forced `vfs` path:

```bash
DIND_IMAGE=box-dind-js tests/dind/example-storage-driver-vfs.sh
```

## Host Prerequisites

The host kernel and Docker runtime must allow the inner daemon to create the
mounts, namespaces, cgroups, and networking state that Docker Engine needs.
In practice:

- Use `--privileged` for the standard nested Docker mode, or install and use
  `sysbox-runc` for the Sysbox mode.
- For **DinD** (the isolated default), do not bind-mount `/var/run/docker.sock`
  from the host: that switches the model to Docker-outside-of-Docker, exposes
  host Docker control, and breaks the per-container Docker view. To *reuse* host
  images while staying isolated, mount the socket read-only at the **passthrough**
  path `/var/run/host-docker.sock` instead (see
  [Host-Image Passthrough](#host-image-passthrough-dind_host_passthrough)).
- For **DooD** (a supported, opt-in mode), bind-mounting `/var/run/docker.sock`
  at the real runtime path is exactly the point — set `DIND_SKIP_DAEMON=1` and add
  `--group-add "$(stat -c '%g' /var/run/docker.sock)"`. See
  [Docker-outside-of-Docker (DooD)](#docker-outside-of-docker-dood) for the trade-off.
- Ensure enough disk is available for `/var/lib/docker`, or mount a volume there.
- If dockerd does not become ready, inspect `docker logs <container>` and the
  configured `DIND_LOG_FILE` inside the container before changing timeouts.

## Local Example Runner

To run the same examples CI runs against a local image:

```bash
docker build -f ubuntu/24.04/dind/Dockerfile \
  --build-arg BASE_IMAGE=konard/box-js:latest \
  -t box-dind-js .

DIND_IMAGE=box-dind-js tests/dind/example-basic-docker-ps.sh
DIND_IMAGE=box-dind-js tests/dind/example-commit-cycle.sh
DIND_IMAGE=box-dind-js tests/dind/example-sudoers-extension.sh
DIND_IMAGE=box-dind-js tests/dind/example-storage-driver-vfs.sh
DIND_IMAGE=box-dind-js tests/dind/example-preload-images.sh
DIND_IMAGE=box-dind-js tests/dind/example-dood-host-socket.sh
```

Set `DIND_KEEP_CONTAINERS=1` while debugging to keep the temporary containers
and images after a failing example.
