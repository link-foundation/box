# Prior art and upstream research

## GitHub Actions job temporary storage

GitHub's official
[variables reference](https://docs.github.com/en/actions/reference/workflows-and-actions/variables)
defines `RUNNER_TEMP` as the runner's temporary directory for a job; GitHub-hosted
runners empty it at job boundaries. It is a default environment variable present
in every workflow step and cannot be overwritten through workflow configuration.
That lifecycle matches wrapper-owned state better than the process-global `/tmp`
directory a child is explicitly allowed to manage.

The source markdown consulted is stored as
`../research/github-actions-variables.md`. The
[workflow-command reference](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands)
is stored beside it and supports the census treatment of `::stop-commands::`.

## Known `RUNNER_TEMP` boundaries

Related reports were checked rather than assuming the variable is magic:

- [actions/runner#4357](https://github.com/actions/runner/issues/4357) describes
  overlapping self-hosted runner workers clearing a shared `_temp` directory.
  That is a self-hosted runner isolation defect and does not describe this hosted
  run, but it means operators must give concurrent self-hosted runners separate
  work directories.
- [actions/runner#529](https://github.com/actions/runner/issues/529) records
  cleanup failures when actions leave root-owned files under the runner temp
  directory. The budget wrapper creates and removes its files as the runner
  user, so it does not introduce that condition.
- [actions/runner#1984](https://github.com/actions/runner/issues/1984) concerns
  mounting `RUNNER_TEMP` into Docker actions. This wrapper is a host `run:`
  script, not a Docker action, so the path is directly available.

Complete issue JSON, including comments and update timestamps, is under
`../research/`. None is the cause of run `34455018634`; each is a documented
operational boundary of the selected location.

## Standard timeout components

[GNU Coreutils `timeout`](https://www.gnu.org/software/coreutils/manual/html_node/timeout-invocation.html)
and shell process groups solve the basic deadline problem. They do not supply
this repository's GitHub warning/annotation contract, privileged-survivor
diagnostics, separately relayed streams, or status artifact semantics. The
existing wrapper is therefore the nearer reusable component; isolating its
state is smaller and preserves the behaviors covered by issue #123's suites.

No third-party action is required to allocate a safe temporary directory.
Depending on one would add a supply-chain boundary to implement behavior already
provided by the runner's default environment.

## Reference-template implementation

Only the JavaScript template uses the vulnerable status-file design. Duplicate
search found no report for the deletion race, so
[js template #189](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/189)
was filed with a no-Docker reproduction, a conditional `TMPDIR` workaround, and
the `RUNNER_TEMP`/`BUDGET_STATE_PARENT` fix. The Python, Rust, and PHP wrappers
track completion without placing status files under `TMPDIR` and are unaffected.
