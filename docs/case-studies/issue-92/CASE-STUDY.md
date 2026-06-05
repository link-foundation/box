# Issue 92 Case Study: CI/CD is broken

Issue: https://github.com/link-foundation/box/issues/92

Pull request: https://github.com/link-foundation/box/pull/93

Analysis date: 2026-06-04 UTC

## Scope

Issue 92 asked for a full CI/CD investigation, not only a patch for one failed
job. The requested scope was:

- Investigate the linked main-branch failure:
  https://github.com/link-foundation/box/actions/runs/26983601067/job/79634413995
- Re-check PR 89 and PR 91 runs for false positives and hidden failures.
- Download logs and data into `docs/case-studies/issue-92`.
- Compare this repository with the link-foundation CI/CD templates.
- Search online for relevant facts and existing mechanisms.
- Identify root causes, solution plans, and whether related template issues
  should be opened.
- Apply the fix across the codebase where the same pattern exists.

## Archived Evidence

Raw artifacts kept for repeatable review:

- `raw/run-26962712292-metadata.json`: PR 89 validation run metadata.
- `raw/run-26966607948.log`: main release run after PR 89.
- `raw/run-26966607948-error-index.txt`: error lines for the PR 89 follow-up run.
- `raw/run-26966607948-dockerhub-error-excerpt.txt`: Docker Hub manifest failure excerpt.
- `raw/run-26966607948-metadata.json`: metadata for the PR 89 follow-up run.
- `raw/run-26980259791-metadata.json`: PR 91 validation run metadata.
- `raw/run-26983601067.log`: main release run after PR 91.
- `raw/run-26983601067-error-index.txt`: error lines for the PR 91 follow-up run.
- `raw/run-26983601067-apt-error-excerpt.txt`: apt mirror-sync failure excerpt.
- `raw/run-26983601067-python-dind-index.txt`: focused python dind job index.
- `raw/run-26983601067-metadata.json`: metadata for the linked failure.
- `raw/template-comparison.tsv`: template comparison summary.

GitHub refused to stream complete logs for the successful PR validation runs
without narrowing to individual jobs because those runs would require too many
API requests. Their metadata was still archived and the failure analysis used
the complete logs from the failed main-branch runs.

## Timeline

| Time (UTC) | Event | Evidence |
| --- | --- | --- |
| 2026-06-04T15:44:55Z | PR 89 validation run `26962712292` started on head SHA `55a9a90b65c77025545043df2a30374b0f49dd2c` and concluded `success`. | `raw/run-26962712292-metadata.json` |
| 2026-06-04T16:56:20Z | PR 89 (`fix(dind): default exec sessions to box user`) merged into `main`. | `gh pr view 89` |
| 2026-06-04T16:56:26Z | Main release run `26966607948` started on merge SHA `cb1f4c9ef1dd01c615db680f0ac9876c1bc4296c` and later failed. | `raw/run-26966607948-metadata.json` |
| 2026-06-04T18:06:10Z | Docker Hub login timed out in `dind-manifest (perl)`. | `raw/run-26966607948-dockerhub-error-excerpt.txt` |
| 2026-06-04T18:06:33Z | The same job still executed Docker Hub manifest commands and failed after GHCR manifest publishing had already succeeded. | `raw/run-26966607948-error-index.txt` |
| 2026-06-04T21:19:27Z | PR 91 validation run `26980259791` started on head SHA `d95a221ceb00d4b255b26c092191d549bcaa1c91` and concluded `success`. | `raw/run-26980259791-metadata.json` |
| 2026-06-04T22:33:27Z | PR 91 (`fix(ci): guard Docker Hub manifest publishing`) merged into `main`. | `gh pr view 91` |
| 2026-06-04T22:33:30Z | Main release run `26983601067` started on merge SHA `38fee23d627cb68ecbe1611e88dfb55fe118e601` and later failed. | `raw/run-26983601067-metadata.json` |
| 2026-06-04T23:26:55Z | `build-dind-amd64 (python)` hit Ubuntu mirror metadata mismatch during `apt-get update`. | `raw/run-26983601067-apt-error-excerpt.txt` |
| 2026-06-04T23:27:38Z | The buildx retry path failed for the same apt metadata mismatch and the run concluded failure. | `raw/run-26983601067-error-index.txt` |

## Root Causes

### 1. PR 89 post-merge failure: Docker Hub manifest path was not fully guarded

The PR 89 validation run passed, but the main release run failed in a
main-only manifest publication path. Docker Hub login timed out, the job logged
a warning, then still tried to create/push Docker Hub manifests. GHCR manifests
had already succeeded, so a Docker Hub transient failure caused the whole release
run to fail after partial publication.

PR 91 already fixed this in the current workflow by separating GHCR and Docker
Hub manifest steps and guarding Docker Hub work on the login outcome. GitHub
Actions exposes `steps.<step_id>.outcome`, which is the pre-`continue-on-error`
result of a step, so it is the right context for this guard:
https://docs.github.com/en/actions/reference/workflows-and-actions/contexts#steps-context

