# Upstream reports filed from issue #121

| Repository | Issue | Reproduced at | Reproduction |
| --- | --- | --- | --- |
| `link-foundation/js-ai-driven-development-pipeline-template` | [#184](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/184) | `c3a6d23b693972a70097430f01e69fcee5a51ad2` | `experiments/issue-121-template-recheck/reproduce-all-recovered-false-negative.sh` |
| `link-foundation/rust-ai-driven-development-pipeline-template` | [#170](https://github.com/link-foundation/rust-ai-driven-development-pipeline-template/issues/170) | `f63a061fb3e23e647de0455886528a121b997678` | same script, same output |

`all-recovered-false-negative.md` is the shared body, with the per-repository
values left as `__SHA__`, `__SHORTSHA__`, `__WFLINES__`, `__PRIOR__`, `__REPO__`
and `__SIBLING__`; its first line is the issue title.

Both clones were run through the reduced reproduction verbatim before filing,
and both printed:

    Re-check: 2 lychee failure(s), 1 answered and final, 1 never got an answer
    ::notice::http://127.0.0.1:8731/ never answered lychee but answers 100..=103,200..=299 now -- not a broken link
    Re-check finished: 1 recovered, 0 still without an answer
    == $GITHUB_OUTPUT ==
    all_recovered=true

with `https://example.com/definitely-gone/` still an unforgiven `[404]` in the
report that `links.yml` was about to stop failing on.

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
