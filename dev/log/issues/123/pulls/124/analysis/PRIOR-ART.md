# What already exists, and why each fix is or is not one of those things

The task asks to "check online for known existing components/libraries that
solve a similar problem or can help". This is that check, per root cause, with
the source that settles it. **Three of the thirteen fixes are an existing
component; the rest are not, and each row says why.**

Where a claim is about a tool's documented behaviour, the citation is the
tool's own documentation. Where it is about this repository, the citation is a
measurement in this directory.

## The one piece of prior art that decides the most

[actions/runner#2684](https://github.com/actions/runner/issues/2684) — "Action
runner ignores SIGPIPE and causes shell script with redirections to hang" —
**open**, labelled `bug` and `keep`, no maintainer response. It is the upstream
statement of RC-6's mechanism: the runner sets SIGPIPE to `SIG_IGN`, and bash
passes an inherited `SIG_IGN` on to the commands it starts, so
`producer | head` yields `write error: Broken pipe` and a non-zero pipeline
status under `pipefail` instead of a silent death.

It matters twice over. It confirms RC-6 is not a local misconfiguration, so
bounding the reader is the right fix rather than a workaround. And it is *still
open after two years*, which is why the fix here does not wait for it: every
site in this repository bounds its own reader.

## Per root cause

### RC-1 — the budget wrapper

| candidate | verdict |
|---|---|
| [`timeout(1)`](https://www.gnu.org/software/coreutils/timeout) with `--kill-after` | **Closest existing tool, and used** — `run-with-budget-warning.sh` is not a replacement for `timeout`, it adds what `timeout` does not have. |
| GitHub's own `timeout-minutes` | Already present as the backstop, and it is what finally cancelled the job — 19 minutes late and without naming the step. |

`timeout` sends SIGTERM and, with `-k`, SIGKILL after a delay — and the manual is
explicit that in `--foreground` mode "any children of command will not be timed
out", while the default mode kills the process *group*. Neither disposition
helps here: the survivors were in the group **and** owned by root, so a
runner-uid `kill` fails with EPERM in both. That is the gap the fix fills — the
escalation borrows root through passwordless `sudo` for the final SIGKILL, and
liveness is read from `/proc` rather than from `kill -0`, which cannot tell
EPERM from ESRCH.

The other two things `timeout` does not do, and this job needed: a warning at
70% of the budget naming the step, and relaying the command's output so a
survivor cannot hold the step's stdout open. `systemd-run --scope` would give
proper cgroup-level teardown and is not available to an unprivileged step on a
hosted runner.

### RC-2 — the supersede question

No action or library reads "is this job's `concurrency.cancel-in-progress`
true?" — the value is not in any context GitHub exposes at run time
([Contexts](https://docs.github.com/en/actions/learn-github-actions/contexts)),
which is exactly why the gate asked a question it *could* answer instead of the
one it needed. `scripts/ci/read-job-cancel-in-progress.sh` reads it out of the
workflow file `GITHUB_WORKFLOW_REF` names, the way this repository's own
`check-status-gate-covers-all-jobs.mjs` already reads workflow files — by
indentation and regex, so a gate job on a bare runner needs no YAML library.

Adjacent things that exist and do something else:
[`tspascoal/fail-workflow-on-alerts-action`](https://github.com/tspascoal/fail-workflow-on-alerts-action)
fails a workflow on open code-scanning alerts, not on the run's own job
conclusions; the standing feature request for a
[warning status on steps and jobs](https://github.com/orgs/community/discussions/156778)
is the thing whose absence makes a terminal status gate necessary at all.

### RC-3 — log injection from text the repository prints

**Existing mechanism, adopted.** `::stop-commands::<token>` is GitHub's own
answer, documented in
[GitHub Security Lab's "Untrusted input"](https://securitylab.github.com/resources/github-actions-untrusted-input/)
guidance: stop command processing with a random token, log the untrusted output,
resume with the matching token.

The guidance carries a caveat worth recording, because it is the reason the
implementation looks the way it does: *the token is visible in the log, so if the
logged text can change after the token is printed, it can re-enable command
processing.* `run-with-commands-stopped.sh` generates a fresh 128-bit token per
invocation, and every one of the 15 call sites prints text that is already fixed
when the token is chosen — a commit message that has been written, a path list
that has been computed. An attacker would have to guess the token in advance.

Also existing and not sufficient:
[`@actions/core`](https://github.com/actions/toolkit/tree/main/packages/core)'s
`core.info` does no escaping (it is the very function that printed #121's
payload), and
[actions/runner#807](https://github.com/actions/runner/issues/807) is the
standing request that the runner not echo the `stop-commands` token in the first
place.

### RC-4 — capture while streaming

`tee /dev/stderr` is the idiom this is replacing.
[`moreutils`](https://joeyh.name/code/moreutils/) has nothing for it, and
`bash`'s process substitution (`> >(tee ...)`) reintroduces a race on the
subshell's exit. `scripts/ci/capture-and-stream.sh` is nine lines: tee into a
temporary file, stream through `>&2` — a *duplicate* of the caller's descriptor
rather than a reopen of the file behind it. There is no library here to adopt;
there is a footgun to stop using.

### RC-5 — zizmor offline

**Existing tool, existing behaviour, used correctly.** zizmor's
[Usage](https://docs.zizmor.sh/usage/) documents it exactly: "If `GH_TOKEN`,
`GITHUB_TOKEN` or `ZIZMOR_GITHUB_TOKEN` is set, then zizmor runs in online
mode"; otherwise it is offline, and offline "is the default if you don't set a
GitHub API token". The
[audit list](https://docs.zizmor.sh/audits/) marks `impostor-commit`,
`typosquat-uses` and `known-vulnerable-actions` as online audits;
`known-vulnerable-actions` is the one that reads the GitHub Advisories database.

So nothing needed inventing. What needed adding is the part no tool can supply:
**a policy that a tool which skipped its online audits must not report success.**
`ZIZMOR_ALLOW_OFFLINE=1` downgrades it for a local run without a token, and the
suite asserts no workflow sets it.

### RC-6 — SIGPIPE

Prior art above. Candidates weighed and declined: `|| true` (hides a real
producer failure), `2>/dev/null` (hides the line, keeps the status), and a
`perl`/`python` shim per site to restore the default disposition — `trap - PIPE`
does not reach a child that inherited `SIG_IGN`. Bounding the reader needs no
tool at all: this repository's `create-changeset.sh` was already doing it, and
`common.sh`'s other resolvers already end in `sort | tail`, which reads to EOF.

### RC-7 — artifact upload

**Existing option, wrong value.** `actions/upload-artifact` documents
`if-no-files-found` as `warn` (default — "output a warning but do not fail"),
`error` and `ignore`
([README](https://github.com/actions/upload-artifact)). The fix is `error` plus a
condition narrow enough for `error` to be right, which is repository-specific:
the steps run under `if: ${{ !cancelled() }}`, and the
[`steps` context](https://docs.github.com/en/actions/learn-github-actions/contexts#steps-context)
holds only steps that "have an `id` specified and have already run", so the
condition is written in the positive form — a step that never started has no
entry at all, and the negative form would be true of that empty value.

### RC-8, RC-9, RC-10 — the image-build warnings

Nothing to adopt. `npm --force` is a flag to stop passing (measured: twelve runs,
identical outcomes). `brew link | grep` is a pipeline to reorder.
`useradd -m` against a `WORKDIR`-created home is Debian
[`useradd(8)`](https://manpages.debian.org/bookworm/passwd/useradd.8.en.html)
behaving as documented — skel is copied only when useradd creates the directory
— and the fix is `-M` plus an explicit restore of the two files that matter,
chosen by measuring four images rather than by reading the man page alone.

### RC-11 — "what did this pull request change?"

This is the one place with real, popular prior art, and it was **weighed and
declined**:

| candidate | why not |
|---|---|
| [`dorny/paths-filter`](https://github.com/dorny/paths-filter) | Answers the question in a workflow step and exports booleans. Three of the four callers here are **shell scripts** that also run locally and in the pre-commit hook, where no action can run. Adopting it would leave the shell answer unfixed and add a second, differently-behaving implementation. |
| [`tj-actions/changed-files`](https://github.com/tj-actions/changed-files) | Same shape, and its compromise ([CVE-2025-30066](https://nvd.nist.gov/vuln/detail/CVE-2025-30066), March 2025) is the fixture RC-5's zizmor measurement uses. Adding a third-party action inside the release gates to answer a question `git diff` already answers is more supply chain, not less. |
| GitHub's own `paths:` triggers | Filter whole workflows, not steps, and cannot be read by a script. Already used where they fit — 8 of 15 workflows carry one. |

The repository's own `scripts/ci/detect-changes.sh` had **already** answered this
correctly ("Never under-build. With no usable range the safe classification is
'all of it changed'"). The fix is not a new dependency; it is making the other
three files agree with the one that was right.

### RC-12, RC-13

Repository-specific. RC-12 is a path regex and a printer; RC-13 is `mktemp -d`
instead of a `/tmp/*` glob — the standard advice, applied to a script this branch
wrote.

## The general question behind all thirteen

*Is there something that fails a run when it carries warning annotations?*
Searched, and no: warnings do not affect a job's conclusion, the
[feature request for a warning status](https://github.com/orgs/community/discussions/156778)
is open, and the actions that come closest
([`tspascoal/fail-workflow-on-alerts-action`](https://github.com/tspascoal/fail-workflow-on-alerts-action))
gate on code-scanning alerts rather than on annotations.

That absence is the reason this issue is a *census* rather than a gate. There is
no component to install that would have caught these; there is a body of 804
lines that had to be read. What can be automated afterwards has been: twelve
offline suites, **327 assertions, 0 failures**, each checker exercised in a
passing *and* a failing form, and every sweep pinned to a site count so a new
occurrence cannot appear unnoticed (`REQUIREMENTS.md` §B10). Measured by running
all twelve on this branch:

| suite | assertions |
| --- | ---: |
| `test-issue123-pr-diff-range.sh` | 62 |
| `test-issue123-zizmor-token.sh` | 36 |
| `test-issue123-overrun-not-supersede.sh` | 35 |
| `test-issue123-sigpipe-writers.sh` | 30 |
| `test-issue123-artifact-upload-fail-closed.sh` | 29 |
| `test-issue123-log-command-injection.sh` | 29 |
| `test-issue123-home-skel.sh` | 23 |
| `test-issue123-log-capture-truncation.sh` | 23 |
| `test-issue123-budget-enforcement.sh` | 20 |
| `test-issue123-brew-link-status.sh` | 16 |
| `test-issue123-npm-force.sh` | 14 |
| `test-issue123-apt-retry-defaults.sh` | 10 |
| **total** | **327** |

`apt-retry-defaults` reports 10 with its default settings; the two idle-timeout
legs it can also run cost ~130 s and are behind `APT_MEASURE_TIMEOUTS=1`, with
their recorded output stored in `../apt/`.

## Sources

* [timeout invocation (GNU Coreutils)](https://www.gnu.org/software/coreutils/timeout)
* [actions/runner#2684 — Action runner ignores SIGPIPE](https://github.com/actions/runner/issues/2684)
* [actions/runner#807 — Do not echo `stop-commands` command](https://github.com/actions/runner/issues/807)
* [GitHub Security Lab — Keeping your GitHub Actions and workflows secure: Untrusted input](https://securitylab.github.com/resources/github-actions-untrusted-input/)
* [zizmor — Usage](https://docs.zizmor.sh/usage/) and [Audit Rules](https://docs.zizmor.sh/audits/)
* [actions/upload-artifact](https://github.com/actions/upload-artifact)
* [GitHub Docs — Contexts](https://docs.github.com/en/actions/learn-github-actions/contexts)
* [dorny/paths-filter](https://github.com/dorny/paths-filter)
* [tj-actions/changed-files](https://github.com/tj-actions/changed-files), [CVE-2025-30066](https://nvd.nist.gov/vuln/detail/CVE-2025-30066)
* [community discussion #156778 — warning status for steps and jobs](https://github.com/orgs/community/discussions/156778)
* [tspascoal/fail-workflow-on-alerts-action](https://github.com/tspascoal/fail-workflow-on-alerts-action)
