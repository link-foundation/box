Fixes #125.

Issue #125 names the nine workflows started by the 2.10.0 release and asks for
every false positive, false negative, warning, and error in them, plus a full
comparison with the JavaScript, Python, Rust, and PHP pipeline templates and
the current hive-mind CI/CD guidance.

The audit covers **126 jobs, all four API annotations, all 58 non-expired
artifacts, and 2,598 warning/error text matches**. One workflow verdict was
false; the remaining warnings and errors are truthful retry telemetry,
package-manager notices, checker/test vocabulary, or protected fixture text.

## The false verdict

`Measure Disk Space and Update README` run
[`34455018634`](https://github.com/link-foundation/box/actions/runs/34455018634)
failed even though the measurement completed, wrote all 27 component results
(4,835 MB total), and uploaded its artifact.

`run-with-budget-warning.sh` kept its status and captured streams in a private
directory under `/tmp`. The wrapped measurement deliberately clears `/tmp/*`
to establish a clean disk baseline. One second after launch it therefore
deleted its parent's control paths. The child retained open descriptors and
completed, but the wrapper could neither relay its output nor atomically write
the final status. That bookkeeping failure converted command exit 0 into
wrapper exit 1 and emitted 1,800 `No such file or directory` lines.

This is one root cause with two incorrect observations:

- false positive: a successful command was reported failed;
- false negative: almost all successful measurement output was discarded.

## Latent verbose-tracing defect

The deliberately forced-verbose final gate found a second defect before
commit: raw Bash xtrace put the live GitHub token into each local online zizmor
log five times. Staged secretlint rejected those files, so no affected commit
or push was created. The same credential-expansion class existed in registry
probe and credential preflight.

A repository-wide audit covered all 20 pre-fix xtrace entry points. Only these
three consumed credentials; all three are fixed. The four current template
snapshots contain no xtrace entry point, so no additional upstream report is
needed.

## Fix

The wrapper now keeps parent-owned control state under GitHub's job-scoped
`RUNNER_TEMP`, falling back to `TMPDIR`/`/tmp` for portable local use.
`BUDGET_STATE_PARENT` provides an explicit override for other CI systems and
tests. A control-directory creation failure exits 2 with the parent named.
`BUDGET_VERBOSE=1` also reports the chosen location, still off by default.

The minimum offline regression has a child erase its own `TMPDIR`, print a
line, and exit 0. It fails three ways on 2.10.0 and passes five assertions here,
including output relay, cleanup, override precedence, and opt-in tracing.

Zizmor now suspends xtrace for the complete token-dependent branch. Registry
probe and credential preflight use state-only diagnostics that report request,
decision, and result without formatting credentials or authorization headers.
An offline canary regression goes from three functional passes plus three
secrecy failures before the fix to 6/6 passes after it. Both real online verbose
zizmor modes were rerun cleanly.

## Other log signal

- Four Docker Hub copy attempts genuinely ended in HTTP/2 `PROTOCOL_ERROR`;
  the existing mirror helper waited ten seconds and every retry succeeded on
  attempt two. The green final verdict is correct and the diagnostic remains.
- The three failure annotations are correct propagation of the wrapper's
  incorrect originating exit; the one notice links a successful lychee report.
- BuildKit/package-manager warnings are truthful and immediately resolved or
  informational. Quoted `##[error]` fixture text is protected by
  `stop-commands` and generated no annotation.

## Templates, guidance, and upstream

Complete current file trees and CI/CD-relevant contents from all four requested
templates are saved and compared by 155 script roles and 17 workflow roles.
The Python, Rust, and PHP budget wrappers do not store control files under
`TMPDIR`; the JavaScript template does and reproduces this failure. It is
reported upstream with the standalone reproduction, workaround, and suggested
fix as
[js template #189](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/189).

All 16 current hive-mind practices were remeasured. Fifteen apply and hold;
dependency auditing is correctly not applicable because this repository has no
root dependency manifest. A patch changeset prepares the fix for release.

## Evidence

`dev/log/issues/125/pulls/126/` contains every run/job payload, annotation,
available artifact, compressed log, timeline, requirement closure map, root
cause analysis, alternative-solution assessment, warning/error census,
primary-source research, full template snapshots, and exact upstream report.
The narrative is in `docs/case-studies/issue-125/CASE-STUDY.md`.

## Verification

- minimum issue-125 regression: 5 passed, 0 failed;
- complete experiment runner: **94 passed, 0 failed, 7 documented skips**;
- verbose credential regression: **6 passed, 0 failed**;
- pre-commit gates over the full worktree: pass;
- hadolint and digest-pinned actionlint: pass;
- online zizmor regular and pedantic high/high: pass;
- live lychee link/fragment scan: 711 links, 0 errors;
- full local output: `dev/log/issues/125/pulls/126/local-tests/`.
