# Solutions considered

## Selected: isolate parent-owned state

The wrapper now resolves its state parent in this order:

1. `BUDGET_STATE_PARENT`, an explicit override for other CI systems and tests;
2. `RUNNER_TEMP`, GitHub Actions' job-scoped temporary directory;
3. `TMPDIR`, then `/tmp`, as portable local fallbacks.

This changes no child environment and no measurement behavior. It makes the
ownership boundary explicit: a wrapped command may clean its temporary work,
but not the wrapper's control state. Creation failure exits 2 with the selected
parent named. With `BUDGET_VERBOSE=1`, the selected private directory is printed
to stderr; verbosity remains off by default.

The minimum test verifies exit status, output relay, absence of missing-file
noise, cleanup on exit, override precedence, and opt-in trace output. Saved
results:

| Subject | Test exit | Result |
| --- | ---: | --- |
| merge baseline (`origin/main`) | 1 | successful child becomes exit 1; output lost; missing paths |
| current JavaScript template | 1 | successful child becomes exit 1; missing paths |
| this fix | 0 | five assertions pass |

The complete outputs are `reproducer-before.log.gz`,
`reproducer-js-template.log.gz`, and `reproducer-after.log.gz`.

## Alternative: stop cleaning `/tmp`

Rejected. Cleaning the installation environment is part of the measurement's
definition, and the shared wrapper has 15 call sites unrelated to disk
measurement. Making one child avoid a collision leaves the wrapper vulnerable
to any other command that manages `TMPDIR`.

Narrowing the measurement cleanup is worthwhile as general hygiene, but it is
not a replacement for keeping parent state outside a child-owned namespace.

## Alternative: put state in the workspace

Rejected. The workspace persists across steps and is scanned, packaged, and
potentially uploaded. A crash could leave control data in the checkout, and a
concurrent or later tool could treat it as source. `RUNNER_TEMP` has the right
job lifetime without contaminating repository state.

## Alternative: retain only open file descriptors

Rejected. The wrapper polls growing output by pathname and atomically publishes
completion with `status.partial` then `mv`. Reworking all three as anonymous
pipes or descriptors would complicate EOF and survivor handling repaired by
issue #123. It also would not solve the status handoff without another IPC
mechanism.

## Alternative: replace the wrapper with GNU `timeout`

Rejected for this repository. `timeout(1)` supplies a deadline, but this wrapper
also emits the warning threshold, creates GitHub annotations, distinguishes
TERM/KILL grace periods, examines and reports process-group survivors including
privileged children, preserves step completion when survivors retain output,
and relays the command's actual exit. Replacing it would regress those tested
issue #121/#123 requirements to solve a one-line location error.

## Registry retry alternatives

The release errors need no new dependency. The existing three-attempt mirror
helper did exactly what a registry-aware retry component should do: show the
failed request, classify it, bound retries, and preserve the final status. Hiding
first-attempt stderr, converting it to annotations, or extending timeouts would
make the signal less accurate. The roughly six-to-ten-minute stalled attempts
are a possible future performance budget, but issue #125 provides no failed
final publication to justify changing that policy.
