# Case Study: Issue #117 — A green release that reached nobody

## Executive Summary

Run 33972074755 built the whole matrix, published a GitHub Release, reported
success, and delivered nothing. Two releases went that way — 2.5.0 and 2.6.0 —
and the defect survived for months because every signal the repository produced
about it was, in its own terms, correct.

| # | Finding | Root cause | Resolution |
|---|---------|-----------|------------|
| 1 | Docker Hub has nothing newer than `2.4.0` (2026-06-21). | The `DOCKERHUB_TOKEN` secret expired. The login step is `continue-on-error: true` by design, so the run logged one warning, skipped all fourteen mirror steps, and stayed green. | `scripts/release/preflight-credentials.sh` proves the credential can **write** before anything is built, and fails the run on `main` when it cannot. |
| 2 | `konard/box:latest` still serves the pre-#112 June image (Node 20, the duplicated `~/.rustup`). | Consequence of #1: the fix shipped in 2.5.0, which never reached the mirror. | Same fix, plus a README that says which registry carries which version instead of implying both carry the newest. |
| 3 | The GHCR packages `box` and `box-dind` are private. The "registry of record" was pullable by nobody. | A GHCR package is created private on first push, and **no API exists to change that** — the packages REST API is `GET`/`DELETE`/restore only. Nothing noticed, because nothing ever asked anonymously. | The preflight asks anonymously and blocks the release; `docs/RELEASING.md` carries the manual runbook, because a manual step that is not written down is a manual step that does not happen. |
| 4 | The v2.6.0 notes say "28 of 56 image references resolve". Anonymously the number was **0 of 56**. | The check ran inside `create-release`, after `docker/login-action` had authenticated that job to ghcr.io. It measured the publisher's access and reported it as the reader's. | The generator holds no credential and probes over HTTP through `scripts/release/registry-probe.sh`; `scripts/release/check-publication.sh` re-asks after publication and fails the run when the answer is nobody. |
| 5 | `2.5.0` has no git tag and no GitHub Release; the tags run v2.4.0 → v2.6.0. | The version bump was committed and the release job never produced its output, with nothing asserting that a bumped version becomes a release. | The preflight gates the version bump itself, so a run that cannot publish does not leave a bumped `VERSION` behind with no release to match it. |

One sentence covers all five: **a check that runs as the one party guaranteed
to have access is not a check.** Every mechanism added here holds no
credential, or proves that the credential it holds actually works.

---

## 1. The thing that made this hard to see

Nothing in run 33972074755 was hidden. The Docker Hub login failure is in the
log:

```
##[warning]Docker Hub login failed (outcome=failure)
```

and every `Mirror … to Docker Hub` step is honestly marked `skipped`. The run
is `success` because each individual decision along the way was defensible:

- The login is `continue-on-error: true` so a mirror outage cannot fail a
  release — that is issue #115's principle #13, and it is right.
- The skipped steps are gated on the login's outcome — also right; running a
  push with a credential that just failed would only add noise.
- `create-release` does not require the image jobs, so a registry outage still
  produces the release and the notes — right again, and deliberately so.

The three correct decisions compose into a run that cannot fail for the one
reason that matters. That is the shape of this defect: not a bug in any step,
but the absence of anyone asking, at the end, *did this reach anyone?*

## 2. The maintainer's requirement

From the issue thread:

> at pull request we test how code works, and it is fine for CI/CD to be
> executed to test builds and so on. But in main branch our task is not to test
> the code, our task is produce release, so if any token or auth is not
> configured or unavailable (and we should be able to check it in advance),
> there is no need to do any resource intensive calculations for CI/CD […] we
> should fail immediately.

This is a different principle from #115's "never gate the release on an image
push", and the two only look like a contradiction. They are separated by
*when*:

- **Before any work**, on `main`: prove every planned target will accept a
  write. If one will not, stop — the compute cannot produce a release.
- **After the release exists**: never withhold the tag and the notes because a
  push failed. Report, warn, and let a human re-run the mirror.

The preflight runs at minute zero; `check-publication.sh` runs after the
release is published and only decides whether the *run* is green. Neither one
can withhold a GitHub Release.

## 3. Why "can you log in?" is not "can you publish?"

The obvious preflight is a `docker login`. It is not sufficient, and on GHCR it
is not even meaningful. Measured against the live registries on 2026-09-06:

