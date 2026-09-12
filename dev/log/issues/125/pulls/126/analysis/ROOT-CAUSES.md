# Root causes and signal dispositions

## RC-1 — child and parent shared a destructive temporary namespace

The wrapper created all of its private state here:

```bash
status_dir="$(mktemp -d "${TMPDIR:-/tmp}/budget-status.XXXXXX")"
```

The wrapped measurement deliberately establishes a clean disk baseline here:

```bash
maybe_sudo rm -rf /tmp/* 2>/dev/null || true
```

Those operations are individually reasonable but mutually incompatible. The
child owns temporary working data; the parent owns status and captured streams.
Putting both under the directory the child is explicitly contracted to clean
lets the child erase its parent's control plane.

Open descriptors do not preserve a pathname. The child could continue writing
to files it had already opened, but each polling pass reopened `stdout` and
`stderr` by the now-deleted path. The final status write likewise addressed
`status.partial` through the deleted directory. Its failure became the wrapper
subshell's exit status, so a successful measurement became exit 1.

This is a deterministic race, not a timeout: the first missing path arrived at
08:26:41, the measurement completed at 08:41:59, and the 2,400-second budget was
never approached.

## RC-2 — output loss was a false negative paired with the false failure

The production artifact proves the command continued and completed, while the
archived step log contains only the wrapper's repeated open failures after the
first second. The logger therefore omitted the useful command output precisely
when diagnosis needed it. Moving all three control files together fixes both
the false failure and the false-negative log stream.

## RC-3 — the terminal status gate was correct

All three failure annotations are consequences of RC-1:

1. the measure job's `Process completed with exit code 1`;
2. `Failing jobs: measure-disk-space` from the terminal gate;
3. the gate's own `Process completed with exit code 1`.

The gate was not a duplicate defect. It accurately propagated the job result,
which is its purpose. Suppressing either process annotation or teaching the gate
to overlook this job would create a genuine false negative.

## RC-4 — four release errors were successful retry telemetry

Four Docker Hub mirrors received HTTP/2 `PROTOCOL_ERROR` on attempt one:

| Job | Attempt-one interval | Attempt two |
| --- | --- | --- |
| rocq dind amd64 | 09:56:32–10:05:13 | began 10:05:23; succeeded |
| full dind arm64 | 10:05:10–10:15:06 | began 10:15:16; succeeded |
| php dind arm64 | 09:54:04–10:00:06 | began 10:00:16; succeeded |
| swift dind arm64 | 09:51:12–10:00:10 | began 10:00:20; succeeded |

Each BuildKit error is printed twice (progress record and terminal summary), so
four failures produce eight visible error lines. `mirror-to-dockerhub.sh`
classified each as transient, retained the diagnostic, waited ten seconds, and
succeeded on the next of three allowed attempts. All four jobs and the 99-job
workflow succeeded with zero annotations. That is a correct final verdict and
useful sub-attempt telemetry, not a false negative. No code change is warranted.

## RC-5 — package-manager warnings were genuine but already handled

- `update-alternatives` could not create optional man-page aliases because the
  minimal image omits the corresponding man pages. Runtime alternatives were
  installed; hiding apt output would conceal actionable package failures.
- Homebrew twice said its bin directory was not yet on `PATH`; the same build
  immediately runs `brew shellenv`, persists it, and exports the Dockerfile
  path.
- pyenv twice said it was not yet on the load path during installation; the
  image immediately configures and verifies that path.

These messages describe intermediate installer state. The final smoke tests are
the controlling verdict. They should remain visible.

## RC-6 — apparent workflow-command text was inert

One successful release log contains quoted `##[error]` text from a commit body.
It appears between GitHub's `::stop-commands::` and matching resume marker, so
the runner correctly treated it as ordinary text. The Actions API confirms zero
annotations for the entire release workflow. The census models that state and
classifies the line as `bracketed-text` rather than a command.

## RC-7 — the link-check notice was intentional

The only annotation outside the failed measurement is lychee's `notice` linking
to its successful summary. The same log reports zero link errors. A notice is
neither a warning nor an error, and removing it would make the report harder to
find.

## Closure

Only RC-1 and RC-2 require a code change, and one ownership correction closes
both. RC-3 through RC-7 are retained because altering truthful diagnostics to
make a word census quieter would reduce CI accuracy—the opposite of issue #125.
