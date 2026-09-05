# Case Study: Issue #112 — Stale runtimes: track LTS forward, refresh what is copied, keep one version per language

## Executive Summary

`konard/box:latest` was shipping runtimes that had been frozen at whatever was
current when each install script was written, and — worse — carrying *two*
copies of some of them. Three defects, all with the same shape (a version
decided at authoring time instead of at build time), plus one that the images
could not fix by editing a script at all, because it is a property of how Docker
layers work.

| # | Finding | Root cause | Resolution |
|---|---|---|---|
| 1 | `box-js` shipped Node 20 forever. | `ubuntu/24.04/js/install.sh` ran `nvm install 20` / `nvm use 20`. | The Node major is resolved from nodejs.org's release feed at build time, `nvm alias default` makes it the login-shell Node, and any other Node in the tree is uninstalled. |
| 2 | The full image carried a 2.2 GB `~/.rustup` with a stale `stable` (1.96.0) *next to* a newer pinned toolchain (1.98.0). | `COPY --from=rust-stage` bakes whatever the (often cached) `konard/box-rust:latest` was built with. Updating after the `COPY` cannot help: the stale bytes are already committed and a later `rm -rf` only writes a whiteout. | `full-box/refresh-rust.sh` binds the stage with `RUN --mount=type=bind,from=rust-stage` and does copy + `rustup update` + prune **inside one layer**. |
| 3 | Nothing stopped an image from shipping two runtimes of the same language. | No invariant existed. | `assert_single_runtime_versions()` fails the build if a second version appears under any language root; every language install script calls it and CI asserts it on the built image. |
| 4 | *(maintainer follow-up on the issue)* "all boxes must deliver the most fresh latest LTS versions of all dependencies". | Java 21, .NET 8.0, PHP 8.3, Swift 6.0.3, opam 2.3.0, Ruby restricted to `3.x`, nvm v0.40.3 were all hardcoded. | A single version policy in `ubuntu/24.04/common.sh`, used by every box, the standalone installer and the disk-space measurement script. |
| 5 | *(maintainer follow-up on the issue)* CI spent the whole expensive matrix on commits the pull request had already moved past — while the newest commit never ran. | `concurrency: { group: <workflow>-<ref>, cancel-in-progress: true }` is a deadlock for pull requests: a run blocked on the group is `pending`, executes no step, and therefore cannot cancel the predecessor that is holding it. | Pull-request runs get a **unique** concurrency group so they always start, and supersession is explicit — `scripts/ci/supersede.sh`, with the cancel verified and escalated to `force-cancel` (§7). |

Measured, not asserted: the layer behaviour behind finding #2 is reproduced by
`experiments/rust-refresh-layer-test.sh`, which builds both variants with a
128 MB payload and compares image sizes — **`COPY` + later delete: +256 MB;
`RUN --mount` + prune in-layer: +128 MB.**

---

## 1. Requirements extracted from the issue

| # | Requirement | Status |
|---|---|---|
| R1 | Track Node forward: resolve the current LTS at build time and `nvm alias default` it. | ✅ `resolve_node_lts_major()` + `nvm alias default`, asserted in CI against the live feed. |
| R2 | Refresh rustup `stable` **in the layer that creates it**, since a later `rm -rf` only writes a whiteout. | ✅ `full-box/refresh-rust.sh` under `RUN --mount=type=bind,from=rust-stage`; the layer arithmetic is measured by an experiment. |
| R3 | Keep one version per language root (`~/.nvm/versions/node`, `~/.rustup/toolchains`, `~/.pyenv/versions`, `~/.sdkman/candidates/*`) as a build-time invariant. | ✅ `assert_single_runtime_versions()`, called by every install script and re-checked on the built image in CI. |
| R4 | (Issue comment) Every box delivers the freshest LTS of every dependency, and of the OS. | ✅ Every box, plus the standalone installers (§5); Ubuntu stays 24.04 LTS — see §6. |
| R5 | (Issue comment) "previous commits skip execution in pull requests, if multiple are committed in the order. So we only execute on last commit, and reduce resource waste on all previous commits." | ✅ Unique per-run concurrency group + explicit supersession (`scripts/ci/supersede.sh`) — see §7. |