| Request | ghcr.io | docker.io |
|---------|---------|-----------|
| Token for `scope=repository:<repo>:pull,push`, **any** credential | **HTTP 200**, body `{"token":"<base64 of the credential you sent>"}` | 200 for a valid credential, **401** for a wrong one |
| Same request, **no** credential | 403 | **HTTP 200**, with a pull-only `access` claim |
| Actual write (`POST /v2/<repo>/blobs/uploads/`) | 403 `permission_denied: The token provided does not match expected scopes` | the truth |

ghcr.io's token endpoint verifies nothing: it hands back your own credential,
base64-encoded, for any scope you ask for. A preflight that stopped at a 200
would have passed with a credential that could not write a byte. Docker Hub
fails the other way — it answers 200 to an *anonymous* push-scope request, with
the `access` claim quietly narrowed to pull.

So the probe opens a real blob upload session and immediately cancels it with
`DELETE` on the returned `Location`. Only an attempted write proves write
access. The evidence is in
[`dev/log/issues/117/pulls/118/token-endpoint-is-not-a-credential-check.log`](../../../dev/log/issues/117/pulls/118/token-endpoint-is-not-a-credential-check.log).

## 4. Telling "private" from "missing" without a credential

Finding #4's first fix attempt is a trap worth naming: log in, so that
`docker manifest inspect` can tell a private package from an absent one. That
is exactly what `create-release` was already doing, and it is what made "28 of
56" a false statement about a release where the honest number was 0.

The distinction can be made anonymously, because GHCR draws it at the *token*
step rather than the manifest step:

| State | Anonymous token request | Anonymous manifest GET |
|-------|------------------------|------------------------|
| Published | 200 | 200 |
| Private | **401** | (never reached) |
| Missing | 200 | **404** |
| Rate limited | 200 | **429** → reported as `unknown`, never as missing |

`registry_probe_pull` reads that sequence, so the four states stay distinct with
no credential anywhere. Running the generator against the real v2.6.0
reproduces the issue's claim exactly:

```
Checked anonymously […]: 0 of 56 image references can be pulled without credentials.

| Registry                                      | Pullable | Checked |
| GitHub Container Registry (registry of record) | 0        | 28      |
| Docker Hub (mirror)                            | 0        | 28      |
```

with all 28 GHCR references listed as private and all 28 Docker Hub references
as missing —
[`dev/log/issues/117/pulls/118/release-notes-v2.6.0-anonymous.md`](../../../dev/log/issues/117/pulls/118/release-notes-v2.6.0-anonymous.md).
The same shape, run through the post-publish gate, exits 1:
[`check-publication-v2.6.0.log`](../../../dev/log/issues/117/pulls/118/check-publication-v2.6.0.log).

`private` had to become a state of its own. Calling a private package
"missing" would be the same class of false claim in the other direction, and it
sends an operator looking for a build failure that never happened. The two have
different fixes — one is a re-run, the other is a visibility setting no API can
change.

## 5. Trusted publishing

The maintainer's request was to prefer trusted publishing "where no regular
tokens update is necessary". A stored token is a secret that must be rotated by
a human who will not be reminded until a release has already failed — which is
finding #1, stated as a property of the mechanism rather than of this incident.

`.github/actions/dockerhub-login` prefers OIDC whenever
`DOCKERHUB_OIDC_CONNECTIONID` is set: `docker/login-action` takes the
organization name as `username`, no `password` at all, and the runner mints a
short-lived token per job. The token path remains as a fallback, because Docker
Hub OIDC connections are an **organization** feature and `konard/box` is a
personal namespace. The images have to move before this repository can turn the
secret off; until then the preflight is what converts an expiry into an
immediate, explanatory failure.

One trap the action closes: a job that sets `DOCKERHUB_OIDC_CONNECTIONID`
without granting `permissions: id-token: write` cannot mint a token, and a
called workflow's permissions are capped by its caller's, so this is easy to
half-wire. The action checks `ACTIONS_ID_TOKEN_REQUEST_URL` — which the runner
injects only when the permission was granted — and fails with an explanation
instead of attempting a login that cannot succeed.

## 6. What now fails that used to pass

