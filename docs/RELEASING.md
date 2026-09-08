# Releasing

This is the runbook the release workflow's error annotations point at. It
covers the two things a release needs that no script can do for itself:
credentials that work, and packages a reader is allowed to pull.

## The principle this file exists to enforce

> On `main` the job is not to test the code, it is to produce a release. If any
> credential needed to produce **all** planned releases is missing or
> unavailable — and we can check that in advance — then there is no reason to
> spend a single minute of compute. Fail immediately.

Issue #117 is what that principle costs when it is absent. Run 33972074755
built and tested every image in the matrix, logged one
`##[warning]Docker Hub login failed (outcome=failure)`, skipped all fourteen
mirror steps, and finished **green**. Two releases (2.5.0, 2.6.0) went nowhere
and nobody found out for months.

`scripts/release/preflight-credentials.sh` runs first, before any build, and on
`main` it exits non-zero when a target cannot be written. On a pull request it
runs in `--mode report`: a fork has no secrets and must still be able to build.

## What a release needs

| Target | Credential | Can it expire? |
|--------|-----------|----------------|
| `ghcr.io/link-foundation/box*` (registry of record) | the run's own `GITHUB_TOKEN`, with `permissions: packages: write` | No. It is minted per run. |
| `konard/box*` on Docker Hub (mirror) | `DOCKERHUB_OIDC_CONNECTIONID` (preferred) or the `DOCKERHUB_TOKEN` secret | The token, yes — and it did. |

