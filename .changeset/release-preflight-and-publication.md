---
bump: minor
---

Fail before the compute when a release cannot be published, and check the published result as an outsider (issue #117).

Run 33972074755 built the whole matrix, published a GitHub Release, reported
`success`, and delivered nothing. Two releases went that way — 2.5.0 and 2.6.0.
One sentence covers all five findings in the issue: **a check that runs as the
one party guaranteed to have access is not a check.** Every mechanism added here
either holds no credential, or proves that the credential it holds actually
works.

### Fail immediately, before anything expensive

The maintainer's requirement, from the issue thread: on a pull request the job
is to test the code, so a missing credential is reported and the build proceeds;
on `main` the job is to produce a release, so a credential that cannot publish
means there is no reason to spend a single minute of the matrix.

`scripts/release/preflight-credentials.sh` runs first, and every expensive job —
`js`, `essentials`, `languages`, `full`, `dind`, `create-release`, and the
version bump itself — now needs it. On a pull request it runs in `--mode report`
and never fails, because a fork has no secrets and must still be able to build.

**"Can you log in?" is not the question.** Measured against the live registries:
ghcr.io's token endpoint returns HTTP 200 with `{"token":"<base64 of the
credential you sent>"}` for *any* scope and verifies nothing — the write then
fails 403 `permission_denied` — while docker.io answers 200 to an *anonymous*
push-scope request with the `access` claim quietly narrowed to pull. So the
probe opens a real blob upload session and cancels it with `DELETE` on the
returned `Location`. Only an attempted write proves write access.

This gate **will block releases on `main` until the GHCR packages are made
public**, which is a manual step — there is no API for package visibility, the
packages REST API being `GET`/`DELETE`/restore only. `docs/RELEASING.md` is the
runbook, and the repository variable `ALLOW_PRIVATE_GHCR=1` downgrades it to a
warning. Blocking is the intent: publishing more versions of a package nobody
can pull is exactly the compute the principle above says not to spend.

### The release notes told the publisher's story, not the reader's

The v2.6.0 notes say "28 of 56 image references resolve with `docker manifest
inspect`". That check ran inside `create-release`, immediately after
`docker/login-action` had authenticated the job to ghcr.io. Anonymously the
number was **0 of 56**: both GHCR packages private, Docker Hub empty behind the
expired token — and the notes then linked Docker Hub tags that do not exist.

`create-release` now holds no registry credential at all, and the generator
probes over HTTP through `scripts/release/registry-probe.sh`, which makes the
distinction the login was there to make without needing one: on GHCR a private
package refuses the anonymous *token* request with 401, while a missing one
still issues a token and answers 404 on the manifest. `private` is a state of
its own — an image that exists and cannot be pulled is not published, and
calling it "missing" would be the same false claim in the other direction, with
a different fix. Counts are reported per registry, because "28 of 56" also hid
*which* half was gone, and Quick Start now leads with GHCR, the registry of
record.

`scripts/release/check-publication.sh` asks again after the release is
published, and fails the run when no reference on the registry of record pulls
anonymously. It runs *after* publication on purpose: issue #115's principle #13
still holds, the GitHub Release is never withheld because a push failed, and
what this decides is whether the run may be green. A lagging Docker Hub mirror
stays a warning; GHCR carrying nothing is an error.

### Trusted publishing

A stored token is a secret that must be rotated by a human who will not be
reminded until a release has already failed — finding #1 restated as a property
of the mechanism. `.github/actions/dockerhub-login` is now the single Docker Hub
login for the repository and prefers OIDC whenever
`DOCKERHUB_OIDC_CONNECTIONID` is set: organization name as `username`, no
password, a short-lived token minted per job. The token path stays as a
fallback, because Docker Hub OIDC connections are an organization feature and
`konard/box` is a personal namespace. A job that sets the connection id without
granting `permissions: id-token: write` fails with an explanation instead of
falling through to a login that cannot work — checked via
`ACTIONS_ID_TOKEN_REQUEST_URL`, which the runner injects only when the
permission was granted.

### Evidence and tests

Running the new generator against the real v2.6.0 reproduces the issue's claim
exactly — 0 of 56, 28 GHCR private, 28 Docker Hub missing — and the
post-publish gate exits 1 on it. Both transcripts are in
`dev/log/issues/117/pulls/118/`, alongside the registry measurements that show
why a token endpoint's 200 means nothing. `docs/case-studies/issue-117/` has the
full analysis, including why three individually correct decisions compose into a
run that cannot fail for the one reason that matters.

129 offline assertions across four suites: `test-issue117-preflight.sh` (31),
`test-issue117-preflight-gating.sh` (46), `test-issue117-check-publication.sh`
(16), and `test-issue115-release-notes.sh` (36, ported to a stub probe with the
v2.6.0 shape pinned).

### Still outstanding, and not fixable from a pull request

`2.5.0` has no git tag and no GitHub Release. Docker Hub carries nothing newer
than `2.4.0`, so `konard/box:latest` is still the pre-#112 June image; the
README says so now rather than implying both registries carry the newest build.
Restoring either one needs a credential rotation and a package visibility
change, both documented in `docs/RELEASING.md`.
