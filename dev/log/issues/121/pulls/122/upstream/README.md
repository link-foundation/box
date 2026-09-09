# Upstream reports filed from issue #121

| Repository | Issue | Reproduced at | Reproduction |
| --- | --- | --- | --- |
| `link-foundation/js-ai-driven-development-pipeline-template` | [#184](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/184) | `c3a6d23b693972a70097430f01e69fcee5a51ad2` | `experiments/issue-121-template-recheck/reproduce-all-recovered-false-negative.sh` |
| `link-foundation/rust-ai-driven-development-pipeline-template` | [#170](https://github.com/link-foundation/rust-ai-driven-development-pipeline-template/issues/170) | `f63a061fb3e23e647de0455886528a121b997678` | same script, same output |
| `docker/buildx` | [#4067](https://github.com/docker/buildx/issues/4067) | `v0.36.1` (regression in `v0.36.0`, commit [`8db02212`](https://github.com/docker/buildx/commit/8db022122dfb7315bb553f47265552fbbae05596)) | `experiments/issue-121-buildx-rm-timeout/reproduce-rm-timeout.sh` |
| `docker/setup-buildx-action` | [#615](https://github.com/docker/setup-buildx-action/issues/615) | `v4` post step, `src/main.ts:245-252` | the same script, plus box run 34293699247 |
| `link-foundation/js-ai-driven-development-pipeline-template` | [#185](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/185) | `c3a6d23b693972a70097430f01e69fcee5a51ad2` | read from the snapshot in `dev/log/issues/121/pulls/122/templates/`; see the honest-limits section of the body |

`all-recovered-false-negative.md` is the shared body, with the per-repository
values left as `__SHA__`, `__SHORTSHA__`, `__WFLINES__`, `__PRIOR__`, `__REPO__`
and `__SIBLING__`; its first line is the issue title.

`js-docker-publish-unverified.md` is the body of the js template report, which
states in its own section what it did and did not observe.

`buildx-rm-timeout.md` and `setup-buildx-post-rm-warning.md` are the bodies of
the two docker reports, laid out in each repository's own bug-template sections;
in every file here the first line is the issue title.

Both clones were run through the reduced reproduction verbatim before filing,
and both printed:

    Re-check: 2 lychee failure(s), 1 answered and final, 1 never got an answer
    ::notice::http://127.0.0.1:8731/ never answered lychee but answers 100..=103,200..=299 now -- not a broken link
    Re-check finished: 1 recovered, 0 still without an answer
    == $GITHUB_OUTPUT ==
    all_recovered=true

with `https://example.com/definitely-gone/` still an unforgiven `[404]` in the
report that `links.yml` was about to stop failing on.

## The buildx pair, in one paragraph

`docker buildx rm` bounds the whole removal with `--timeout`, which buildx's own
help calls "the default timeout for loading builder status" and defaults to 20s.
Deleting a BuildKit state volume is not a status query and takes as long as the
build cache in it is large, so on a big build the delete is still in flight at
20s: the command exits 1, the volume is left behind, and the builder entry is
dropped from the store anyway, leaving nothing that can name the volume.
`docker/setup-buildx-action`'s post step then converts that stderr into a
`core.warning`, which is the annotation on box's green `full / docker-build-push`
job in run 34293699247 - 20.053s between the command and the error. Bisected to
v0.36.0 (v0.35.0 waits and succeeds), and pinned to the one-line change
`rm(ctx, ...)` -> `rm(timeoutCtx, ...)` that commit `8db02212` made in both
`runRm` and `rmAllInactive`. Reproduced without CI and without a large cache by
stalling only `DELETE /<api>/volumes/...` on a proxied Docker socket; both
`--timeout 0` and `--timeout 60s` fix it on v0.36.1, and box's own fix is
`cleanup:` decided from `runner.environment`.

## Considered and not filed

- **The python template's missing terminal status gates** in `docs.yml`,
  `links.yml`, `security.yml` and `workflows.yml` — already covered by the open
  `python-ai-driven-development-pipeline-template#69`
  ("check-pipeline-status.sh is wired into release.yml only").
- **The python template's `scripts/run-with-budget-warning.sh`** — the
  pre-refinement liveness/completion defect was hypothesised and did not
  reproduce: a probe with a SIGTERM-ignoring command holding a grandchild and a
  3 s budget gave exit 124, 5 s elapsed and the grandchild killed with the
  process group on *both* templates.