GHCR is the registry of record precisely because its credential cannot expire
(issue #115, RC-3). Docker Hub is a mirror: it may lag, and a lagging mirror is
a warning. GHCR carrying nothing is an error.

## Trusted publishing to Docker Hub (preferred)

A stored access token is a secret that has to be rotated by a human who will
not be reminded until a release has already failed. OIDC removes it: the runner
mints a short-lived token per job, and there is nothing to expire.

Setup, once:

1. In Docker Hub, under the **organization**'s settings, create an OIDC
   connection trusting `https://token.actions.githubusercontent.com` and
   restrict it to this repository.
2. Add two repository **variables** (not secrets — neither value is sensitive):
   - `DOCKERHUB_OIDC_CONNECTIONID` — the connection id Docker Hub shows.
   - `DOCKERHUB_ORGANIZATION` — the organization name, which
     `docker/login-action` takes as its `username` in OIDC mode.
3. Delete the `DOCKERHUB_TOKEN` secret. `.github/actions/dockerhub-login`
   prefers OIDC whenever `DOCKERHUB_OIDC_CONNECTIONID` is set and only falls
   back to the token when it is not, so leaving both configured just keeps a
   secret alive that nothing uses.

Known limitation: Docker Hub OIDC connections are an **organization** feature.
`konard/box` is a personal namespace, so this repository cannot enable it until
the images move to an organization. Until then the token path stays, and the
preflight is what turns its expiry into an immediate, explanatory failure
instead of fourteen skipped steps under a green check.

Every job that logs in with OIDC must grant `permissions: id-token: write`, and
for a called workflow the **caller** job must grant it too — a called workflow's
permissions are capped by its caller's. The action refuses to try when
`ACTIONS_ID_TOKEN_REQUEST_URL` is absent, which is the runner's own evidence
that the permission was not granted; a half-wired OIDC setup fails loudly
rather than falling through to a login that cannot work.

## Rotating `DOCKERHUB_TOKEN` (while the token path is in use)

1. Create a new access token with **Read & Write** scope: sign in to Docker Hub
   and open *Account settings -> Personal access tokens -> Generate new token*
   (the direct URL is behind the login wall, so it is not linked here; see
   [Docker's access token documentation](https://docs.docker.com/security/for-developers/access-tokens/)).
2. Update the `DOCKERHUB_TOKEN` secret under
   *Settings → Secrets and variables → Actions*.
3. Re-run the release workflow. The preflight step at the top of the run either
   confirms the credential can write or fails within a minute, before anything
   is built.

Docker Hub access tokens expire. Nothing in GitHub Actions warns you when one
does; the login step reports `outcome=failure` and, before this change,
everything downstream carried on.

## Making the GHCR packages public

**A private package is not a published image.** A GHCR package is created
private on its first push, and there is no API for changing that: the packages
REST API is `GET`/`DELETE`/restore only. It is a manual step, once per package.

For each `box*` package:

1. Open <https://github.com/orgs/link-foundation/packages>.
2. Select the package → **Package settings**.
3. **Danger Zone → Change visibility → Public**.
4. While you are there, check **Manage Actions access** lists this repository
   with the *Write* role, so the release workflow can push to it.

The packages, all of which need this: `box`, `box-essentials`, `box-js`, and
`box-<language>` for each of python, go, rust, java, kotlin, ruby, php, perl,
swift, lean, rocq — plus a `-dind` variant of every one of those.

Verify from outside, holding no credential at all:

```sh
VERSION=2.7.0 \
GHCR_IMAGE=ghcr.io/link-foundation/box \
DOCKERHUB_IMAGE=konard/box \
  bash scripts/release/check-publication.sh
```

Exit 0 means a reader can pull the release. Exit 1 says which of the ways of
reaching nobody happened: nothing was pushed, what was pushed is private, or
what was pushed resolves and does not carry the architectures the release built
(issue #119). The same script runs at the end of every release, after the
GitHub Release has been created, so a release that reaches nobody turns the run
red instead of being reported as a success.

Until the visibility is flipped, the preflight blocks releases on `main` with
`::error title=GHCR package is private::`. That is deliberate: publishing more
versions of a package nobody can pull is exactly the compute the principle at
the top of this file says not to spend. To release anyway — knowing the result
is unreachable — set the repository variable `ALLOW_PRIVATE_GHCR=1`, which
downgrades it to a warning.

## Architectures, and the tag a user actually pulls

A tag that resolves is not a tag that was published: `konard/box:2.7.0`
answered HTTP 200 while serving linux/amd64 alone, and an arm64 reader got
`no matching manifest for linux/arm64`. Three things now hold that shut, and
they are worth knowing about before changing a release workflow.

- **`EXPECTED_PLATFORMS`** (default `linux/amd64 linux/arm64`) is what every
  checked reference must carry. On the registry of record a reference that
  carries less fails the run; on Docker Hub a *missing* tag stays a warning
  because a mirror may lag, but a tag that resolves with the wrong
  architectures is an error — somebody pulling it today gets the wrong answer
  today. Setting it empty disables the coverage check entirely.
- **`PREVIOUS_VERSION`** adds the comparison a constant cannot make: a tag that
  was multi-arch in the previous release and is single-arch now is a
  regression, whatever `EXPECTED_PLATFORMS` says. The release workflow fills it
  from `gh release list`; the baseline only counts when the previous release's
  reference is itself published.
- **Only a manifest step may write a tag without an architecture suffix.** An
  architecture-specific job that pushes `:latest` publishes a tag that is true
  of one platform — which is exactly how `konard/box:latest` lost arm64 in
  2.7.0. `experiments/test-issue119-tag-policy.sh` reads every image reference
  out of the release workflows and fails if a job named for one architecture
  names a bare tag.

An unreadable platform list is neither of these: it means "I could not look",
and it is reported as a warning, never as a missing architecture.

## Checking a release by hand

Everything below runs anonymously, which is the only view that decides whether
a release happened.

```sh
# What can a reader pull, per registry?
VERIFY_IMAGES=1 VERSION=2.7.0 REPO=link-foundation/box \
GHCR_IMAGE=ghcr.io/link-foundation/box DOCKERHUB_IMAGE=konard/box \
  bash scripts/release/build-release-notes.sh

# Will the credentials in this environment actually write?
GHCR_IMAGE_NAME=link-foundation/box GHCR_USERNAME="$USER" \
GITHUB_TOKEN="$(gh auth token)" DOCKERHUB_IMAGE_NAME=konard/box \
  bash scripts/release/preflight-credentials.sh --mode report
```

`--mode report` never fails the shell; it prints what it found and what it could
not check. It also refuses to claim it verified anything when every credential
in the environment was absent, which is the difference between "I looked and
found nothing wrong" and "I could not look".

## Known gaps in the published history

Measured anonymously on 2026-09-08; reproduce with the commands above.

- **2.5.0 has no git tag and no GitHub Release.** The version bump was
  committed, the release was not produced, and the tags run v2.4.0 -> v2.6.0.
- **GHCR is correct and complete for 2.7.0.** All 28 packages serve `2.7.0` and
  `latest` anonymously, with both architectures. The private-package blocker
  recorded here for 2.6.0 has been cleared.
- **Docker Hub carries 2.7.0 for `konard/box` only, and only for amd64.** The
  same run overwrote `konard/box:latest` with that amd64-only index, so it does
  not run on arm64; every other `konard/...:latest` is the older multi-arch
  image. `konard/box-dind:2.7.0` and the rest of the `2.7.0` mirror tags are
  absent. Issue #119 explains why the manifest step could not have worked, and
  the fix ships in the next release; nothing in this repository rewrites a tag
  that is already published.
- **`konard/box:latest` and `konard/box:2.7.0` are the same digest**
  (`sha256:9ac67276...`), which is how the regression is visible from outside:
  the amd64-only 2.7.0 index replaced a `latest` that used to serve both
  architectures. Prefer `ghcr.io/link-foundation/box:latest` until a release
  runs with the #119 fix.
