# `run-with-budget-warning.sh` stores parent control state where a wrapped command can delete it

## Summary

`scripts/run-with-budget-warning.sh` creates its status directory under
`${TMPDIR:-/tmp}`. A command which legitimately cleans that temporary directory
therefore deletes its parent's status file while the wrapper is still using it.
The command can finish successfully, but the wrapper returns 1 and emits
`No such file or directory` instead.

This occurred in production in `link-foundation/box` run
[34455018634](https://github.com/link-foundation/box/actions/runs/34455018634),
where the wrapped disk-space measurement clears `/tmp/*` to establish a clean
measurement baseline. The measurement itself completed and uploaded all 27
component results, but the wrapper reported failure because its control
directory disappeared.

The affected line at `c3a6d23b693972a70097430f01e69fcee5a51ad2` is:

```bash
status_dir="$(mktemp -d "${TMPDIR:-/tmp}/budget-status.XXXXXX")"
```

## Minimum reproduction

Run this from a checkout of the template. It deletes only the wrapper's
throwaway fixture directory, not the machine's real `/tmp`:

```bash
work="$(mktemp -d)"
mkdir -p "$work/command-tmp" "$work/runner-tmp"

TMPDIR="$work/command-tmp" \
RUNNER_TEMP="$work/runner-tmp" \
BUDGET_POLL_SECONDS=0.05 \
  bash scripts/run-with-budget-warning.sh 5 "tmp-cleaning command" \
    bash -c 'rm -rf "${TMPDIR:?}"/*; printf "command completed\n"'

echo "wrapper exit=$?"
```

Observed:

```text
Running tmp-cleaning command with a 5s budget (warning at 3s).
command completed
.../budget-status.XXXXXX/status.partial: No such file or directory
mv: cannot stat '.../budget-status.XXXXXX/status.partial': No such file or directory
tmp-cleaning command finished in 0s of its 5s budget (exit 1).
wrapper exit=1
```

The command printed its completion message and exited 0. Only the wrapper's
post-command bookkeeping failed.

In the `box` wrapper, which also captures stdout and stderr in the same control
directory, the consequence is worse: the command's output is lost and every
poll emits two missing-file errors. The production run emitted 1,800 such
lines (900 for each stream).

## Workaround

Set `TMPDIR` to a location the wrapped command does not clean:

```yaml
- name: Long operation
  env:
    TMPDIR: ${{ runner.temp }}
  run: bash scripts/run-with-budget-warning.sh 1200 "long operation" ./operation.sh
```

This is safe only if the child cleans a known directory such as `/tmp`, rather
than deleting `${TMPDIR}` itself. There is no environment override for the
wrapper's private state independently of the child's temporary files in the
current implementation.

## Suggested fix

Keep parent-owned control state in the job-scoped `RUNNER_TEMP`, and offer an
independent override for non-GitHub CI. Fail clearly if creation is impossible:

```bash
state_parent="${BUDGET_STATE_PARENT:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}"
if ! status_dir="$(mktemp -d "${state_parent%/}/budget-status.XXXXXX")"; then
  echo "Could not create budget control state under ${state_parent}." >&2
  exit 2
fi
```

Document `BUDGET_STATE_PARENT`, and include the reproduction above as a
regression test. GitHub documents `RUNNER_TEMP` as the runner's per-job
temporary directory, emptied at the beginning and end of each job, which makes
it the appropriate default for wrapper-owned state.

This correction is now implemented and regression-tested in the pending
`link-foundation/box` fix for
[box#125](https://github.com/link-foundation/box/issues/125). A full-tree
comparison against the JavaScript, Python, Rust and PHP templates found this
specific implementation only in the JavaScript template; the other three
budget wrappers do not create a status file under `TMPDIR`.