---

## 2. The version policy (`ubuntu/24.04/common.sh`)

Every resolver answers in the same three-layer order, so a build is
overridable, current by default, and never fails because a feed is down:

```
explicit override  >  upstream release feed  >  pinned fallback
```

| Resolver | Feed | Override | Fallback |
|---|---|---|---|
| `resolve_node_lts_major` | `nodejs.org/dist/index.json`, newest entry with a non-`false` `lts` | `NODE_VERSION` | 24 |
| `resolve_nvm_version` | `nvm-sh/nvm` `/releases/latest` redirect | `NVM_VERSION` | v0.40.7 |
| `resolve_java_lts_major` | `api.sdkman.io/2/candidates/java/linuxx64/versions/list`, filtered to the LTS cadence (8, 11, 17, then every 4th from 21) | `JAVA_VERSION` | 25 |
| `resolve_dotnet_lts_channel` / `resolve_dotnet_apt_channel` | `releases-index.json`, intersected with what this archive can install (`apt_has_package`) | `DOTNET_CHANNEL` | 10.0 / 8.0 |
| `resolve_swift_versions` | `swift.org/api/v1/install/releases.json`, newest-first list | `SWIFT_VERSION` | 6.3.3 |
| `resolve_opam_version` | `ocaml/opam` `/releases/latest` redirect | `OPAM_VERSION` | 2.5.2 |
| `add_cran_repo` | CRAN's `<codename>-cran40` suite + `marutter_pubkey.asc` | — | distro `r-base` |

Live output of the resolvers while writing this (they are exercised on every PR
by `pr-test / version-policy`):

```
node=24  nvm=v0.40.7  java=25  dotnet=10.0  swift=6.3.3 6.3.2 6.3.1 6.3 6.2.4  opam=2.5.2
```

Two resolvers deserve a note:

- **.NET** is resolved *twice*. `resolve_dotnet_lts_channel()` says what
  Microsoft considers the current LTS; `resolve_dotnet_apt_channel()` then keeps
  only a channel for which `dotnet-sdk-<channel>` actually exists in the
  configured archive, walking down if it does not. Installing "the newest LTS"
  blindly would break the build the day Microsoft declares an LTS the Ubuntu
  archive has not published yet.
- **Swift** returns a *list*, not a version. swift.org does not publish an
  `ubuntu2404`/`aarch64` tarball for every release, so the install script probes
  each candidate URL and takes the newest that really exists. The probe has to
  follow redirects — `remote_file_exists()` uses `curl -fsSIL`, not `-fsSI` —
  because download.swift.org answers a missing tarball with `302 ->
  swift.org/404.html`, which `curl -f` reports as *success*:

  ```console
  $ curl -fsSI  .../swift-6.3.3-RELEASE-ubuntu26.04.tar.gz >/dev/null; echo $?
  0            # the 302 itself; the file does not exist
  $ curl -fsSIL .../swift-6.3.3-RELEASE-ubuntu26.04.tar.gz >/dev/null; echo $?
  22           # follows through to the real 404
  ```

  Without `-L` the loop accepts its first candidate on every platform, which is
  the same class of bug as the hardcoded version it replaced. The unit test
  mocks that exact redirect, so the probe cannot regress to `-fsSI`.

The pinned fallbacks are the only hardcoded versions left in the repository, and
they are reachable only when the feed is unreachable.

---

## 3. Finding #2 — why the rustup fix had to change the *layer*, not the script

The full image builds Rust like this:

```dockerfile
COPY --from=rust-stage /home/box/.rustup /home/box/.rustup
```

and `rust-stage` is `konard/box-rust:latest` whenever the rust matrix did not
rebuild — so `stable` is a snapshot from whenever that image was last built. The
obvious repairs both fail:

- `rustup update` *after* the `COPY` **adds** a toolchain. The stale one is
  already committed in the copied layer.
