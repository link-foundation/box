# A command succeeded; its CI wrapper failed

Issue [#125](https://github.com/link-foundation/box/issues/125) began as a broad
request: inspect every false positive, false negative, warning, and error in the
nine workflows created by the release of 2.10.0. Eight workflows were green.
The disk-space workflow was red. The tempting reading was that a 15-minute
installation failed. The artifact showed the opposite.

## The contradictory evidence

The failed job uploaded a JSON file generated at 08:41:59 UTC with all 27
component measurements and a 4,835 MB total. One second later the wrapper said
the measurement had exited 1. Between launch and that verdict, the log contained
1,800 copies of two errors:

```text
/tmp/budget-status.mwvhb9/stdout: No such file or directory
/tmp/budget-status.mwvhb9/stderr: No such file or directory
```

The application result existed; the observer had failed.

## One directory with two owners

`run-with-budget-warning.sh` captured command output and completion status in a
private `mktemp` directory under `/tmp`. That was meant to solve an earlier
failure: a privileged survivor must not retain the CI step's own stdout and hold
the job open.

The disk measurement, correctly for its purpose, cleaned `/tmp/*` before each
measurement so preexisting temporary files would not count toward installed
size. The child therefore deleted the parent's status, stdout, and stderr paths
one second after the wrapper started. The child retained already-open file
descriptors and completed, but the parent reopened those paths once per second
and could no longer relay them. Finally, the child wrapper tried to atomically
rename `status.partial` in a directory that no longer existed. That bookkeeping
failure became the reported command status.

This was both a false positive and a false negative: exit 0 became exit 1, and
the useful output proving success disappeared.

## The smallest proof

The regression uses no apt, sudo, Docker, or network. A child clears a private
fixture `TMPDIR`, prints one line, and exits 0. On the 2.10.0 baseline:

```text
FAIL: successful command became wrapper exit 1
FAIL: command output was lost
FAIL: wrapper tried to read control files erased by its child
```

After the fix, five assertions pass, including cleanup and the explicit state
override. The same baseline fixture also fails against the current JavaScript
pipeline template, leading to upstream
[issue #189](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/189).

## The ownership fix

GitHub Actions exposes `RUNNER_TEMP` for job-scoped temporary state. The wrapper
now selects:

```bash
state_parent="${BUDGET_STATE_PARENT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}"
```

`BUDGET_STATE_PARENT` supports non-GitHub CI and tests; local execution retains
the portable fallback. Creation failure names the parent and exits 2. Existing
`BUDGET_VERBOSE=1` now prints the chosen state directory, still off by default.
The child's environment is unchanged.

## Why the other errors stayed

The 99-job release workflow contained four Docker Hub copies whose first
attempts ended with HTTP/2 `PROTOCOL_ERROR`. Each was retried after ten seconds
and succeeded on attempt two. Those are real sub-attempt errors with a correct
green final verdict. Hiding them would make the pipeline less diagnosable.

Likewise, minimal-package man-page warnings, Homebrew/pyenv installation-path
notices, test fixture vocabulary, and one lychee report notice were truthful or
inert. The audit fixed the observer that lied and retained diagnostics that told
the truth.

## The verifier found another observer bug

The full worktree gate was also run with opt-in `BOX_VERBOSE=1`. That exercise
made two real online zizmor logs contain the live GitHub token: Bash xtrace
prints arguments after expansion, including token assignment, tests, and
export. The staged secret scanner rejected those logs, so no affected commit
or push was created.

A whole-codebase sweep found the same raw-xtrace class in registry probe and
credential preflight. Zizmor now disables tracing for the complete secret
branch; the registry paths use state-only messages that omit credentials and
authorization headers. An offline canary test went from three functional
passes plus three secrecy failures to six passes. Both real online verbose
zizmor modes were rerun and saved cleanly.

The lesson is the same as the temporary-directory failure: diagnostic
machinery is production code. It must not change a command's verdict, lose its
output, or disclose data merely because observation was enabled.

The full record—126 jobs, annotations, artifacts, lexical census, current
template trees, hive-mind verification, timeline, alternatives, and before/after
outputs—is under `dev/log/issues/125/pulls/126/`.
