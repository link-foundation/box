# Case Study: Issue #110 — Fully support & document both DooD and DinD workflows

## Executive Summary

The `box-dind` image could *technically* run in two modes — **Docker-in-Docker
(DinD)**, a nested daemon seeded by host-image passthrough, and
**Docker-outside-of-Docker (DooD)**, where the in-container CLI drives the host
daemon — but only DinD was documented and supported end-to-end. Wiring a
production deploy on a disk-constrained host (Docker Engine 29.5, containerd
snapshotter, `overlayfs`) surfaced four gaps, reported in issue #110:

| # | Finding | Resolution in this PR |
|---|---|---|
| 1 | Host-socket passthrough silently fails because box is not in the socket's GID; the entrypoint logs a vague WARN and still prints `complete`. | **Code + docs.** The entrypoint detects the socket's owning GID and prints the **exact** `--group-add <gid>` to re-run with; the inaccessible path now ends `WITH WARNINGS`, never a false `complete`. Documented. |
| 2 | Passthrough isn't observably "ready"; `docker info` succeeds long before a multi-GB load finishes. | **Code + docs.** Seeding already blocks handoff to the workload; a `DIND_READY_FILE` sentinel (`complete`/`warnings`) now exposes that completion to the host so it can wait deterministically. |
| 3 | Passthrough is a full `save\|load` COPY (doubles disk); no zero-copy share mode for a containerd-snapshotter host. | **Docs (DooD is the zero-copy path).** A dedicated read-only additional-image-store mount for DinD was evaluated and **deferred** (see §4); DooD is documented as the supported zero-copy / zero-extra-disk option, exactly as the issue itself notes. |
| 4 | DooD works but is undocumented and "unsupported". | **Code + docs + test.** DooD is now a first-class, documented, CI-tested mode of the same image, selected purely by run flags; the entrypoint announces it and makes the real-runtime socket box-readable (without mutating it — see §3). |

A serious bug was **caught during end-to-end verification and fixed before
merge**: the first implementation of the socket fix `chgrp`'d the runtime socket
into the image's `docker` group on any writable mount. In DooD that path is the
*host's shared* `/var/run/docker.sock` — the `chgrp` changed its group on the
host (observed: GID `995` → `991`) and **locked the host user out of Docker**
(`permission denied while trying to connect to the docker API`). The fix now
never mutates a shared socket. See §3.

---

## 1. Requirements extracted from the issue

| # | Requirement | Status |
|---|---|---|
| R1 | Auto-handle the host-socket group, or document `--group-add`, or at minimum make the inaccessible path a loud error instead of a false `complete`. | ✅ All three: precise `--group-add <gid>` emitted, documented, and `WITH WARNINGS` marker. |
| R2 | Block startup until passthrough load completes, or expose a clear completion signal; verify after the load. | ✅ Seeding already blocks handoff; `DIND_READY_FILE` exposes it to the host. Concrete-tag verify (#106) runs after the load and governs the marker. |
| R3 | Zero-copy / share mode so the nested daemon sees host images with no copy and no extra disk. | ⚠️ Deferred for DinD (additional read-only image store — see §4); DooD documented as the supported zero-copy path. |
| R4 | Document DooD as a first-class supported mode (recipe, `--group-add`, isolation trade-off); confirm the socket fix covers the real-runtime socket. | ✅ Documented + CI-tested; socket handling covers the DooD runtime socket safely. |
| R5 | Docs: a "DinD vs DooD" section with copy-paste recipes, the socket-group requirement, the disk/copy trade-off, and "one image, mode chosen by run flags". | ✅ Added to `docs/dind/USAGE.md`; README security model reframed. |

---

## 2. Findings #1, #2, #4 — what changed in the entrypoint

`ubuntu/24.04/dind/dind-entrypoint.sh`:

- **Socket GID detection (finding #1).** New helpers `socket_gid()` (reads
  `stat -c %g`) and `current_user_in_gid()` (scans `id -G`). `grant_socket_access`
  uses them: if box already belongs to the socket's group (e.g. a `--group-add`
  was supplied) the socket is left untouched; otherwise it prints the exact
  remediation:

  ```
  WARN: the Docker socket at /var/run/docker.sock is owned by GID 995, which the
        in-container box user is not a member of, so box cannot access it.
  WARN: re-run the container with --group-add 995 so box can read the socket,
        e.g.: docker run ... --group-add 995 ... (issue #110)
  ```

