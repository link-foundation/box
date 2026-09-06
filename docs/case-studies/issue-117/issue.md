# Issue #117: 2.5.0 and 2.6.0 published no pullable image: Docker Hub push skipped on an expired token, GHCR packages are private, and `latest` still serves the pre-#112 image

https://github.com/link-foundation/box/issues/117

## Summary

The **content** of the #112 fix is delivered and verified — I can see it in box's own release CI. What is not delivered is a **base image anyone can pull**: neither `2.5.0` nor `2.6.0` exists on Docker Hub, and the GHCR packages that did receive them are **not public**. So today there is no registry from which a downstream can obtain a Box image that contains the #112 fix, and `konard/box:latest` — what the README tells people to pull — is still the June image with Node 20 and the duplicated `~/.rustup`.

This blocks link-assistant/hive-mind#2187, which is the downstream side of #112: its `FROM konard/box:2.4.0` / `FROM konard/box-dind:2.4.0` pins cannot move forward, so the workaround (installing a current Node.js/Bun in the hive-mind layer) has to stay.

## What is delivered

Release run [`34011750193`](https://github.com/link-foundation/box/actions/runs/34011750193), job `full / docker-build-push`, prints exactly what #112 asked for:

```
image ships Node v24.20.0, expected major 24
[✓] node: 1 version (v24.20.0)
[✓] rust: 1 version (stable-x86_64-unknown-linux-gnu)
[✓] python: 1 version (3.14.7)
[✓] ruby: 1 version (4.0.6)
[✓] lean: 1 version (leanprover--lean4---v4.33.1)
[✓] sdkman/java: 1 version (25-tem)
[✓] sdkman/kotlin: 1 version (2.4.10)
```

The image that was built is correct. Nothing below disputes the fix itself.

## What is missing

### 1. Docker Hub has nothing newer than `2.4.0` (2026-06-21)

```
$ docker manifest inspect konard/box:2.6.0
no such manifest: docker.io/konard/box:2.6.0
$ docker manifest inspect konard/box-dind:2.6.0
no such manifest: docker.io/konard/box-dind:2.6.0
$ docker manifest inspect konard/box:2.5.0
no such manifest: docker.io/konard/box:2.5.0
$ docker manifest inspect konard/box:2.4.0
{ … resolves … }
```

Newest tag in `hub.docker.com/v2/repositories/konard/box/tags` is `2.4.0`, `last_updated 2026-06-21T18:02:48Z`; same for `konard/box-dind`.

Cause, from the release run's own log (`js / build-js-amd64`, 2026-09-06T04:34:57Z):

```
##[warning]Docker Hub login failed (outcome=failure). The DOCKERHUB_TOKEN repository secret is
most likely expired or revoked. … The job will continue and push to GHCR; guarded Docker Hub
publish steps will be skipped …
```

Every `Mirror … to Docker Hub` step in that run is `skipped`, and the run is `success`. This is the maintainer action #116 flagged (`rotate DOCKERHUB_TOKEN`) — reporting it here because until it happens, **the fix is unreachable**, not merely un-mirrored.

### 2. `konard/box:latest` still serves the pre-fix image

The tag the README's `docker pull konard/box:latest` resolves to has `created: 2026-06-21T17:42:59Z`, and its history still contains the pre-fix rustup path:

```
COPY --chown=box:box /home/box/.rustup /home/box/.rustup # buildkit
```

which is precisely the `COPY --from=rust-stage` mechanism that #112 identified as the cause of the stale `stable` toolchain, and which `full-box/refresh-rust.sh` replaced. Anyone following the README today still gets Node 20 and 2.2 GB of `~/.rustup` — the closed issue's exact symptoms.

### 3. GHCR — the registry of record — is not publicly pullable

A **public** GHCR package issues an anonymous pull token; a private one does not:

```
$ curl -s "https://ghcr.io/token?scope=repository%3Aastral-sh%2Fuv%3Apull&service=ghcr.io"
{"token":"djE6YXN0cmFsLXNoL3V2Oj…"}                       # control: public

$ curl -s "https://ghcr.io/token?scope=repository%3Alink-foundation%2Fbox%3Apull&service=ghcr.io"
{"errors":[{"code":"UNAUTHORIZED","message":"authentication required"}]}
$ curl -s "https://ghcr.io/token?scope=repository%3Alink-foundation%2Fbox-dind%3Apull&service=ghcr.io"
{"errors":[{"code":"UNAUTHORIZED","message":"authentication required"}]}

$ curl -s -o /dev/null -w '%{http_code}\n' https://ghcr.io/v2/link-foundation/box-dind/manifests/2.6.0
401
```

`docker manifest inspect ghcr.io/link-foundation/box-dind:2.6.0` is `denied` even when logged in with a GitHub token that has no `read:packages` scope. GHCR packages default to private on first publish; the release never makes them public, and nothing checks.

Reproduce all of the above with one script (read-only, pulls nothing): [`experiments/issue-2187-box-base-availability.sh`](https://github.com/link-assistant/hive-mind/blob/issue-2187-6617b8797683/experiments/issue-2187-box-base-availability.sh) in the hive-mind branch.

```
Docker Hub (what hive-mind's Dockerfiles pin):
  PULLABLE   konard/box:2.4.0
  PULLABLE   konard/box-dind:2.4.0
  MISSING    konard/box:2.5.0  (no such manifest: docker.io/konard/box:2.5.0)
  MISSING    konard/box-dind:2.5.0
  MISSING    konard/box:2.6.0
  MISSING    konard/box-dind:2.6.0
  PULLABLE   konard/box:latest        <- still the 2026-06-21 pre-fix image
GHCR (box's registry of record since #115):
  NOT PUBLIC ghcr.io/link-foundation/box
  NOT PUBLIC ghcr.io/link-foundation/box-dind
  control (a known-public package):
  PUBLIC     ghcr.io/astral-sh/uv
```

### 4. The publication check cannot tell "published" from "visible to the job that published it"

The release notes for [v2.6.0](https://github.com/link-foundation/box/releases/tag/v2.6.0) say:

> 28 of 56 image references resolve with `docker manifest inspect`.

That verification runs inside `create-release` **after** `docker/login-action` has authenticated to `ghcr.io` with `GITHUB_TOKEN` (log lines `Logging into ghcr.io… Login Succeeded!`, then `VERIFY_IMAGES: 1`). So the 28 that "resolve" resolve *for the publishing job*, not for a user. An anonymous check would have reported **0 of 56**.

This is the same family as the false positives #115 was about — a check that cannot distinguish "I looked and it is there" from "I looked with credentials nobody else has". The release is `success`, the notes then render full Docker Hub tables of tags that do not exist (the unpublished list is above them, but the tables link to `hub.docker.com/r/konard/box/tags?name=2.6.0`, which is empty).

### 5. `2.5.0` has no tag and no release

`git ls-remote --tags` shows `v2.4.0` then `v2.6.0`. Commit `7ac36f4` ("2.5.0: Resolve every runtime version at build time…") is on `main`, but its release run on `42be663` failed, so the version that actually fixes #112 exists only as a `VERSION` bump that was overwritten. Not harmful by itself — noting it so the changelog/tag history is not read as "2.5.0 shipped".

## Suggested fixes

1. **Rotate `DOCKERHUB_TOKEN` and re-run the release for `2.6.0`** (or cut `2.6.1`), so `konard/box:2.6.0` / `konard/box-dind:2.6.0` and a refreshed `latest` exist. Everything else in this report is secondary to this.
2. **Make the GHCR packages public** (and link them to the repository), so the registry of record is a real fallback when the mirror credential lapses. A one-off `gh api -X PATCH /orgs/link-foundation/packages/container/<name> -f visibility=public` per package, plus a release-time assertion that the package is public.
3. **Verify publication the way a consumer sees it**: run the `VERIFY_IMAGES` pass with a logged-out docker config (or a plain unauthenticated registry `HEAD`), and fail — or at minimum mark the release as failed-to-publish — when the count for the primary registry is 0. Rendering a Docker Hub table for tags the same job just reported as unpublished is the concrete symptom.
4. **Keep `latest` honest**: if a release cannot publish, `latest` continues to advertise a superseded image with the exact defect a closed issue claims to have fixed. Either the release fails, or `README`/release notes state which tag actually carries the fix.

## Downstream status

link-assistant/hive-mind#2187 / [PR #2204](https://github.com/link-assistant/hive-mind/pull/2204) keeps `FROM konard/box:2.4.0` / `konard/box-dind:2.4.0` and installs a pinned current Node.js (24.20.0) and Bun in its own layer, pruning the superseded nvm version. That workaround stays until a Box image carrying the #112 fix is pullable; the byte cost in the base layer (`~/.rustup` duplication) cannot be reclaimed downstream at all, since a `rm -rf` in a derived layer only writes a whiteout.



---

## Comment by konard (2026-09-06T17:57:59Z)

So we have false positive here, and all our CI/CD must be fixed here, and we should check access to docker hub early. At pull request we test how code works, and it is fine for CI/CD to be executed to test builds and so on. But in main branch our task is not to test the code, our task is produce release, so if any token or auth is not configured or unavailable (and we should be able to check it in advance), there is no need to do any resource intensive calculations for CI/CD, so no checks needs to be executed at all if there is no way to produce all planned releases, so if we have missing any credentials needed to produce any of releases, we should fail immediately. 

And that should be separate key principle at https://github.com/link-assistant/hive-mind/blob/main/docs/CI-CD-BEST-PRACTICES.md, and if any template has the same issue, we should also report issues there.

For adding such principle in best practices we should also create issue in https://github.com/link-assistant/hive-mind so it will update its CI/CD as well as docs.

Also we should prefer trusted publishing, where no regular tokens update is necessary if possible. Because that reduce the risk to not have token or credentials to publish in the first place.
