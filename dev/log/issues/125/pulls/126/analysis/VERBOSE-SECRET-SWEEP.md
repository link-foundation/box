# Verbose-tracing credential sweep

The final local gate was intentionally run with `BOX_VERBOSE=1`. Secretlint
stopped the staged snapshot because the two online zizmor logs each contained
the live GitHub token five times. No affected commit was created or pushed.
That finding broadened the audit from the observed release logs to every raw
xtrace entry point in executable repository code.

## Why it leaked

The GNU Bash manual says `set -x` prints commands and their arguments after
expansion. Passing Docker `-e GH_TOKEN` by environment *name* protects the
container argv, but the wrapper first expanded the value in an assignment,
tests, and `export`. Raw xtrace therefore disclosed it before Docker ran.
GitHub documents automatic masking for supported secrets and `add-mask` for
other values, but local logs have no runner masker. Preventing expansion into
diagnostic output is the security boundary; post-processing is only defense in
depth.

Primary sources are saved as `../research/bash-set-builtin.html` and
`../research/github-actions-secrets.html`.

## Complete search and dispositions

Before the fix, 19 shell scripts and one composite-action block enabled raw
xtrace. The three credential-consuming intersections were fixed:

| Entry point | Exposure before fix | Resolution |
| --- | --- | --- |
| `scripts/ci/run-zizmor.sh` | Expanded `GH_TOKEN`/`GITHUB_TOKEN` during assignment, tests, and export. | Suspend xtrace for the complete secret branch, discard the local copy, then restore tracing. Docker still receives only `-e GH_TOKEN` by name. |
| `scripts/release/registry-probe.sh` | Expanded basic-auth password, registry bearer token, and `Authorization` header. | Replace raw xtrace with state-only request/result tracing that omits headers and credentials. |
| `scripts/release/preflight-credentials.sh` | Expanded both registry credentials through positional/local assignments and probe environment assignments. | Replace raw xtrace with credential-presence and probe-state messages that never format a value. |

The remaining 17 shell entry points are:

- seven CI utilities (`build-chain`, file-line limits, quoted-heredoc,
  hadolint, shellcheck, shfmt, and fresh-merge simulation);
- git-hook installation and the two installation/measurement drivers;
- six release utilities (base-image assertion, release notes, buildx retry,
  publication check, manifest creation, and Docker Hub mirroring);
- `run-zizmor.sh`, whose secret-dependent region is now explicitly untraced.

Searches for `TOKEN`, `PASSWORD`, `SECRET`, `AUTH`, and `CREDENTIAL` at all of
those sites found no other expanded credential. Mentions in the release tools
are explanatory text about expired tokens; authentication is performed before
the scripts, and their arguments are image references or public probe state.
The one composite-action xtrace block receives only a pinned BuildKit image,
public mirror, retry controls, and a boolean verbose input.

The four current reference-template snapshots contain zero xtrace entry
points, so this second defect is local to box and does not require another
upstream report.

## Executable proof

`experiments/test-issue125-verbose-secret-redaction.sh` drives all three public
entry points with inert canaries and offline stubs. The same test was run before
and after the implementation:

| Revision | Functional checks | Secrecy checks | Result |
| --- | ---: | ---: | --- |
| before | 3 passed | 3 failed | every verbose path leaked its canary |
| after | 3 passed | 3 passed | all paths work and no canary appears |

Exact outputs and status are
`verbose-secret-redaction-{before,after}.txt` and
`verbose-secret-redaction-status.tsv`. The real online regular and pedantic
zizmor checks were then rerun with verbose mode enabled; both pass and their
saved logs contain neither a credential nor a redaction placeholder.