- **Honest completion + readiness signal (finding #2).** `preload_into_daemon`
  tracks a `passthrough_status`; an inaccessible passthrough socket flips the
  terminal line from `image preload/passthrough complete` to `...finished WITH
  WARNINGS`. A new `write_ready_file()` writes `DIND_READY_FILE`
  (default `/tmp/box-dind-ready`) with `complete` or `warnings`. Passthrough was
  already synchronous — it blocks before the workload handoff — so the real gap
  was the lack of an *external* signal, which the sentinel now provides:

  ```bash
  until docker exec box-dind test -f /tmp/box-dind-ready; do sleep 1; done
  status="$(docker exec box-dind cat /tmp/box-dind-ready)"   # complete | warnings
  ```

- **DooD announced and supported (finding #4).** The `DIND_SKIP_DAEMON=1` branch
  logs that it is running Docker-outside-of-Docker against the mounted
  `/var/run/docker.sock`, and `fix_socket_permissions` makes that socket usable
  by box (via the `--group-add` guidance, never mutation — §3).

---

## 3. The host-socket mutation bug (caught in live verification)

The first implementation generalized the long-standing inner-socket fix to *any*
writable socket: `chgrp docker <sock> && chmod 660 <sock>`. That is correct for
the **DinD inner socket**, which is private to the container. It is **dangerous
for the DooD host socket**, which is the host's shared `/var/run/docker.sock`.

Reproduced end-to-end against a real host socket with a purpose-built minimal
image whose `docker` group GID (`991`) deliberately differed from the host
socket's GID (`995`):

```
# DooD, writable mount, no --group-add — first (buggy) implementation:
$ stat -c '%g' /var/run/docker.sock      # before: 995
$ docker run -d -e DIND_SKIP_DAEMON=1 -v /var/run/docker.sock:/var/run/docker.sock box-dood-mini sleep infinity
$ stat -c '%g' /var/run/docker.sock      # after:  991   ← host socket mutated!
$ docker ps                              # permission denied — host user locked out
```

**Fix.** `grant_socket_access` gained an `adopt` mode:

| Mode | Used for | Action when box lacks access |
|---|---|---|
| `adopt` | DinD **inner** socket (private) | `chgrp` into the image `docker` group |
| `keep`  | DooD **host** socket / `:ro` passthrough (shared) | **never** `chgrp`; emit `--group-add <gid>` |

`fix_socket_permissions` selects `keep` when `DIND_SKIP_DAEMON=1`, `adopt`
otherwise. Re-verified after the fix:

```
# no --group-add: host socket stays 995, loud --group-add 995 guidance, no false complete
# with --group-add "$(stat -c %g /var/run/docker.sock)":
$ docker exec dood-ok id        # ...,995  (joined the host socket's GID)
$ docker exec dood-ok docker info        # REACHED host daemon
$ docker exec dood-ok docker ps          # lists dood-ok itself → talking to the HOST daemon
$ stat -c '%g' /var/run/docker.sock      # still 995 — never mutated
```

Regression guard: unit-test Case 27 asserts `keep` mode never invokes `chgrp`
even when it *would* succeed, while `adopt` mode still does.

---

## 4. Finding #3 — zero-copy share mode (deferred, with rationale)

The issue's most-impactful request is a DinD **share** mode: bind-mount the
host's image layers as a read-only *additional image store* so the nested daemon
sees host images with zero copy. This was evaluated and **deferred**:

- The host runs the **containerd snapshotter**; its layer store is not
  format-compatible with a classic nested `overlay2`/`fuse-overlayfs` daemon's
  store, so a read-only lower store cannot simply be bind-mounted across the two.
  Docker's additional-image-store support targets the classic graphdriver layout,
  not a cross-snapshotter share.
- The issue itself concludes that **DooD is the only zero-copy / zero-extra-disk
  option today**. This PR makes that path first-class and documented, which
  satisfies the underlying need (reuse host images with no copy on a
  disk-constrained host) without a fragile, snapshotter-specific store hack.

So R3's user-facing goal is met via DooD; a native DinD additional-store mode
remains future work and is called out as such in the docs.

---

## 5. Documentation

- `docs/dind/USAGE.md`: a **DinD vs DooD** comparison table ("one image, mode
  chosen by run flags"), a **Docker-outside-of-Docker (DooD)** section (recipe,
  the `--group-add` requirement, the isolation trade-off), a **Knowing When the
  Image Cache Is Ready** section (`DIND_READY_FILE`), the `DIND_SKIP_DAEMON` /
  `DIND_READY_FILE` env-var rows, and a reframed Host Prerequisites note.
- `README.md`: the Docker-in-Docker security model now distinguishes isolated
  DinD (don't mount the runtime socket) from the supported DooD opt-in (mount it
  + `--group-add`, with the isolation trade-off spelled out).

---

## 6. Tests

- `experiments/preload-unit-test.sh` — **85 assertions**, including Cases 23–27
  covering the GID helpers, the `--group-add` remedy, the `WITH WARNINGS` marker,
  `DIND_READY_FILE`, and the host-socket-safety regression guard.
- `tests/dind/example-dood-host-socket.sh` — new CI-run example that exercises
  the real DooD flow (`DIND_SKIP_DAEMON=1` + host socket +
  `--group-add "$(stat -c '%g' /var/run/docker.sock)"`) and asserts the
  in-container CLI reaches the host daemon and sees its own host container. Wired
  into `release.yml`'s documented-dind-examples step.

---

## 7. Files changed

| File | Change |
|---|---|
| `ubuntu/24.04/dind/dind-entrypoint.sh` | Socket GID helpers, adopt/keep `grant_socket_access`, `DIND_READY_FILE`, honest completion marker, DooD announce. |
| `docs/dind/USAGE.md` | DinD-vs-DooD, DooD section, readiness section, env-var rows, reframed prerequisites. |
| `README.md` | Security model reframed for DinD vs DooD. |
| `experiments/preload-unit-test.sh` | Cases 23–27. |
| `tests/dind/example-dood-host-socket.sh` | New CI-run DooD example. |
| `.github/workflows/release.yml` | Run the new DooD example. |
| `.changeset/dind-dood-first-class.md` | `minor` bump. |