Docker and GitHub documentation both model Docker Hub publishing as login plus
build/push steps; if the login step fails, Docker Hub publishing should not keep
running:

- https://docs.github.com/en/actions/tutorials/publish-packages/publish-docker-images
- https://github.com/docker/login-action

### 2. PR 91 post-merge failure: apt metadata refresh had no retry/cleanup

The linked run failed while building `box-python-dind`. The relevant apt error
was a repository metadata race:

```text
File has unexpected size (2525257 != 2525258). Mirror sync in progress?
```

This occurred in `ubuntu/24.04/dind/install.sh` during a direct
`apt-get update`. The outer workflow retried the whole build, but the mirror
served the same inconsistent metadata across retries. The install script had no
local retry/backoff and did not clear `/var/lib/apt/lists` between attempts.

There was also a helper wiring gap. `ubuntu/24.04/dind/Dockerfile` copied
`ubuntu/24.04/common.sh` to `/tmp/common.sh`, but `dind/install.sh` only looked
for `../common.sh` relative to `/tmp/install.sh`. During Docker builds that is
`/common.sh`, so the shared helper was not sourced.

APT has a built-in `Acquire::Retries` option for retrying failed downloads:
https://manpages.ubuntu.com/manpages/resolute/man5/apt.conf.5.html

The fix adds a shared `apt_update_with_retry` helper that combines:

- apt's own `Acquire::Retries=3`.
- HTTP/HTTPS acquire timeouts.
- five outer attempts by default.
- exponential backoff.
- apt list-state cleanup between failed attempts.

The defaults can be tuned through `APT_UPDATE_MAX_RETRIES` and
`APT_UPDATE_INITIAL_DELAY`.

## False Positive Analysis

The PR validation runs were not "green despite the same command failing" in the
strict sense. They were green because the post-merge release jobs exercised
paths that are either main-only or sensitive to external transient state:

- PR 89 did not publish main release manifests to Docker Hub.
- PR 91 did not hit the Ubuntu mirror sync race during its PR validation run.

The actionable CI gap is that release-only and network-sensitive paths must be
defensive by construction. The PR validation suite cannot reliably force Docker
Hub outages or Ubuntu mirror sync windows, so these paths need idempotent guards,
retry policy, and policy tests.

## Template Comparison

The issue named four templates, and the investigation also checked the Java and
Go templates under `link-foundation` because they use the same template family.
The compact comparison is archived in `raw/template-comparison.tsv`.

Findings:

- None of the checked templates currently has root Docker image build scripts or
  workflow `apt update` calls like this repository.
- The Rust template has an explicit Docker Hub enablement guard around Docker Hub
  publishing. That pattern matches the direction already applied in PR 91.
- No checked template contains the apt metadata-refresh issue fixed here.
- No upstream template issue was opened because the exact failing pattern was
  not present in the current template repositories.

## Codebase Fix Applied

The fix was applied across all matching code paths, not just the dind path from
the failed job:

- Added `apt_update_with_retry` to `ubuntu/24.04/common.sh`.
- Made `apt_update_safe` delegate to the new retry helper.
- Made Docker build scripts source `/tmp/common.sh` when they are copied to
  `/tmp/install.sh`.
- Replaced direct apt metadata refreshes in dind, essentials, full, PHP fallback,
  JS, root/full Dockerfiles, Rocq, and language helper paths.
- Applied the same retry policy to `scripts/ubuntu-24-server-install.sh`,
  `scripts/measure-disk-space.sh`, and the disk-space measurement workflow.

## Regression Test

`experiments/test-issue92-apt-retry-policy.sh` is the focused regression test.
It checks that:

- `ubuntu/24.04/common.sh` defines the retry helper.
- The helper uses `Acquire::Retries`.
- The helper clears apt list state between failed attempts.
- `dind/install.sh` can source `/tmp/common.sh` during Docker builds.
- all Docker-copied install scripts can source `/tmp/common.sh` when present.
- key Dockerfiles and scripts use `apt_update_with_retry` instead of direct
  `apt update` call sites.
- the real helper retries after a simulated apt failure, passes
  `Acquire::Retries=3`, and clears apt list state before retrying.

This test failed before the fix because `dind/install.sh` used direct apt update
calls and did not source `/tmp/common.sh` in Docker builds. It passes after the
fix.

## Residual Risks

- A persistent upstream package outage can still fail after all retry attempts.
  That is correct: CI should fail once retries prove the dependency is not only
  transiently inconsistent.
- The successful PR validation logs were too large for complete download through
  `gh run view --log` without job narrowing. The archived metadata still proves
  their outcomes and SHAs; the failing main-run logs contain the root-cause
  evidence.
- The Docker Hub manifest fix came from PR 91 and was verified by code review
  and archived logs in this case study. This PR focuses on the apt mirror-sync
  failure that remained after PR 91.

## Outcome

Issue 92 has two separate failure classes:

1. Docker Hub manifest execution after Docker Hub login failure. This was fixed
   by PR 91 and documented here with the failing run evidence.
2. Unretried apt metadata refresh during Docker image builds. This PR fixes that
   across the repository and adds a policy regression test.