- `rustup toolchain uninstall` after the `COPY` deletes nothing from the image.
  A delete in a later layer writes a whiteout; the bytes stay in the earlier
  layer and still ship.

`experiments/rust-refresh-layer-test.sh` builds three tiny images to make that
concrete — a stage carrying a 128 MB payload, one image that `COPY`s it and
deletes it in a later `RUN`, and one that binds the stage and copies + prunes
inside a single `RUN`:

```
A: COPY --from + later rm -rf : 330 MB (+256 MB over the base)
B: RUN --mount + prune in-layer : 202 MB (+128 MB over the base)
```

`+256 MB` for a 128 MB payload is the whiteout: the image pays for the payload
twice — once for the copy, once more for nothing. That is exactly the shape of
the 2.2 GB `~/.rustup` in the issue.

So `Dockerfile` and `ubuntu/24.04/full-box/Dockerfile` now do:

```dockerfile
RUN --mount=type=bind,from=rust-stage,source=/home/box,target=/mnt/rust-home \
    --mount=type=bind,source=ubuntu/24.04/common.sh,target=/tmp/common.sh \
    --mount=type=bind,source=ubuntu/24.04/full-box/refresh-rust.sh,target=/tmp/refresh-rust.sh \
    bash /tmp/refresh-rust.sh
```

`refresh-rust.sh` copies the stage home, `chown`s it, re-executes itself as
`box` (rustup must not write root-owned files into the box home), runs
`rustup update stable && rustup default stable`, uninstalls every other
toolchain and finally calls `assert_single_runtime_versions`. All of it in one
`RUN`, so only the refreshed toolchain is ever committed. Both Dockerfiles gained
`# syntax=docker/dockerfile:1` and CI sets `DOCKER_BUILDKIT=1`, because the PR
test tiers use plain `docker build`.

The same reasoning applies to the language image itself: `rust/install.sh` now
refreshes unconditionally (`rustup self update`, `rustup update stable`) rather
than skipping when `rustup` already exists, because the script very often runs
on top of a months-old `~/.rustup`.

---

## 4. Finding #3 — the one-version invariant

```bash
assert_single_runtime_versions   # in ubuntu/24.04/common.sh
```

counts entries under `~/.nvm/versions/node`, `~/.rustup/toolchains`,
`~/.pyenv/versions`, `~/.rbenv/versions` and every `~/.sdkman/candidates/*`, and
returns non-zero if any root holds more than one. Every install script calls it
at the end, so a build fails at the layer that introduced the duplicate instead
of shipping it.

A second entry is never harmless: it is a stale runtime carried in from a cached
language image, it costs 0.5–1.5 GB, and it makes the effective interpreter
depend on which version a directory happens to select. So every install script
also *prunes* before asserting — `nvm uninstall`, `rustup toolchain uninstall`,
`pyenv uninstall -f`, `rm -rf ~/.rbenv/versions/<v>`, `sdk uninstall java`.

Two version managers needed an extra fix to be able to install anything recent
at all: **pyenv** and **ruby-build** ship their list of installable versions as
data in the repository, so a clone made months ago cannot install a release made
since. Both are now `git pull --ff-only`'d before "install the latest" is asked
of them.

---

## 5. Finding #4 — every box, and the standalone installers

| Box | Before | After |
|---|---|---|
| js | `nvm install 20`, nvm installer pinned `v0.40.3` | resolved LTS + `nvm alias default`, resolved nvm tag |
| java | `sdk install java 21-tem` | `resolve_java_lts_major()` (25 today), made default, other JDKs uninstalled |
| kotlin | `sdk install java 21-tem` for its JVM | same resolver as the java box |
| dotnet | `apt install dotnet-sdk-8.0` | `resolve_dotnet_apt_channel()` (10.0 today) |
| php | `shivammathur/php/php@8.3` + `php8.3-*` apt packages | unversioned homebrew-core `php` (current stable) and unversioned `php-*` apt metapackages; `PHP_BREW_FORMULA` pins |
| swift | `SWIFT_VERSION="6.0.3"` | newest release with a real `ubuntu2404` build, probed |
| ruby | `grep -E '^\s*3\.[0-9]+\.[0-9]+$'` — could never leave Ruby 3 | any-major filter, ruby-build refreshed first |
| r | distro `r-base` (frozen for the life of the release) | CRAN's maintained build via `add_cran_repo()`, degrading to distro R |
| rocq | `opam-2.3.0-<arch>-linux` under `/releases/latest/download/` | `resolve_opam_version()` + an explicit tag URL |
| rust | install only if absent | always refresh `stable`, prune extra toolchains |
| python | pyenv clone used as-is | pyenv refreshed, extra interpreters pruned |