| Gate | Fails when | Where |
|------|-----------|-------|
| Release preflight | any required registry credential cannot write, or a GHCR package is private (`ALLOW_PRIVATE_GHCR=1` downgrades) | before every job on `main`; `--mode report` on pull requests |
| Publication check | after publishing, no sampled reference on the registry of record pulls anonymously | last step of `create-release` |
| `test-issue117-preflight.sh` | 31 assertions, offline | `scripts/ci/run-experiments.sh` |
| `test-issue117-preflight-gating.sh` | 46 assertions: every expensive job needs the preflight; every Docker Hub login goes through the shared action | same |
| `test-issue117-check-publication.sh` | 16 assertions, including that the script reads no credential of any kind | same |
| `test-issue115-release-notes.sh` | 36 assertions, ported to a stub probe, with the v2.6.0 shape pinned | same |

### What the first live run reported

The preflight ran on this pull request in `--mode report`
([run 34053764507](https://github.com/link-foundation/box/actions/runs/34053764507),
transcript in
[`dev/log/issues/117/pulls/118/preflight-report-mode-run-34053764507.log`](../../../dev/log/issues/117/pulls/118/preflight-report-mode-run-34053764507.log)),
against the repository's real secrets, and moved two of the issue's five
findings:

```
==> GHCR: OK - ghcr.io/link-foundation/box accepted a blob upload session (HTTP 202)
==> Docker Hub: OK - docker.io/<account>/box accepted a blob upload session (HTTP 202)

| GHCR visibility | ghcr.io/link-foundation/box:latest      | private | HTTP 401 |
| GHCR visibility | ghcr.io/link-foundation/box-dind:latest | private | HTTP 401 |
```

The Docker Hub credential **works today** — the expired token from run
33972074755 has been replaced — so finding #1 is now a missing release run
rather than a missing credential. The private packages of finding #3 are
confirmed by the pipeline itself rather than by an outside probe. Neither fact
was available from any run before this one: the old pipeline could report
`success` in both states and did.

The preflight will **block releases on `main` until the GHCR packages are made
public**, which is a manual step: see
[`docs/RELEASING.md`](../../RELEASING.md). That is the intended behaviour, not
an oversight — publishing more versions of a package nobody can pull is
precisely the compute the maintainer's principle says not to spend.

## 7. The principle, stated for reuse

Proposed for `docs/CI-CD-BEST-PRACTICES.md` in link-assistant/hive-mind:

> **On a release branch, verify every publishing credential before doing any
> work, and verify the published result as an outsider afterwards.**
>
> On a pull request the job is to test the code, so missing credentials are
> reported and the build proceeds. On the release branch the job is to produce
> a release: if any credential needed to produce *all* planned artifacts is
> missing, expired, or unauthorized, fail in the first minute rather than
> spending the matrix to arrive at the same place. "Can I log in?" is not the
> question — ask for the write, on a request that can be cancelled.
>
> And when publishing is done, check the result **without the publisher's
> credentials**. A check that runs as the one party guaranteed to have access
> cannot fail, and reports its own access as everyone's.
>
> Prefer trusted publishing (OIDC). A stored token is a secret that must be
> rotated by a human who will not be reminded until a release has already
> failed.

## 8. Reported upstream

The principle above was filed as
[link-assistant/hive-mind#2221](https://github.com/link-assistant/hive-mind/issues/2221),
drafted as principle #16 of its `docs/CI-CD-BEST-PRACTICES.md` (which ends at
#15), together with hive-mind's own instance of the defect.

All seven `link-foundation/*-ai-driven-development-pipeline-template`
repositories were then read for the same defect. Four have it and were filed
against; three publish with `GITHUB_TOKEN` alone, which is minted per run and
cannot expire, so filing against them would have been a false positive:

| Template | Report | The credential that can expire |
| --- | --- | --- |
| js | [#176](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/176) | `DOCKERHUB_TOKEN`, first used after the npm publish |
| rust | [#163](https://github.com/link-foundation/rust-ai-driven-development-pipeline-template/issues/163) | `CARGO_REGISTRY_TOKEN`, `DOCKERHUB_TOKEN`, both after the full build matrix |
| python | [#74](https://github.com/link-foundation/python-ai-driven-development-pipeline-template/issues/74) | `DOCKERHUB_TOKEN`; when it is absent the run is green and publishes no image |
| csharp | [#51](https://github.com/link-foundation/csharp-ai-driven-development-pipeline-template/issues/51) | `NUGET_API_KEY`; a `Validate NuGet API key` step tests `-z` and prints the length |
| go, java, php | *not filed* | none — `GITHUB_TOKEN` only |

The evidence behind each decision, including the three not filed, is in
[`dev/log/issues/117/pulls/118/UPSTREAM-REPORTS.md`](../../../dev/log/issues/117/pulls/118/UPSTREAM-REPORTS.md).
