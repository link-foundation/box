# The sixteen practices, re-measured against this branch

Issue #123 asks the repository to follow
[`link-assistant/hive-mind/docs/CI-CD-BEST-PRACTICES.md`](https://github.com/link-assistant/hive-mind/blob/main/docs/CI-CD-BEST-PRACTICES.md).
The copy this branch was read against is stored beside this file as
`../templates/hive-mind-CI-CD-BEST-PRACTICES.md`, at commit
`f19f9f7abd692f9ca624e1632674bf92834c29b5` (2026-09-06, "docs(ci-cd): principle
10 - a serialised writer still starts behind").

#121 assessed the same sixteen and adopted the one that was outstanding
(pre-commit hooks). This is not that assessment repeated: it is each practice
re-measured against the tree as it stands on this branch, because #123's whole
subject is checks that report a state they never verified, and an inherited
"already held" is exactly that.

Every row is a command that was run, not a reading of a file name.

| # | practice | held | measurement |
|---|---|---|---|
| 1 | run checks only on relevant file changes | yes | 8 of 15 workflows carry a `paths:` filter; `scripts/ci/detect-changes.sh` classifies the rest at run time; `scripts/ci/check-workflow-path-coverage.mjs` fails CI when a tracked path is reachable by no workflow |
| 2 | file size limits | yes | `scripts/ci/check-file-line-limits.sh` in `file-sizes.yml`, and in the pre-commit hook |
| 3 | automated code formatting | yes | `scripts/ci/run-shfmt.sh`: "Every shell script matches shfmt -i 2 -ci -bn" over 200 scripts |
| 4 | static analysis and linting | yes | six checkers: `run-shellcheck.sh` (200 scripts, 0 findings at `warning`+), `run-hadolint.sh`, `run-zizmor.sh`, `check-mjs-syntax.sh`, `check-py-syntax.sh`, `check-awk-portability.sh` |
| 5 | fast-fail job ordering | yes | see §5 |
| 6 | changeset-based versioning | yes | `.changeset/` plus four scripts: `create-changeset.sh`, `apply-changesets.sh`, `validate-changeset.sh`, `check-changeset-required.sh` - the last two are among the three this branch repaired |
| 7 | validate the actual merge result | yes | `.github/actions/simulate-fresh-merge`, and `experiments/test-issue115-fresh-merge.sh` asserts every workflow that needs it uses it |
| 8 | pre-commit hooks | yes | `.githooks/pre-commit` → `scripts/ci/run-precommit-checks.sh`; adopted in #121, and the run that produced this branch's last commit reported `8 gate(s) ran, 0 failed, 0 could not run` |
| 9 | release automation | yes | `release.yml` and five reusable build workflows |
| 10 | concurrency control | yes | see §10 |
| 11 | secrets detection | yes | `scripts/ci/run-secretlint.sh`, run by `security.yml` and by the pre-commit hook |
| 12 | documentation validation | yes | `check-required-docs.sh` in `docs.yml` (six documents, 24 headings, both README markers), `links.yml` with `--include-fragments` |
| 13 | container images: native runners per architecture | yes | 5 `ubuntu-24.04-arm` references across the workflows; arm64 images are built on arm64 runners, never under QEMU |
| 14 | lint the workflows themselves | yes | `docker://rhysd/actionlint@sha256:b1934ee5…` (v1.7.12, pinned by digest with an offline version floor, #121) plus `run-zizmor.sh` widened to the composite actions |
| 15 | audit the dependency tree | n/a, measured | see §15 |
| 16 | prove you can publish before you build | yes | see §16 |

## §5 Fast-fail job ordering

The practice as written orders *test* jobs. box's expensive work is image builds,
and the ordering is the same shape: `release.yml` runs the cheap gates
(`check-version`, the changeset check, `preflight-credentials`) before it calls
any of the five `release-*` build workflows, and each build workflow is
`needs:`-gated on them.

The part box adds beyond the practice is that ordering alone does not make a
run fail: #121 found `pr-test / dind-full` concluded `failure` inside a run that
concluded grey, because GitHub ranks a cancellation above a failure.
`scripts/ci/check-pipeline-status.sh` is a terminal gate in every entry-point
workflow, and `check-status-gate-covers-all-jobs.mjs` fails CI when a job is
added outside one.

## §10 Concurrency control

Measured: **9 of box's 15 workflows carry a `concurrency:` group; 6 do not.**

The six are `pr-tests.yml`, `release-dind.yml`, `release-essentials.yml`,
`release-full.yml`, `release-js.yml` and `release-languages.yml`. Every one of
them is `workflow_call`-only:

```
$ for f in pr-tests release-dind release-essentials release-full release-js release-languages; do
    echo "$f: $(grep -A6 '^on:' .github/workflows/$f.yml | grep -E '^\s{2}\w+:' | tr -d ' :')"
  done
pr-tests: workflow_call
release-dind: workflow_call
release-essentials: workflow_call
release-full: workflow_call
release-js: workflow_call
release-languages: workflow_call
```

A reusable workflow runs inside its caller's run and is already covered by the
caller's group; giving it a second, independent group would let a called
workflow queue behind a different run of itself while its caller holds a slot.
So the six omissions are the practice being followed, not skipped - which is the
same conclusion #121 reached after its first count of `concurrency:` produced a
false positive by ignoring the call graph. Recording it here so the next count
does not have to rediscover it.

The same 9/6 split appears in the status gate: `check-pipeline-status.sh` is
called by exactly those nine entry-point workflows and by none of the six
reusable ones, for the same reason. Two independent invariants landing on the
same partition is what makes the partition believable.

`scripts/ci/read-job-cancel-in-progress.mjs` holds the other half of the
practice: a release run on `main` is never cancelled by a newer push.

## §15 Audit the dependency tree

box declares no dependency manifest of its own. Measured on this branch:

```
$ git ls-files | grep -E '(^|/)(package\.json|package-lock\.json|requirements.*\.txt|Pipfile|pyproject\.toml|Cargo\.toml|Cargo\.lock|composer\.json|go\.mod|.*\.csproj|pom\.xml|Gemfile)$'
dev/log/issues/115/pulls/116/templates/js-ai-driven-development-pipeline-template/package.json
dev/log/issues/121/pulls/122/templates/js-ai-driven-development-pipeline-template/package.json
dev/log/issues/121/pulls/122/templates/python-ai-driven-development-pipeline-template/docs/requirements.txt
dev/log/issues/121/pulls/122/templates/python-ai-driven-development-pipeline-template/pyproject.toml
```

Four paths, all four snapshots of *other* repositories stored as evidence under
`dev/log/`. A dependency audit here would be a job that can only ever pass -
which is the defect class this issue exists to remove, so adding one to satisfy a
checklist would make the pipeline worse by the issue's own standard. Recorded as
not applicable, with the measurement, exactly as #121 declined the templates'
`dependency-review` job.

What box does audit is the layer it actually ships: `assert-base-image.sh` pins
and verifies the base image of every Dockerfile, and `run-hadolint.sh` reads all
of them.

## §16 Prove you can publish before you build

Held, and box is where several of the practice's own bullets came from - #117
found a release whose notes said "28 of 56 image references resolve" while an
anonymous reader saw 0 of 56.

| bullet | box |
|---|---|
| probe with a write, not a login | `scripts/release/registry-probe.sh` opens a blob upload session and cancels it |
| report every failure, not the first | `scripts/release/preflight-credentials.sh` collects all credentials and reports once |
| check reachability, not just writability | `scripts/release/check-publication.sh` pulls anonymously after the push |
| prefer trusted publishing | Docker Hub OIDC, with the `ACTIONS_ID_TOKEN_REQUEST_URL` guard the bullet asks for, in `.github/actions/dockerhub-login/action.yml:62` |
| verify the published result anonymously, and separately | `check-publication.sh` runs after the release and does not gate the push |
| report `unknown`, never a guess | `registry-probe.sh` distinguishes a refusal from a timeout or a 429 |

The one thing #123 changes here is upstream of all six: `preflight-credentials.sh`
used to send an operator holding a rejected credential to a heading nothing
verified, which #121 fixed with `check-required-docs.sh`; this branch's
contribution is that the three *pull-request* gates can no longer answer "clean"
when git could not answer at all (`scripts/release/pr-diff-range.sh`).

## What this verification is not

It says every practice is held. It does not say the pipeline is correct - #123
exists because it was not, and every defect this branch fixes was in code that
satisfied all sixteen. A practice list is a floor.