The `rocq` change also fixes a live 404: `/releases/latest/download/<asset>`
only resolves when `<asset>` exists in the *newest* release, so
`opam-2.3.0-x86_64-linux` stopped resolving the day opam 2.4 shipped and the
fallback path had been silently broken.

`scripts/ubuntu-24-server-install.sh` and `scripts/measure-disk-space.sh` are
standalone (`curl | bash`) and cannot assume the repository is present. They now
locate `ubuntu/24.04/common.sh` next to themselves, at `/tmp/common.sh`, or
fetch it, and call each resolver **in a subshell** so `common.sh` cannot clobber
their own coloured `log_*` helpers:

```bash
box_resolve() {
  local fn="$1" fallback="$2" out=""
  if [ -n "$BOX_COMMON_SH" ]; then
    out=$( (set +eu; . "$BOX_COMMON_SH" >/dev/null 2>&1; "$fn" 2>/dev/null) ) || out=""
  fi
  if [ -n "$out" ]; then echo "$out"; else echo "$fallback"; fi
}
```

---

## 6. Why the base stays on Ubuntu 24.04 LTS

The issue comment asks for the freshest OS too. Ubuntu 24.04 is kept
deliberately: it is the newest release for which **swift.org publishes a Linux
toolchain** — the release feed carries `ubuntu2404` (and `ubuntu2404-aarch64`)
builds and nothing newer, so a 26.04 base would drop Swift from the full box.
Everything installed *on top of* the base now tracks its own upstream, so the
base being one LTS cycle behind does not hold any runtime back. When Swift
publishes a newer Ubuntu build, moving the base is a one-directory change.

---

## 7. Only the pull request's latest commit runs

The maintainer's second comment on the issue asked for this directly: *"We must
fix our CI/CD, so previous commits skip execution in pull requests, if multiple
are committed in the order. So we only execute on last commit, and reduce
resource waste on all previous commits."*

### 7.1 The workflow already had `cancel-in-progress`, and it made things worse

`release.yml` declared the usual stanza, and every commit below carried an
identical copy of it:

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

Four consecutive pushes to this very pull request produced:

| run | commit | created | outcome |
|---|---|---|---|
| 33959630651 | 53c4258 | 10:03 | **still starting jobs at 10:29:39** (`pr-test / full`) |
| 33959814682 | 4f06a6c | 10:07 | `pending` → cancelled 10:12 |
| 33960020799 | 981b61e | 10:12 | `pending` → cancelled 10:15 |
| 33960152379 | f07e411 | 10:15 | `pending` |

The exact opposite of the requirement: the whole expensive matrix ran for the
*oldest* commit, twenty-two minutes after it had been superseded, while the
commit everyone was waiting for never started.

The mechanism is a deadlock inherent to the shared group. A newer run that lands
on an occupied concurrency group is `pending` — it holds no runner and executes
**no step**, so it cannot cancel its predecessor; it can only be cancelled by
the run after it. `cancel-in-progress` is evaluated by the platform, and here the
platform kept the in-progress run alive. A `pending` run cannot fix that from
the inside, because being `pending` is precisely the state of not running.

### 7.2 The fix: never let PR runs block each other, supersede explicitly

Pull-request runs now get a **unique** group, so they always start:

```yaml
group: ${{ github.event_name == 'pull_request'
          && format('{0}-pr-{1}-run-{2}', github.workflow, github.event.pull_request.number, github.run_id)
          || format('{0}-{1}', github.workflow, github.ref) }}
```

