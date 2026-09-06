# Case Study: Issue #90 - CI/CD Release Failed After PR #89 Merge

## Summary

Issue [#90](https://github.com/link-foundation/box/issues/90) reported that CI/CD was broken after PR
[#89](https://github.com/link-foundation/box/pull/89) merged. The linked failure was release run
[`26966607948`](https://github.com/link-foundation/box/actions/runs/26966607948), job
[`79583415202`](https://github.com/link-foundation/box/actions/runs/26966607948/job/79583415202)
(`dind-manifest (perl)`), created on **2026-06-04 at 16:56:26 UTC** for merge commit
`cb1f4c9ef1dd01c615db680f0ac9876c1bc4296c`.

The root cause was an incomplete issue #82 hardening pass. Docker Hub login was allowed to fail, but the
manifest jobs still ran Docker Hub `docker manifest create/push` commands unconditionally in the same shell
step as GHCR manifest publishing. When Docker Hub timed out, GHCR manifests were pushed, then the job failed
on the Docker Hub manifest transaction.

## Evidence Saved

- Issue and PR metadata: [`github/issue-90.json`](./github/issue-90.json),
  [`github/issue-90-comments.json`](./github/issue-90-comments.json),
  [`github/pr-89.json`](./github/pr-89.json)
- CI run summaries: [`ci-logs/run-summary.txt`](./ci-logs/run-summary.txt),
  [`ci-logs/pr-89-runs.json`](./ci-logs/pr-89-runs.json),
  [`ci-logs/recent-main-runs.json`](./ci-logs/recent-main-runs.json)
- Linked failing job: job 79583415202 (`dind-manifest-perl`), metadata in
  [`ci-logs/job-79583415202.json`](./ci-logs/job-79583415202.json). The step log
  itself was not committed and GitHub's 90-day retention has since removed it;
  the failure lines are in
  [`ci-logs/error-extracts.txt`](./ci-logs/error-extracts.txt).
- Focused failure extract: [`ci-logs/error-extracts.txt`](./ci-logs/error-extracts.txt)
- PR #91 follow-up CI check: [`ci-logs/pr-91-run-26976940117-check-for-changesets.log`](./ci-logs/pr-91-run-26976940117-check-for-changesets.log)
- Template comparison files: [`templates/template-ci-files.txt`](./templates/template-ci-files.txt),
  [`templates/dockerhub-patterns.txt`](./templates/dockerhub-patterns.txt)

The full linked run log was downloaded during investigation, but not committed because it was 24 MB and the
focused job log plus job metadata contain the failure needed for review.

## Timeline

| Time (UTC) | Event |
|---|---|
| 2026-06-04 13:44:05 | PR #89 run `26955643754` succeeds at `05f1df96257438e6c56bb02635ee1333d9f00516`. |
| 2026-06-04 13:52:16 | PR #89 run `26956105055` succeeds at `52d0d0f5b0c411de794d07a4886da2c3b63aae84`. |
| 2026-06-04 14:49:48 | PR #89 run `26959450744` starts and is later cancelled by a newer push. Cancelled jobs show runner shutdown/context-cancel messages, not the release failure. |
| 2026-06-04 15:17:01 | PR #89 run `26961091250` starts at `c267b169f7abdfc9be83835375d89fb06873db11`; one `pr-test / dind-js` job fails with `overlay2` unsupported inside DinD, and the run is cancelled by the next push. |
| 2026-06-04 15:44:55 | Final PR #89 run `26962712292` succeeds at `55a9a90b65c77025545043df2a30374b0f49dd2c`. |
| 2026-06-04 16:56:20 | PR #89 merges. |
| 2026-06-04 16:56:26 | Push to `main` triggers release run `26966607948` at merge commit `cb1f4c9ef1dd01c615db680f0ac9876c1bc4296c`. |
| 2026-06-04 18:06:10 | `dind-manifest (perl)` Docker Hub login fails with `context deadline exceeded`. |
| 2026-06-04 18:06:33 | The same job fails on Docker Hub manifest creation/push with `Client.Timeout exceeded while awaiting headers`; workflow conclusion becomes failure. |

## Requirements From Issue #90

1. Read issue details and comments thoroughly.
2. Investigate all PR #89 runs/jobs, not just the linked post-merge failure.
3. Download and preserve CI logs/data under `docs/case-studies/issue-90`.
4. Reconstruct the sequence of events.
5. Compare this repository's CI/CD files against these templates:
   `js-ai-driven-development-pipeline-template`, `rust-ai-driven-development-pipeline-template`,
   `python-ai-driven-development-pipeline-template`, and `csharp-ai-driven-development-pipeline-template`.
6. Search online for relevant facts and best practices.
7. Identify root causes and propose/implement a fix.
8. Report upstream template issues if the same template bug is present.

## Root Cause

### Primary bug: Docker Hub manifest commands were not guarded

The failing job already tolerated Docker Hub login failure:

```text
Error response from daemon: Get "https://registry-1.docker.io/v2/": context deadline exceeded
```

The workflow warning then said the job would continue and GHCR would be pushed. That part was true. The same
step then ran a combined shell block that first pushed GHCR manifests and then unconditionally ran Docker Hub
manifest commands. The Docker Hub transaction failed:

```text
failed to configure transport: error pinging v2 registry:
Get "https://registry-1.docker.io/v2/":
net/http: request canceled while waiting for connection
(Client.Timeout exceeded while awaiting headers)
```

Docker's manifest documentation explains why this can fail even after GHCR succeeds: manifest creation and
push interact with the target registry, and non-default registries must be named in the manifest reference
([Docker CLI docs](https://docs.docker.com/reference/cli/docker/manifest/)).

Affected jobs before this fix:

| Job | Broken pattern |
|---|---|
| `js-manifest` | GHCR and Docker Hub manifests in one unguarded shell step |
| `essentials-manifest` | GHCR and Docker Hub manifests in one unguarded shell step |
| `languages-manifest` | GHCR and Docker Hub manifests in one unguarded shell step |
| `docker-manifest` | Separate Docker Hub step, but no successful-login guard |
| `dind-manifest` | GHCR and Docker Hub manifests in one unguarded shell step |

### Secondary issue: action versions were approaching a runtime cutoff

The failing job log also warned that `actions/checkout@v4` and `docker/login-action@v3` were Node 20 actions.
GitHub's changelog says hosted runners start using Node 24 by default on **2026-06-16**, with Node 20 removal
later in 2026 ([GitHub Changelog](https://github.blog/changelog/2025-09-19-deprecation-of-node-20-on-github-actions-runners/)).
The four templates already use newer action major versions such as `actions/checkout@v6`, `docker/login-action@v4`,
and `docker/build-push-action@v7`.

### Cosmetic diagnostics issue: unquoted `#82` truncated step names

The release logs showed the warning step as `Check Docker Hub login (issue`, because unquoted `#82` in YAML is
parsed as a comment. The workflow still ran, but the log label was misleading.

## PR #89 Run Findings

The final PR #89 branch run was green before merge. The older non-passing PR #89 runs do not match the linked
post-merge release failure:

- Run `26959450744` was cancelled after a newer push. Its focused logs show runner shutdown and context-cancel
  messages.
- Run `26961091250` was cancelled after a newer push. One `pr-test / dind-js` job failed earlier because the
  inner daemon could not start with `overlay2`; this was superseded by the final green run.
- Run `26962712292` succeeded at `55a9a90b65c77025545043df2a30374b0f49dd2c`, then PR #89 merged.

The release failure happened only after the merge commit ran on `main`.

## Template Comparison

The issue requested comparison against four templates. Relevant files were saved under
[`templates/`](./templates/).

Findings:

- The JS template publishes Docker Hub images through an optional `docker-publish` job and a local
  `publish-dockerhub` composite action. The publish step is gated on template configuration outputs.
- The Rust template explicitly configures Docker Hub publishing and gates login, metadata, Buildx, and publish
  steps on `steps.dockerhub.outputs.enabled == 'true'`.
- Python and C# templates do not carry the local multi-registry, multi-arch manifest pattern that failed here.
- The templates use current action versions (`checkout@v6`, Docker actions `@v4`/`@v7`, artifacts `@v7`).

No upstream template issue was opened because the exact unguarded-manifest bug is local to this repository's
custom release workflow, not present in the templates.

## Online Research

- GitHub Actions `if:` conditionals are evaluated as expressions for steps, so `if: steps.dockerhub-login.outcome == 'success'`
  is the correct way to skip a publish step after a tolerated login failure
  ([GitHub workflow syntax docs](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)).
- `continue-on-error` prevents a tolerated failure from failing the job, but it does not automatically skip later
  steps; later steps still need explicit conditions when they depend on the failed step
  ([GitHub workflow syntax docs](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)).
- Docker's official action examples use `docker/login-action@v4`, `docker/setup-buildx-action@v4`, and
  `docker/build-push-action@v7`
  ([docker/login-action](https://github.com/docker/login-action),
  [docker/build-push-action](https://github.com/docker/build-push-action)).

## Fix Implemented

1. Split combined manifest shell steps into independent GHCR and Docker Hub steps for `js-manifest`,
   `essentials-manifest`, `languages-manifest`, and `dind-manifest`.
2. Added `if: steps.dockerhub-login.outcome == 'success'` to every Docker Hub manifest step.
3. Added explicit Docker Hub manifest skip-warning steps when login is not successful.
4. Added the same guard to the already separate `docker-manifest` Docker Hub step.
5. Updated workflow actions to the template/current major versions:
   `actions/checkout@v6`, `actions/upload-artifact@v7`, `docker/setup-buildx-action@v4`,
   `docker/login-action@v4`, `docker/build-push-action@v7`, and `docker/metadata-action@v6`.
6. Quoted `Check Docker Hub login (issue #82)` step names so GitHub logs retain the full issue reference.
7. Added [`experiments/test-issue90-release-workflow-policy.sh`](../../../experiments/test-issue90-release-workflow-policy.sh)
   to enforce the manifest guard and action-version policy.
8. Added the changeset `.changeset/issue-90-guard-dockerhub-manifests.md` after
   PR #91 CI correctly reported that workflow code changes require a patch
   changeset. (Changesets are consumed by the release that publishes them, so
   the file no longer exists on `main` — see the 1.7.0 entry in `CHANGELOG.md`.)

## Verification

Local checks:

```bash
ruby -ryaml -e 'YAML.load_file(".github/workflows/release.yml"); YAML.load_file(".github/workflows/measure-disk-space.yml"); puts "workflow yaml parse ok"'
bash experiments/test-issue90-release-workflow-policy.sh
bash experiments/test-issue82-dockerhub-login-tolerance.sh
bash experiments/test-issue82-pr-parallel-tests.sh
bash -n scripts/*.sh scripts/release/*.sh experiments/*.sh tests/dind/*.sh
```

The policy test would have failed on the original workflow because the Docker Hub manifest commands were mixed
with GHCR commands and lacked `if: steps.dockerhub-login.outcome == 'success'`.

## Follow-ups Not Included

- Fully split Docker image build-push steps by registry. The existing build steps still publish both GHCR and
  Docker Hub tags in one `docker/build-push-action` invocation with `continue-on-error`; this issue's linked
  failure was specifically in manifest jobs after image builds had succeeded.
- Add scheduled Docker Hub credential health checks. Issue #82 already documents token rotation, but proactive
  alerting would reduce diagnosis time.