(Push/tag runs keep the per-ref group — releases must still serialise.)

Supersession is then done by a step that actually executes, `scripts/ci/supersede.sh`,
in two modes:

| Mode | Where it runs | What it does |
|---|---|---|
| `cancel-older` | the new `cancel-superseded` job — first job of the run, no `needs:` | Lists this workflow's `pull_request` runs on the PR's head branch and cancels every still-live one with a **lower run number** and a **different head SHA**. |
| `stop-if-superseded` | first step after checkout in all six expensive PR jobs | Re-reads the pull request's head SHA and cancels **its own run** if the commit has moved on. |
| `watch` | started in the background by that same step | Polls the head SHA every 5 minutes for the life of the job and cancels the run the moment it stops being current. |

All three are needed, because each covers a window the others cannot.

`cancel-older` catches the runs that already exist when a new commit lands, but
it needs a runner like any other job — and a superseded run is usually the
reason none is free. Measured while developing this: run 33962058501 sat
`queued` for **more than ten minutes** because its predecessor was holding
~25 job slots; its `cancel-superseded` job was queued behind the very jobs it
existed to stop, and only cancelled them at 11:05:39.

`stop-if-superseded` covers the opposite direction: a matrix job can sit queued
for half an hour before a runner frees up (`pr-test / full` above started 26
minutes after its run was created), so by the time it starts, its commit may be
long gone and no newer run has been able to reach it. It is the first step after
checkout, so the check is paid before any image is built.

`watch` covers the gap between those two — the job that was *already running*
when the new commit landed. It runs inside a job that already holds a runner, so
it never queues, and one cancelled run frees every slot that run was holding at
once. A poll every 5 minutes (`SUPERSEDE_WATCH_INTERVAL_SECONDS`) keeps the
whole ~28-job matrix well inside `GITHUB_TOKEN`'s REST budget while still
reclaiming most of a 40-minute build.

### 7.3 A graceful cancel is a request, not a guarantee

Measured on the first live run of the new job: it requested
`POST /actions/runs/33959630651/cancel` at 10:40:57, the API accepted it, and
that run's `pr-test / dind-full` still ran to a **green finish at 10:49:25**,
with `pr-test / full` building on past it. This is the same platform behaviour
that made `cancel-in-progress` a no-op above. `POST .../force-cancel` on the
identical run ended it within seconds.

So every cancel is verified: `ensure_cancelled()` polls the run's status and,
if it is still live after `SUPERSEDE_FORCE_AFTER_SECONDS` (45 s by default),
escalates to `force-cancel`. The grace period is what makes the polite request
worth trying first — a graceful cancel lets a job upload its logs.

### 7.4 Failing open is deliberate

Every lookup and every cancel that does not work — API error, unparseable
payload, or the read-only `GITHUB_TOKEN` a fork pull request gets, which cannot
cancel anything — logs a warning and lets CI continue. Losing a cancellation
wastes runner minutes; a false cancellation would silently lose test coverage on
a commit that is about to be merged.

### 7.5 Limits

A cancel is still asynchronous, so a superseded job can do a few more seconds of
work before the runner tears it down, and the `watch` cadence means up to five
minutes of a build can be spent on a commit that has just been superseded.
Fork pull requests get a read-only token and cannot cancel at all — they behave
exactly as they do today. Push and tag runs are untouched: they keep the per-ref
concurrency group, because releases must still serialise.

---

## 8. Tests

| Test | What it proves |
|---|---|
| `experiments/version-policy-unit-test.sh` — **69 assertions** | Every resolver against mocked feeds: override wins, feed is parsed correctly (LTS selection, Java LTS cadence, dotnet archive intersection, swift ordering), fallback on an unreachable feed, and `assert_single_runtime_versions` accepting one / rejecting two. Case 9 covers `add_cran_repo` end to end (success, idempotency, unsupported codename, key-download failure, offline degradation) and asserts no partial apt config is left behind. |
| `experiments/rust-refresh-layer-test.sh` — 7 assertions | Builds the three images above and asserts the single-layer variant is measurably smaller, i.e. that the fix had to be a layer change. |
| `experiments/node-lts-integration-test.sh` | Runs the real js install path in `ubuntu:24.04`: exactly one Node under `~/.nvm/versions/node`, the active Node is the resolved LTS, a **login shell** runs the same Node (the `nvm alias default` regression), and the assertion helper accepts the pruned tree and rejects a two-version one. |
| `pr-test / version-policy` (new CI job) | Runs the two experiment suites and then calls each resolver against the **live** upstream feeds, failing if any returns empty. It gates all three existing PR test tiers and the `docker-build-test` aggregator. |
| `pr-test / js` | On the built image: `node --version` matches the resolver's answer, `nvm version default` equals it, and there is exactly one Node in the image. |
| `pr-test / full` | The same Node check, plus `rustup toolchain list` has exactly one entry, `rustup check` reports no update available for the toolchain, and `assert_single_runtime_versions` passes inside the image. |
| `experiments/test-issue112-supersede.sh` — **69 assertions** | The supersession logic against a stubbed `gh api` (`SUPERSEDE_API`): which runs are selected and which are left alone (self, newer, completed, same commit, another fork), the force-cancel escalation when a run ignores the graceful cancel, the self-cancel when the PR head moved on, the background watcher (polling, cancelling, giving up at its ceiling, surviving a transient API failure), and failing open on every API error. It then reads `release.yml` back and asserts the wiring: the per-run PR concurrency group, the `cancel-superseded` job with no `needs:`, and — for all six expensive PR jobs — the guard, the watcher, the `actions: write` permission and the guard's position as the first step after checkout. Run by `pr-test / version-policy`. |

The Node assertions source `$HOME/.nvm/nvm.sh` explicitly rather than relying on
`bash -lc`: Ubuntu's `/etc/skel/.bashrc` returns early for non-interactive
shells, so `bash -lc 'node --version'` finds no node in `box-js`. The rustup
assertion filters `^rustup ` out of `rustup check`, which also reports updates
for the rustup binary itself and would otherwise fail spuriously.

---

## 9. Files changed

| File | Change |
|---|---|
| `ubuntu/24.04/common.sh` | The version resolvers, `apt_has_package`, `add_cran_repo`, `count_installed_versions`, `assert_single_runtime_versions`. |
| `ubuntu/24.04/js/install.sh` | Resolved Node LTS + nvm tag, `nvm alias default`, prune, assert. |
| `ubuntu/24.04/rust/install.sh` | Unconditional `rustup update stable`, prune, assert. |
| `ubuntu/24.04/full-box/refresh-rust.sh` | New: single-layer adopt + refresh + prune of the rust stage. |
| `Dockerfile`, `ubuntu/24.04/full-box/Dockerfile` | `# syntax=docker/dockerfile:1`; `RUN --mount=type=bind,from=rust-stage` replaces the `COPY`. |
| `java`, `kotlin`, `dotnet`, `php`, `swift`, `ruby`, `python`, `r`, `rocq` install scripts (+ `php/Dockerfile`) | Build-time versions, pruning, assertions. |
| `ubuntu/24.04/full-box/install.sh` | The same resolutions for the single-script path. |
| `scripts/ubuntu-24-server-install.sh`, `scripts/measure-disk-space.sh` | `common.sh` bridge + resolved versions. |
| `.github/workflows/release.yml` | `DOCKER_BUILDKIT=1`, new `pr-test / version-policy` tier, freshness assertions in the js and full smoke tests; per-run PR concurrency group, `cancel-superseded` job, and the superseded-commit guard plus background watcher in every expensive PR job (§7). |
| `scripts/ci/supersede.sh` | New: `cancel-older` / `stop-if-superseded` / `watch`, with verified (force-)cancellation. |
| `README.md`, `ARCHITECTURE.md` | Version claims replaced with the policy; new "Build-Time Version Resolution" design decision. |
| `experiments/…` | The three suites above + `experiments/layer-whiteout/`. |
