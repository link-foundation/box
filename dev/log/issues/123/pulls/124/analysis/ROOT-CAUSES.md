# The twenty root causes, and the fix each one got

Issue #123 asks for "all false positives, false negatives, warnings and errors"
in the nine CI/CD runs on `main` at `1d9fb3e`, and the task asks for "the root
cause of each problem". This is that list.

The scope it is answered against is measured, not assumed:
`warnings-errors.census.md` classifies all **804** lines in those nine runs that
contain `warn` or `error`, and `annotations/README.md` holds all **7**
annotations the API reports. Everything below is either one of those lines or a
defect of the same class found while looking for its siblings — or, for RC-14
through RC-16, a defect of the same class that the GitHub runner found in the
tests this branch wrote to measure the others, and for RC-17, one that this
branch's own experiment run found in the gate that reads the most files in the
repository. RC-18 and RC-19 come from the last two sweeps: the first from asking
the release workflows the one question this issue asks of everything — "where
did you get that number?" — and the second from a break this branch itself
introduced and every one of its own gates passed. RC-20 came from the branch's
own release run going red over a changeset belonging to another repository.

## The shape they share

Every one of these is a check that reported a verdict about data it never
obtained.

* `git diff` exits 128 and prints nothing — the gate reads the silence as "no
  changes" (RC-11).
* `if-no-files-found: warn` — the step reports the absence of the only record of
  the run as a line in the log of the run whose record is missing (RC-7).
* zizmor answers "no findings to report" about audits it skipped for lack of a
  token (RC-5).
* `kill -0` fails identically for "gone" and "alive, not yours to signal", so the
  budget wrapper reports a termination it did not perform (RC-1).
* the status gate excuses a cancellation as a supersede in a job a supersede
  cannot reach (RC-2).
* `git ls-files … || true` turns a git that could not read the index into an
  empty list, and the linter reports the empty list as a clean tree (RC-17).
* `VERSION=$(tr -d '[:space:]' < VERSION)` succeeds over an empty file, and the
  bump arithmetic turns the empty string into `1.0.0` — a release named after a
  file nothing read (RC-18).
* four gates each read the same unparseable workflow line by line and each
  printed a verdict about it, because none of them could tell a file it
  disagrees with from a file no parser accepts (RC-19).
* the changeset gate matched `.changeset/` at any depth and failed the release
  over a file written in another project's format, which the release itself
  never reads (RC-20).

The two that are not that shape are the two that are the opposite — text that
was *not* a verdict being read as one (RC-3, the log injection) and a log that
was written and then destroyed (RC-4).

**Eight of the nine runs were green.** Six of the twenty root causes — RC-3,
RC-5, RC-6, RC-7, RC-8, RC-10 — were found in those eight. That is the point of
the issue: a red run tells you where to look, and a green run does not. RC-14,
RC-15 and RC-16 make the same point from the other side: they were found by a
run that went red, in tests that had been green on every machine here. RC-17 is
the third side of it: one experiment run out of many went red, once, and the
assertion that failed had thrown away the reason — the defect it was pointing at
had been in the two largest gates in this repository since they were written.

## The list

| # | Root cause | First seen | Fixed in |
|---|---|---|---|
| RC-1 | `kill -0` cannot tell EPERM from ESRCH, so a budget reports a termination it did not perform — and the survivor holds the step open on inherited stdout | 34366975927, annotation 3 | `eacba67` |
| RC-2 | the supersede question is asked of the run, and the answer excuses cancellations in jobs a supersede cannot reach | 34366975927, annotation 5 | `6a46916` |
| RC-3 | the runner accepts `##[` anywhere in a physical line, so pull-request-authored text echoed by `git commit` becomes an annotation | 34366976358, annotation 1 | `4139d54` |
| RC-4 | `tee /dev/stderr` reopens fd 2 with `O_TRUNC`, erasing the log it was streaming into | found sweeping for RC-3's printers | `4139d54` |
| RC-5 | zizmor is offline without a token, and said so on a green run while reporting "no findings" | 34366975873, `tool` census | `82656ba` |
| RC-6 | the runner starts a step's shell with SIGPIPE ignored, so `producer \| head` writes into a closed pipe under `pipefail` | 34366975942 and 34366976358, `tool` census | `2bc0814` |
| RC-7 | `if-no-files-found: warn` — an upload that cannot fail | 34366975837, `tool` census | `cd25f22` |
| RC-8 | `npm --force` on an install that never needed it | every JS build job, `docker-build` census | `2b9fa1e` |
| RC-9 | `brew link … \| grep -v Warning \|\| true` — the pipeline's status is grep's opinion of the text | found sweeping for RC-8's siblings | `c151dd5` |
| RC-10 | a `WORKDIR` that creates the home defeats `useradd -m`'s skel copy | both JS build jobs, `docker-build` census | `09549d9` |
| RC-11 | three release gates discarded `git diff`'s exit status, and two `gh` reads conflated "empty" with "failed" | found by taking upstream report F to our own tree | `45abc52` |
| RC-12 | the changeset gate's path set omitted `VERSION`, `.github/actions/` and `.githooks/`, and echoed pull-request-controlled paths with command processing live | surfaced by extracting RC-11's inline step | `45abc52` |
| RC-13 | this branch's own comparison script read `/tmp/roles-*.txt`, a glob that matched its other output | found by reading the matrix it produced | `320491d` |
| RC-14 | a suite asserted that apt's default retry count **equals** 3 — a property of the machine, reported as a property of this repository | this branch's `scripts / regression suites`, 2026-09-10T03:54:31Z | `2ba6591` |
| RC-15 | a suite's "SIGPIPE at its default" leg inherited the disposition instead of establishing it, so on a runner both its legs were the same leg | this branch's `scripts / regression suites`, 2026-09-10T03:53Z | `2ba6591` |
| RC-16 | a fake `ps` fabricated an unkillable survivor only for process groups that still existed, so the survivor died with the group it was standing in for | this branch's `scripts / regression suites`, 2026-09-10T03:53Z | `2ba6591` |
| RC-17 | eight gates decided what to read with `git ls-files`, and five of them turned a git that could not answer into an empty list — reported as a clean tree over 201 unread files | one red assertion in this branch's own experiment run | `2ba6591` |
| RC-18 | eighteen release steps each re-derived the version being published by reading a file, and an empty file publishes `1.0.0` — below every version this repository has released | asking the release workflows where their number comes from | `2ba6591` |
| RC-19 | an unparseable workflow passed all four gates that read workflows, each printing a confident verdict about a file no parser accepts | a break this branch introduced, caught by an experiment and by none of the gates | `2ba6591` |
| RC-20 | the changeset gate's path pattern had no anchor, so it validated — and failed the release over — another project's changeset committed here as evidence | this branch's own release run 34435214054, job 102738738078 | `2ba6591` |

---

## RC-1 — a budget that reported a termination it had not performed

**What the log said.** `Measure Component Disk Space` (job 102518097809) printed
at 15:37:47, 2400 s after the step began:

```
##[error]disk space measurement did not finish within its 2400s budget and was
terminated. Shorten the step or raise its budget …
```

and then ran for another **19 m 21 s**, until the runner's own
`timeout-minutes: 60` cancelled the job at 15:57:08.

**Mechanism.** The process tree was

```
wrapper (uid runner) → sudo (real uid runner) → measure-disk-space.sh (root) → apt-get (root)
```

`sudo` keeps the invoking user's real uid, so the wrapper could signal `sudo`,
and `sudo` relayed SIGTERM to the script it started. That script's children have
real uid 0: not `sudo`'s to relay to, not the wrapper's to signal. `apt-get`
survived. `kill -0` cannot report that — it fails with EPERM for "running, but
not yours to signal" and ESRCH for "gone", **exit status 1 for both** — so the
liveness check read a group of root survivors as finished, skipped its SIGKILL
escalation, and exited 124 believing it had terminated the command.

A second, separable defect explains why the *step* outlived the wrapper rather
than merely the budget: `apt-get` had inherited the step's stdout, which is the
pipe into `tee`, so `tee` never reached EOF and the shell never finished the
pipeline. Killing the wrapper would not have ended the step.

**What it was not.** The 60-minute overrun itself is not a repository defect. It
is a mirror that stopped delivering: 25.6 MB in 21 m 24 s (≈20 kB/s) from
`azure.archive.ubuntu.com`, on a job whose `apt-get update` in the same minute
reported `Fetched 9435 kB in 1s (8809 kB/s)`. No apt option covers it —
`Acquire::http::Timeout` bounds an *idle* connection, and this one was
delivering, slowly. Measured in `../apt/README.md`; the apt-hardening candidate
was retired there rather than shipped.

**Fix.** Liveness is a question about the process table and is asked of the
process table. The escalation goes SIGTERM → SIGKILL → SIGKILL with the
privilege a runner can borrow (passwordless `sudo`). Anything alive after that
is named in an `::error`. And the command's output is relayed by the wrapper, so
the only processes holding the step's own stdout are the wrapper and its shell —
a survivor can no longer hold the step open whether or not it can be killed.

**Alternatives considered.** Raising `timeout-minutes` would have made the
symptom rarer and the report no truer. Killing the process *group* alone does
not help: the survivors are in the group and still not signallable by uid.
Reading `kill -0`'s stderr to separate EPERM from ESRCH is fragile across
locales; `/proc` answers the same question in one read.

**Sweep.** `experiments/test-issue123-budget-enforcement.sh` (offline,
unprivileged, with a fake `ps` for the survivor the suite is not allowed to have
and `setsid` for the one it can) plus
`experiments/issue-123/repro-budget-privileged-child.sh`, which rebuilds the
tree in a container and runs itself against either wrapper: `--old` asserts the
defect, the default asserts the fix, both where root can be borrowed and where it
cannot. Both central claims are mutation-checked: with `BUDGET_CAPTURE_OUTPUT=0`
the same step still hangs for 25 s, and an overrun the wrapper does terminate
reports no survivors. Filed upstream as report **B** — js#187, python#81,
rust#172, php#15.

## RC-2 — a supersede that could not have happened

**What the log said.** The gate job of the same run concluded `success`, with:

```
##[warning]measure-disk-space. This run is no longer the head of main, so the
cancellation reads as a supersede rather than an overrun.
```

**Mechanism.** `check-pipeline-status.sh` asked one question of the whole run —
"is this still the branch head?" — and let the answer excuse **every** cancelled
job in it. `measure-disk-space.yml` declares, for that job:

```yaml
concurrency:
  group: measure-disk-space-${{ github.ref }}
  cancel-in-progress: false
```

In the workflow's own words it "queues instead of cancelling", so no supersede
could have reached that job, and the `1h0m0s` overrun was the only explanation
left.

**And the run really was not the head — because of itself.** This is the causal
link the timeline makes visible, and it is the reason the false positive fired
on this particular push rather than on a rare racing one:

| time (UTC, 2026-09-09) | event |
|---|---|
| 14:56:51 | all nine runs created at `1d9fb3e` |
| 14:57:06 | release run 34366976358 starts its own `Apply Changesets` job |
| **14:57:12.64** | that job pushes `1d9fb3e..1e202f5  HEAD -> main` |
| 15:57:09 | `Measure Component Disk Space` is cancelled by `timeout-minutes: 60` |
| 15:57:12 | `pipeline-status` starts, finds `main` at `1e202f5`, and excuses the cancellation |

The run was superseded by a **sibling job of the same push**, 21 seconds after it
started. Every release will do this. The test was not unlucky; it was wrong.

**Fix.** Ask the question where it can be answered.
`scripts/ci/read-job-cancel-in-progress.sh` reads the effective
`concurrency.cancel-in-progress` out of the workflow file `GITHUB_WORKFLOW_REF`
names — the job's own block first, the workflow-level block second — by
indentation and regex, the way `check-status-gate-covers-all-jobs.mjs` already
reads these files, so a gate job on a bare runner needs no YAML library. A
cancellation is excused only when the run is no longer the branch head **and**
that job's value is `true`. `false`, a bare `concurrency: group` (default
false), no group at all, a job the workflow does not declare, an expression, an
unreadable file — every one fails closed, which is the bias the script was
already written with: a missed supersede costs one noisy error, a missed overrun
costs a silent failure.

**Alternatives considered.** Comparing the run's `head_sha` against the branch
head *at the time the run was created* would have made this run pass, and would
still excuse a genuine overrun in any run older than one push. Dropping the
supersede excuse entirely would make every legitimately superseded run red —
the reason #121 added the excuse in the first place.

**Sweep.** `experiments/test-issue123-overrun-not-supersede.sh`. Part 1 drives
the gate with the shape of run 34366975927 and asserts the error the run should
have had (before the fix it reproduces the annotation verbatim and 21 of the
assertions fail); Part 6 reads **all 31 jobs of the shipped entry-point
workflows** — 30 cancel in progress and remain excusable, `measure-disk-space`
is the one that does not. Filed upstream as report **A** — js#186, python#80,
rust#171, php#14.

## RC-3 — a green job carrying a `failure` annotation

**What the log said.** `ci-logs/release-34366976358/102518168976-Apply_Changesets_.log.gz`,
between `Committing version bump...` and `git commit`'s own diffstat:

```
14:57:10.9574854Z Committing version bump...
14:57:11.2322895Z ##[error]` while explaining a fix. `docker/setup-buildx-action` creates …
14:57:11.2380481Z  2 files changed, 1 insertion(+), 40 deletions(-)
```

**Mechanism.** `apply-changesets.sh` runs `git commit -m "$NEW_VERSION: $DESCRIPTIONS"`;
git echoes the subject and body it just recorded; `$DESCRIPTIONS` is the
changeset bodies a pull request wrote. Release 2.9.0's notes were *about* issue
#121's log injection, so they quoted `##[error]` — and the runner's
`ActionCommand.TryParse` accepts `##[` **anywhere** in a physical line, unlike
`TryParseV2`. The runner turned a quoted string into a `failure` annotation on a
job that succeeded.

This is #121's mechanism with a different printer: there,
`docker/build-push-action` printed the commit message out of a buildx metadata
file; here `git commit` printed it directly. The upstream half was already filed
by #121 (docker/buildx#4066, docker/build-push-action#1612, actions/runner#4692);
what is new is that the repository prints the same text itself.

**Fix.** `scripts/ci/run-with-commands-stopped.sh` brackets a child's output with
`::stop-commands::<token>` / `::<token>::` using a fresh 128-bit token, and
always resumes. Ten printers were routed through it in `4139d54` — the five
`git commit` sites, the `git pull --rebase` a retry runs, and the four
changeset-path echoes — and later commits on this branch added five more of their
own; **15 call sites** across `.github/workflows/` and `scripts/release/` now:

```
$ git grep -nE '(^|[^-a-z])run_with_commands_stopped |bash scripts/ci/run-with-commands-stopped\.sh ' \
    -- '.github/workflows/*.yml' 'scripts/release/*' 'scripts/ci/*' | grep -vc '^scripts/ci/run-with-commands-stopped.sh:'
15
```

**Alternatives considered.** Sanitising the text (stripping `##[`) changes what
the commit message *says* — the message here is documentation of the defect, and
rewriting it would be a second false report. `git commit --quiet` suppresses this
particular printer and none of the others. `stop-commands` is the mechanism
GitHub documents for exactly this, and the token has to be unguessable because
the text is attacker-controlled.

**Sweep.** `experiments/test-issue123-log-command-injection.sh` — including the
real `apply-changesets.sh` run against a hostile changeset, and a mutation
control that restores the annotations. Filed upstream as report **C** — js#188,
python#82, rust#173, csharp#60, go#7, java#7 — and the dispatch-input variant as
report **D** (go#8, java#8, and a comment on csharp#53).

## RC-4 — a log that was written and then destroyed

**Mechanism.** Four scripts captured while streaming with

```bash
output="$(cmd 2>&1 | tee /dev/stderr)"
```

`/dev/stderr` is a symlink to `/proc/self/fd/2`, so `tee` **reopens** the file
behind fd 2 with `O_TRUNC`. Harmless when fd 2 is a pipe — which is what a
GitHub Actions step gives it, and why this survived — and destructive when it is
a file, which is what `run-with-budget-warning.sh` gives a wrapped command and
what this repository's own guidance gives a local run. The caller's descriptor is
then past end of file, so the next write leaves a NUL hole.

RC-1's fix makes this strictly worse on its own: relaying the command's output
means more callers hold a file behind fd 2. The two fixes are in adjacent
commits for that reason.

**Fix.** `scripts/ci/capture-and-stream.sh` tees into a temporary file and
streams through `>&2` — a *duplicate* of the caller's descriptor rather than a
reopen. Four sites: `buildx-retry.sh`, `docker-push-with-retry.sh`,
`git-push-with-retry.sh`, `mirror-to-dockerhub.sh`.

**Sweep.** `experiments/test-issue123-log-capture-truncation.sh`, including the
log corruption reproduced end to end and a mutation that puts `tee /dev/stderr`
back into `git-push-with-retry.sh`.

## RC-5 — an analyser that answered a question it never asked

**What the log said.** Run 34366975873 (Workflows) was green and printed, once
per pass:

```
 WARN audit: zizmor: zizmor is running in offline mode by default; some audits
 and auto-fixes will not be available. see https://docs.zizmor.sh/usage/#operating
```

**Mechanism.** Since 1.0, zizmor is offline unless it holds a GitHub API token.
Both passes were `docker run` invocations with no `-e GH_TOKEN`, and docker
forwards no environment — so a job holding `GITHUB_TOKEN` handed the container
nothing. Every audit that needs the API was skipped, `known-vulnerable-actions`
among them: the one audit here that can catch a supply-chain compromise of an
action this repository already trusts. "No findings to report" was an answer to a
question the job never asked.

**Measured**, over a fixture pinning `tj-actions/changed-files@v44`
(CVE-2025-30066) — same analyser, same fixture, twice
(`../zizmor/`):

| pass | `known-vulnerable-actions` | banner | findings |
|---|---|---|---|
| offline | 0 | 1 | 7 — 2 medium, 2 high |
| online | 2 | 0 | 8 — 2 medium, 3 high |

**Fix.** Both passes go through `scripts/ci/run-zizmor.sh`, which pins the image,
the floors and the scan targets in one place, passes the token by name rather
than on the command line, and **treats the offline banner as a failure** — a
check that reports success about audits it did not run is worse than no check at
all. `ZIZMOR_ALLOW_OFFLINE=1` downgrades it for a local run without a token, and
the suite asserts no workflow sets it. A tokenless run omits `-e GH_TOKEN` rather
than forwarding an empty value, which zizmor rejects outright.

**Alternatives considered.** Suppressing the banner (`--no-online-audits`) makes
the check honest about being narrower, and silently drops
`known-vulnerable-actions` — the audit worth the most here. Running zizmor
outside docker would forward the environment for free and give up the image pin.

**Sweep.** `experiments/test-issue123-zizmor-token.sh` (offline, with a docker
stub modelling the forwarding rule; reverting the fix fails 9 of its assertions)
and `experiments/reproduce-issue123-zizmor-offline-audits.sh` (the measurement
above; needs docker, network and a token, so the runner skips it). The same
invocation was restated in two more places, both fixed: the local invariant suite
ran the analyser with no token, and the checkout-credentials reproduction read
the floors out of a workflow that no longer holds them.

## RC-6 — writing into a closed pipe on a runner that ignores SIGPIPE

**What the log said.** Two of the nine runs printed a write error on a job that
passed:

```
run 34366975942  security / secretlint     tr: write error: Broken pipe   (×2)
run 34366976358  full / docker-build-push  grep: write error: Broken pipe
                                           tr: write error: Broken pipe
```

**Mechanism.** A step's shell is started by the runner process with SIGPIPE
already set to `SIG_IGN`, and bash passes an inherited `SIG_IGN` on to the
commands it starts. So `producer | head -c N` does not end with the producer
dying silently: its write returns EPIPE, coreutils prints
`write error: Broken pipe`, and under `set -o pipefail` — which both files set —
that status becomes the pipeline's. `bash -c 'trap "" PIPE; …'` reproduces the
runner's disposition exactly (verified equivalent to python3 setting
`signal.SIG_IGN` and `exec`ing).

Not only noise. Measured for the secretlint canary generator:

```
x=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 16)
  exit 141  under the default disposition (SIGPIPE death, reported by pipefail)
  exit 1    with SIGPIPE ignored, plus the stderr line
```

The shipped call survived only because its result was an argument to `printf`,
where a failed command substitution does not propagate. One refactor to a bare
assignment and `set -e` aborts the script, in both dispositions.

**Fix.** Bound the **reader** so the writer reaches EOF, at both sites:
`run-secretlint.sh`'s `rand_alnum()` reads a bounded block of `/dev/urandom` in a
loop (which `scripts/release/create-changeset.sh:42` already did), and
`common.sh`'s `resolve_node_lts_major()` replaces
`grep '"lts":"' | head -n1 | sed` with one `awk` that keeps the first match and
still reads the 330 kB, 287-entry feed to EOF — answering 24 against the live
feed, under gawk and mawk, and in the `ubuntu:24.04` integration test.
`common.sh:341` already documented this class for `apt_has_package`, and every
other resolver there ends in `sort | tail`, which reads to EOF.

**Alternatives considered.** `|| true` on the pipeline hides a real failure of
the producer. `2>/dev/null` hides the line and keeps the status. Re-enabling the
default SIGPIPE disposition per-command (`trap - PIPE` does not reach a child
that inherited `SIG_IGN`) needs a `perl`/`python` shim at every site.

**Sweep.** `experiments/test-issue123-sigpipe-writers.sh` — the retired shapes
under both dispositions, the two shipped definitions extracted from their files,
and a repository-wide sweep for "unbounded writer into an early-exiting reader"
over every tracked shell script and workflow, with three planted mutation
fixtures: a continuation-line offender, the multi-stage shape, and a **safe**
`curl … | head -n1` that must not be flagged (see "Considered and declined").
`experiments/issue-123/repro-sigpipe-ignored.sh` reproduces both transcripts
verbatim over a 299 kB feed fixture whose matching entries are frequent enough
that grep flushes while `head -n1` is still ahead of it — a single-match feed
does not reproduce it, because grep buffers the match and never writes twice.

## RC-7 — an upload that could not fail

**What the log said.** In run 34366975837 (Scripts), on a green job:

```
  if-no-files-found: warn
```

**Mechanism.** Both `actions/upload-artifact` steps in the tree carried
`if-no-files-found: warn`, which the action documents as "Output a warning but do
not fail the action". The one outcome each step exists to prevent — the only
record of a run not being kept — was reported as a line in the log of the run
whose record is missing.

`warn` was not arbitrary, which is why `error` alone is not the fix: the steps
run under `if: ${{ !cancelled() }}`, which is also true when the job failed
*before* the producing step ran, and then there is legitimately nothing to
upload. Turning that into an error would make every early failure fail twice, the
second time misleadingly.

**Fix.** Narrow the question instead — upload when the producing step actually
ran, and require files when it did:

```yaml
if: ${{ !cancelled() && (steps.<id>.outcome == 'success' || steps.<id>.outcome == 'failure') }}
if-no-files-found: error
```

Written in the positive form rather than `outcome != 'skipped'`: the `steps`
context holds only steps that "have an `id` specified and have already run"
(GitHub, *Contexts*), so a step that never started has no entry at all and the
negative form is true of that empty value — which would put the upload straight
back into the failing-early case.

The premise — that once the producing step has run the path is non-empty — is
measured rather than assumed: `run-experiments.sh` leaves one log per suite for a
failing run as well as a passing one, and `tee measurement.log` creates the file
even when the measured command fails before writing a byte.

**Sweep.** `experiments/test-issue123-artifact-upload-fail-closed.sh` scans every
tracked workflow and composite action for upload steps and holds each to the
shape above, with four mutation fixtures: the pre-fix `warn`, an omitted input
(the action defaults to `warn`), the negative form, and a condition naming a step
id that is not declared in that job.

## RC-8 — `npm --force` on an install that never needed it

**What the log said.** Every JS build job in the nine runs:

```
npm warn using --force Recommended protections disabled.
```

**Mechanism.** `ubuntu/24.04/js/install.sh` had carried `--force` on the
Playwright install since issue #84. npm means that warning literally, so a reader
had to decide on every green build whether a protection npm disabled was why
something later broke.

**Measured** rather than reasoned about. Two reasons for the flag were plausible:
a bin conflict (`playwright` and `@playwright/test` both declare a bin named
`playwright`) and the retry (`run_with_retry` re-runs the identical command over
the tree a failed attempt left behind). Both were tested on both images the
component builds on, in a fresh install, a reinstall, and after the
`npm install -g npm@latest` that `install.sh` performs first — **twelve runs,
with and without the flag**: twelve `exit=0`, twelve `Version 1.63.0`, and the
warning in exactly the six runs that asked for it (`../npm-force/measurement.txt`).
The flag bought nothing and cost a warning.

**Sweep.** `experiments/test-issue123-npm-force.sh` asserts offline that the line
carries no `--force` and still carries the retry and `--no-fund`, that no npm
invocation under `ubuntu/`, `scripts/` or `.github/` passes the flag, that the
sweep saying so would catch a reintroduction (and leaves brew's and git's own
`--force` alone), and that the committed measurement says what the decision
claims it says.

## RC-9 — a link whose exit status was grep's opinion of the text

**Mechanism.** Four scripts linked Homebrew's PHP with

```bash
brew link --overwrite --force php 2>&1 | grep -v "Warning" || true
```

`brew link` prints `Warning:` lines on a link that **worked**, so filtering them
is reasonable; ending the pipeline with the filter is not. A pipeline's status is
its last command's, so what was tested was grep's opinion of the text — and
`|| true` discarded even that. Three failures were invisible:

1. a brew that failed and said why — grep prints the reason, exits 0, the script
   carries on;
2. a brew that failed saying only `Warning:` lines — every line deleted, grep
   exits 1, `|| true` swallows it, the step is silent;
3. at `ubuntu/24.04/php/install.sh`, the `timeout` returning 124 — the hang
   issue #53 exists about — after which the next line logged
   `Phase: brew link completed`.

**Fix.** All four sites keep the filter on the output and the status on brew:
`ubuntu/24.04/full-box/install.sh`, `ubuntu/24.04/php/install.sh`,
`scripts/measure-disk-space.sh`, `scripts/ubuntu-24-server-install.sh`. A failure
prints everything brew said, **including** the warnings — on that path they may
be the reason — and names the status; the php site names a 124 as a timeout. The
filter is anchored, so a line that merely mentions a warning is no longer deleted
with them.

**Sweep.** `experiments/test-issue123-brew-link-status.sh` drives both shapes
against a brew stub, reproduces all three retired failures, asserts the shipped
shape reports each of them and stays silent on success, and sweeps the tree for
any `brew link` still ending in a filter or missing the status capture —
asserting the site count is 4, so a fifth site cannot be added unchecked.

## RC-10 — a home directory `useradd` refused to populate

**What the log said.** Both JS build jobs of run 34366976358, once per
architecture:

```
useradd: warning: the home directory /home/box already exists.
useradd: Not copying any file from skel directory into it.
```

**Mechanism.** `WORKDIR /home/box` stands near the top of
`ubuntu/24.04/js/Dockerfile`, and Docker creates a `WORKDIR` that is not there —
so `useradd -m` further down was handed a directory it had not made, and
`useradd` populates a home from `/etc/skel` **only when it creates the directory
itself**. The second line is the one that costs something: no skel means no
`~/.profile`, and Ubuntu's `~/.profile` is what sources `~/.bashrc` for a login
shell. Every image here descends from the JS box, so every one of them shipped a
`box` user for whom `ssh`, `su - box` and `docker run -it box bash -l` saw none
of the PATH the install scripts append to `~/.bashrc`.

**Why the obvious fix is wrong.** Moving the `WORKDIR` below the `useradd` trades
the defect for a different one: skel's `.bashrc` opens with

```bash
case $- in *i*) ;; *) return;; esac
```

and `scripts/entrypoint.sh:7` sources `~/.bashrc` from a **non-interactive**
shell, so adopting skel's copy makes that `source` return before reaching
anything the install scripts appended. Measured over four `ubuntu:24.04` images
differing only in how the home is populated
(`../useradd/workdir-skel-measurement.txt`):

| variant | non-int login | int non-login | int login | non-int source |
|---|---|---|---|---|
| early-workdir | UNSET | from-bashrc | UNSET | from-bashrc |
| late-workdir | UNSET | from-bashrc | from-bashrc | UNSET |
| **shipped** | from-bashrc | from-bashrc | from-bashrc | from-bashrc |
| shipped+bashrc | UNSET | from-bashrc | from-bashrc | UNSET |

**Fix.** The `WORKDIR` stays where it is; `useradd -M` stops useradd being asked
to populate a directory it did not create; `.profile` and `.bash_logout` are
copied back explicitly and `.bashrc` is **not**; and the chown becomes recursive,
because `cp -a` keeps root's ownership where useradd would have given the files
to the user. That is the only variant with no `UNSET` in any column — it also
fixes the non-interactive login shell, which moving the `WORKDIR` does not,
because `~/.profile` is read by every login shell whether or not it is
interactive.

**Applied everywhere.** The same defect is latent in the four shell scripts that
create the same user — `ubuntu/24.04/common.sh`,
`ubuntu/24.04/essentials-box/install.sh`, `scripts/measure-disk-space.sh`,
`scripts/ubuntu-24-server-install.sh` — since any of them can meet a `/home/box`
that already exists, after a `userdel` without `-r` or on a host that provisioned
the directory first. All four restore the two skel files after the `useradd`,
never overwriting, so a re-run is a no-op. Five sites in total with the
Dockerfile.

**Sweep.** `experiments/test-issue123-home-skel.sh` — the Dockerfile ordering and
what it now does about it, `~/.profile`'s effect on a real `bash -li` against
fixture homes, the guard's effect on a real non-interactive `source`, that
`scripts/entrypoint.sh` is still the shell that would pay for it, that no tracked
file copies skel's `.bashrc`, that all four shell sites carry the restore, and
the shipped loop executed as `common.sh` writes it over four fixture trees. Three
mutations — `useradd -m` with no restore, dropping the loop from one site, adding
skel's `.bashrc` — each fail it.

## RC-11 — three release gates that read a failed `git diff` as "nothing changed"

**Mechanism.** Three of the gates that guard every release asked

```bash
git diff --name-only "origin/${GITHUB_BASE_REF}...HEAD"
```

and discarded the exit status — `2>/dev/null || echo ""` in `check-version.sh`,
`2>/dev/null | grep` in `validate-changeset.sh`, and `| grep -E … || true` in
`release.yml`'s inline changeset-check step. `git diff` exits **128 and prints
nothing** when the range does not resolve: a checkout without `fetch-depth: 0`, a
base branch renamed or deleted while the pull request was open, a failed fetch,
no merge base.

**Measured** on a fixture branch that rewrites `VERSION` from 1.0.0 to 9.9.9 and
changes a script with no changeset, with `refs/remotes/origin/main` removed and
nothing else touched
(`experiments/issue-123/repro-version-gate-silent-pass.sh`):

```
check-version.sh       exit=0   No manual version changes detected - check passed
validate-changeset.sh  exit=1   ::error::No changeset found
inline changeset-check exit=0   0 code file(s) seen
```

Two of the three reported the passing verdict, and the third was right for the
wrong reason.

**It is not that the repository had not thought about this.** The same question
is asked a fourth time, by `scripts/ci/detect-changes.sh:113`, and there it is
already answered correctly: *"Never under-build. With no usable range the safe
classification is 'all of it changed'."* One question, four files, two answers.

**Fix.** `scripts/release/pr-diff-range.sh` is the one place that asks what a
pull request changed. It restores a base ref that is only missing locally, and
otherwise names the cause and returns 1. Three-dot, not two-dot: two-dot would
report changes the base made since the branch point as if this pull request had
made them, and three-dot is also the form that fails when no merge base exists —
a state a gate must not treat as "clean". The annotation goes to **stderr**,
because every caller reads the helper through a command substitution and an error
on stdout is captured as the answer — which is how the first draft of this helper
managed to exit 1 and print nothing at all.

**The same reading in a different tool.** `git-push-with-retry.sh` treated an
empty `gh pr list` as both "no pull request is open" and "the query failed", and
the create beneath it took `2>&1 | tail -n1`, discarding the exit status with
everything but the last line — so a declined create was handed to `gh pr merge`
as if it were a URL.

**Verbose mode.** The failure path already explains itself; the path that
*succeeds* did not. `PR_DIFF_RANGE_VERBOSE=1`, or `BOX_VERBOSE=1` repository-wide,
makes every answer carry the base ref it resolved, whether that ref had to be
fetched, the range and merge base it diffed, and how many paths came back.
**Default off**, on stderr, and printed through `run_with_commands_stopped`
because a branch name is not text this repository writes.

**Sweep.** `analysis/git-read-failure-sweep.md` dispositions the remaining **23**
sites where a git or `gh` read could be mistaken for an answer; each errs in the
strict direction already, and its production query is an assertion in
`experiments/test-issue123-pr-diff-range.sh` part 1, so a 24th cannot appear
unnoticed. Part 5 mutates the shipped scripts four times and requires each
mutation to change an outcome asserted earlier, so the suite cannot pass by
agreeing with its own fixture. Filed upstream as report **F** — java#9,
rust#174.

## RC-12 — the gate that demanded a changeset for the wrong set of paths

Surfaced by extracting RC-11's inline step into
`scripts/release/check-changeset-required.sh`: inline it could not be run outside
a workflow, and two defects only became visible once it could.

**The path set omitted three things the repository ships.** The regex is now

```
^(Dockerfile|VERSION|scripts/|ubuntu/|\.github/workflows/|\.github/actions/|\.githooks/)
```

`VERSION`, `.github/actions/` and `.githooks/` were absent. The four composite
actions under `.github/actions/` are executed by every release build, so a change
to one of them changes the pipeline exactly as a change to a workflow does;
`.githooks/` is the contributor-facing half of the same checks.

**And it echoed pull-request-controlled paths with command processing live.**
`echo "$CODE_CHANGES"` — a file named `##[error]anything` is a workflow command
anywhere in a physical line. This is RC-3 inside our own workflow, and
`validate-changeset.sh` was already doing it correctly two files away.

**Sweep.** Both are in `experiments/test-issue123-pr-diff-range.sh`, which also
pins that the gate short-circuit cannot skip `validate-changeset.sh` — the one
gate of the three that fails safe.

## RC-13 — a measurement of this branch's own, contaminated by a glob

The comparison this issue asks for (`../templates/COMPARISON.md`) is produced by
`experiments/issue-123/compare-template-roles.sh`. Its first draft wrote
`/tmp/roles-<name>.txt` and read them back with `cat /tmp/roles-*.txt` — which
also matched `/tmp/roles-all.txt` from the same run, and anything else a previous
run or another process had left under that glob. The workflow matrix came out
with the script matrix's summary lines in it, as roles.

It is in this list because it is the same defect as the rest: measuring one thing
with a query that can match another, and reporting the result as if it were the
measurement. The script now uses a private `mktemp -d` with a trap, and says so
in a comment at the site (`compare-template-roles.sh:30-38`) so the next reader
does not reintroduce it.

---

## RC-14, RC-15, RC-16 — the three the runner found in this branch's own tests

These three arrived after the rest were written, from the first `scripts /
regression suites` job that ran the finished branch. All three are suites
*written for this issue* committing this issue's defect, and all three passed on
every machine the branch was developed on. That is the part worth keeping: the
census in this directory was compiled by reading logs line by line rather than
by trusting a green conclusion, and these are three defects that only that
method — or, as it happened, a red run — could find.

### RC-14 — an environment's constant, pinned as if it were the repository's

**Mechanism.** `experiments/test-issue123-apt-retry-defaults.sh` measures how
many connections `apt-get update` opens against a fixture mirror that resets
every connection, which yields apt's retry count exactly. It then asserted that
the *default* leg opens 8 connections — 3 retries — because that is what apt
2.8.3 does here and inside `ubuntu:24.04`. On `ubuntu-24.04` the same apt 2.8.3
on the same Ubuntu 24.04.4 opens 4: **1** retry. The suite failed the branch
with `the default is no longer 3, so -o Acquire::Retries=3 has stopped being a
no-op` — a true sentence about the runner and a false one about this repository,
where nothing depends on the number being 3.

**Root cause.** The assertion held the wrong invariant. `apt_update_with_retry`
*passes* `-o Acquire::Retries=3`, so a lower environmental default makes the
refresh stronger, not weaker; only a default **above** 3 turns the option into a
downgrade. Equality was never the property worth holding, and pinning the
spelling of an environment's constant is precisely the shape of RC-2 and RC-5.

**Why the runner's default is 1 is still unknown**, and `../apt/README.md`
records what was ruled out in `actions/runner-images` (the `80-retries` file
writes `APT::Acquire::Retries`, a key apt does not read; the apt-mock wrappers
add an *outer* loop). So the fix is a measurement plus a diagnostic rather than
a guess: the suite derives the default from its own connection count, prints
`apt-config dump Acquire::Retries`, then — because a *name* is not a *value* —
every dumped key whose name matches `retries` (so the runner's inert
`APT::Acquire::Retries` is seen for what it is: `repro-apt-retries-key.sh` shows
it dumping nothing under the key apt reads), every apt.conf line mentioning
retries with its file and contents, the `apt.conf.d` listing, and `APT_CONFIG`'s
contents. The first version of this diagnostic printed only the file *names*
matching the word, and so blamed `80-retries` — a file invisible to the key it
appears to set — for a 1 it cannot produce; printing values is what closes that
gap. A new assertion makes the report a check: `apt-config dump` and the
measurement are two readers of one setting, so if the dump reports a number and
the measured default disagrees, the suite **fails**, because that is the
signature of a wrapper deciding retries outside apt (which is what the runner
images install). The directional verdict fails only on a default above what the
refresh sites pin. Verified in both directions with `APT_CONFIG` fixtures: a
default of 1 passes as "a strengthening", a default of 5 fails as "has become a
downgrade"; and an `apt-config` shim reporting a value the measurement
contradicts fails the new cross-check.

**Sweep (B10).** The finding has a repository-wide half. If a refresh site can be
weaker than a bare `apt-get update` on some machine, then every refresh site must
pass the option rather than inherit a default. Part 4 of the suite sweeps all 137
tracked `*.sh`, `*.yml`, `*.yaml` and `Dockerfile` sources for an `apt-get update`
with no `Acquire::Retries=`, over **logical** lines — all three real refresh sites
spell the option on a `\`-continuation, and a per-line grep would report every one
of them as an offender. `experiments/` is excluded by name, because this suite's
own fixture runs `apt-get update` with no retry option on purpose. A planted
offender must make the sweep fail, and does.

### RC-15 — a fixture that inherited the premise it was supposed to establish

**Mechanism.** `experiments/test-issue123-sigpipe-writers.sh` compares two signal
dispositions: SIGPIPE ignored ("runner") and SIGPIPE at its default. The first was
established with `trap '' PIPE`. The second was a bare `bash -c` — i.e. whatever
the machine happened to be doing. A GitHub Actions step's shell is started with
SIGPIPE already `SIG_IGN` (actions/runner#2684 — the very fact the suite exists to
describe), an ignored disposition survives `exec`, and bash cannot undo one: a
signal ignored on entry to a non-interactive shell can be neither trapped nor
reset, so `trap - PIPE` is accepted and does nothing. On the runner the two legs
were therefore one leg, and the suite reported
`fixture: the retired shape already complains with default SIGPIPE`.

**Root cause.** Same shape as RC-14: a property of the environment, assumed
rather than measured, underneath a verdict about the code. The default leg now
enters through `perl -e '$SIG{PIPE} = "DEFAULT"; exec ...'` (`python3` where perl
is absent; perl-base is Essential in Debian and Ubuntu and present on every
runner image), and a new Part 0 reads each leg's `SigIgn` mask out of
`/proc/self/status` and asserts the bit for signal 13 — set for the runner leg,
clear for the default leg. The premise now fails loudly instead of the conclusion
failing mysteriously. Verified by running the suite under an ambient `trap ''
PIPE`, which is what the runner does: 33 passed, 0 failed; with the resetter
removed, exactly the runner's two failures come back.

### RC-16 — a stand-in for an unkillable process that was not unkillable

**Mechanism.** `experiments/test-issue123-budget-enforcement.sh` proves that
`run-with-budget-warning.sh` *reports* a process it could not kill rather than
calling it terminated (RC-1). It cannot leave a real unkillable process behind,
so it fakes `ps`: real output first, then one fabricated root-owned member of the
command's process group. The group id must not be guessed, so the fake listed the
groups **currently in the process table** and fabricated a member for each. That
makes the lie conditional on the truth: once `signal_command TERM` took the real
subshell, the command's group left the table and the fabricated survivor left with
it, `group_members` returned empty, and the wrapper correctly concluded there were
no survivors. Three assertions then failed — `ignored SIGTERM`,
`::error title=unkillable step left processes running::` and `fake-survivor` —
blaming the shipped wrapper for a race in the fixture. Locally the group lingered
past the grace period often enough to pass.

**Root cause.** The fixture modelled "a process that survives" as "a process that
exists while something else exists". The fake now records every group id it has
ever seen in a per-leg state file and re-reports all of them on every call, so the
survivor outlives the group it stands in for — which is what unkillable means.
The mutation control (the same overrun with no fake) must still report no
survivors, and does; and stubbing `report_survivors` to a no-op still produces
exactly the two intended failures.

---

## RC-17 — a linter that read nothing, and called the tree clean

**How it surfaced.** A full `scripts/ci/run-experiments.sh` on this branch came
back 88 passed / 1 failed where every previous run had been 89 / 0. The single
failure was in `test-issue121-git-hooks.sh`:

```
FAIL: run-shellcheck.sh does not see the hook; nothing lints it
PASS: run-shfmt.sh discovers .githooks/pre-commit
```

Those two lines run the identical discovery two statements apart, against the
same tree, and the second one passed. So the file set had not changed — the
*answer* had. The assertion could not say more, because it called the gate as
`bash …/run-shellcheck.sh --list 2>/dev/null` and discarded the only diagnostic
there was. Running the suite alone gave 91 / 0; 200 concurrent `git add -A`
against 60 `--list` probes reproduced nothing, and neither did 150 probes run
against a full `run-precommit-checks.sh`. The trigger is still unproven.

**What is not unproven** is what the gate does when discovery comes back short,
and that turned out to be worth more than the trigger:

```bash
collect_files() {
  git ls-files -z --cached --others --exclude-standard --deduplicate '*.sh' '.githooks/*' \
    | tr '\0' '\n' | grep -v '^dev/log/' | sort -u || true
}
```

The trailing `|| true` converts *any* failure of `git ls-files` — a busy index,
an unreadable object, a `git` that is not there — into an empty list, and every
caller then read that empty list as a fact about the repository rather than as a
failure to ask it. Measured against the shipped script with a `git` that exits
128 on `ls-files`:

```
==> No shell scripts to check
$ echo $?
0
```

201 tracked shell scripts, none of them opened, and a gate that says the tree is
clean. This is the sentence at the top of this document with nothing changed:
*a check reporting a verdict about data it never obtained*. Whether the flake
was this or something else, this is a false negative that needs no flake at all
— a `git` failure on the runner would have produced a green `lint` job.

**Root cause.** Not the `|| true` by itself: the gates had no way to distinguish
the two empty answers. "git could not tell me" and "git told me, and there is
nothing" are different facts with different fixes — one is an infrastructure
failure, the other is a wrong glob — and both were being rendered as the same
silence, then as success. The repository already knew this: `check-py-syntax.sh`,
`check-mjs-syntax.sh`, `check-awk-portability.sh`, `run-hadolint.sh` and
`check-file-line-limits.sh` all refuse an empty input set in so many words, and
`run-shfmt.sh` even feeds shfmt a deliberately misformatted canary so its silence
cannot pass for a verdict. The guard existed; it was simply not in every gate
that needed it.

**The fix, and the sweep behind it.** Every gate under `scripts/ci/` that
discovers its own inputs with `git ls-files` now separates the two answers and
reports each as an error, naming which one happened:

```bash
collect_files() {
  local listing
  listing="$(
    git ls-files -z --cached --others --exclude-standard --deduplicate '*.sh' '.githooks/*' \
      | tr '\0' '\n'
    exit "${PIPESTATUS[0]}"
  )" || return 1
  printf '%s\n' "$listing" | { grep -v '^dev/log/' || [ "$?" = 1 ]; } | sort -u
}
```

Three details are load-bearing, and each was measured rather than assumed:
command substitution silently drops NUL bytes, so `tr` has to run *inside* the
substitution; `exit "${PIPESTATUS[0]}"` recovers git's status without `pipefail`,
which would also promote `grep`'s exit 1; and `grep`'s exit 1 means "selected
nothing", which is a legitimately empty tree, so it is absorbed while anything
above 1 is not. `discover_or_exit` then ends the script with exit 2 and an
`::error` that says which of the two happened, and every caller pairs it with
`$( ) || exit $?` — never `< <(...)`, because a process substitution's `exit`
ends only the subshell and would leave the caller carrying on with an empty list.

**The sweep found more than the three gates it started with.** Written as a
requirement of this issue — a defect that exists in more than one place has to be
fixed in all of them — `test-issue123-discovery-fail-closed.sh` drives all eight
discovering gates through both failure modes, and produced two findings I had
already, wrongly, cleared:

* `check-py-syntax.sh` and `check-mjs-syntax.sh` did fail closed on the check
  path, so a first pass called them safe. They reached that exit through the
  *empty-set* branch, which prints `No files to check — the discovery glob is
  wrong` — an operator sent to inspect a glob that was never the problem. A
  correct verdict for a stated reason that is false is still a report about data
  the checker never had.
* Worse, four gates answered `--list-inputs` — the contract
  `check-workflow-path-coverage.mjs` reads to decide whether a workflow's
  `paths:` filter can match what a gate reads — by printing an empty list and
  exiting **0**. A gate that cannot enumerate would have reported that it reads
  no files, and every file it actually reads would have looked covered by any
  filter at all. That is the same false negative one layer up, in the gate whose
  entire job is to catch checks that never run. All four now exit 2 there, and
  the consumer already turns a failed `--list-inputs` into its own error.

* And the ninth site is the one that runs the other eight.
  `scripts/ci/run-precommit-checks.sh` is not a gate, so the first sweep exempted
  it in writing — "the hook driver, not a gate: it dispatches to the gates above
  and reports what each said" — a sentence that is true about its job and says
  nothing about how it reads git. It read the index through
  `< <(git diff --cached --name-only -z … 2>/dev/null)`, where the status is
  unreachable by construction, and its `--worktree` mode read
  `git ls-files -z --cached --others` the same way. A git that could not answer
  therefore produced an empty array and the driver printed
  `==> Nothing staged; no checks to run` and exited 0 — over a commit it had
  never read, having run none of the fourteen gates. Both listings are captured
  through `$( … )` with `exit "${PIPESTATUS[0]}"` now and a failure is exit 2,
  the "could not run" status the hook deliberately does not block on and CI
  still checks. The distinction matters more here than in a gate: an *empty*
  listing is a legitimate answer for this script, because a commit really can
  stage nothing, so only the failing half is an error. It is exercised by part 7
  of the suite — both listings failing, an empty index still passing, and a
  mutation restoring the old form — and the exemption list is one name shorter.

And the sweep's own first version committed the defect it hunts:
`run-hadolint.sh` carried the `|| true` with its globs wrapped across
continuation lines, so `ls-files` and `|| true` never shared a physical line and
a line-at-a-time `grep` pronounced the tree clean. The sweep joins backslash
continuations before matching now — the same treatment
`test-issue123-apt-retry-defaults.sh` gives apt's sources — and a planted
multi-line offender pins that it does.

**Coverage.** Eight gates plus the hook driver fixed or confirmed, 94
assertions. Part 1 requires
every `scripts/ci` script that calls `git ls-files` to be either driven by this
suite or exempt **in writing**, with the exemption checked against the tree so it
cannot go stale; Parts 2 and 3 drive both failure modes; Part 4 restores the
pre-fix shape in a copy of each fixed gate and requires the assertions to fail
against it; Parts 5 and 6 sweep for the shape returning and pin the
`--list-inputs` contract on both sides; part 7 asks the whole question of the
hook driver. The assertion that started this keeps
`--list`'s stderr now, so a recurrence explains itself instead of costing another
iteration.

---

## RC-18 — eighteen jobs each deciding, separately, which version this is

**How it surfaced.** Not from a log line. The census question this issue asks of
every check — *where did you get the data you are reporting on?* — asked of the
release pipeline instead of a linter. Every release job puts a version string on
an image tag, a manifest and a release note, and each one of them worked it out
for itself:

```yaml
- name: Get latest version
  id: version
  run: |
    git pull origin main || true
    VERSION=$(tr -d '[:space:]' < VERSION)
    echo "version=$VERSION" >> "$GITHUB_OUTPUT"
```

Eighteen steps across the six release workflows, three in each file. Sixteen of
the eighteen open with the `git pull`; the two that do not are both in
`release.yml` — the version-bump job's own `CURRENT_VERSION` read, and the read
in its "Fetch latest changes" step, which pulls without `|| true` first.

**What the read cannot catch.** A *missing* VERSION file fails, but only by
accident: the runner's default shell is `bash -e {0}`, the redirection has
nothing to read, and the step dies of that. An empty or whitespace-only file is
caught by nothing at all. Measured:

```
$ : > VERSION
$ V=$(tr -d '[:space:]' < VERSION); echo "[$V] status=$?"
[] status=0
```

`tr` did its job. The step writes `version=` to `$GITHUB_OUTPUT` and reports
success. Where that empty string lands decides how bad it is: in a build job it
becomes an image tag, `ghcr.io/link-foundation/box-js:-amd64`. In the two jobs
that *bump* the version, it becomes arithmetic:

```
$ IFS='.' read -r MAJOR MINOR PATCH <<< ""
$ MAJOR=$((MAJOR + 1)); echo "$MAJOR.0.0"
1.0.0
```

So an unreadable VERSION file does not stop a release. It publishes **1.0.0** —
a version below every version this repository has ever released, computed from a
file nothing looked at, and pushed to `main`. That is this document's opening
sentence with the words changed: a verdict about data never obtained.

**The `git pull` is the second half of the same defect.** It is not needed and it
is not safe. Not needed, because every one of those jobs checks out with
`ref: main`, which `actions/checkout` resolves against the remote when the job
starts — after `apply-changesets` has pushed the bump, since every build job
`needs` it. Not safe, because the only thing the pull can still bring in is a
commit somebody pushed to `main` *after* this release started: the late jobs of a
release then build and tag a different tree from the early ones, and `|| true`
means no log says which happened.

**Root cause.** Eighteen independent answers to a question with one correct
answer per run. The number of readers is the defect, not the shape of any one of
them — hardening the `tr` in all eighteen places would leave eighteen jobs still
free to disagree.

**The fix.** The pipeline had already computed it once and was already handing it
over. `release.yml`'s `detect-changes` job publishes
`version: ${{ steps.version.outputs.version }}` as a job output, and every call
site passes `changes: ${{ toJSON(needs.detect-changes.outputs) }}` — so
`fromJSON(inputs.changes)['version']` has been available inside all five called
workflows the whole time. No new plumbing; one reader:

```yaml
- name: Get latest version
  id: version
  env:
    PIPELINE_VERSION: ${{ fromJSON(inputs.changes)['version'] }}
  run: bash scripts/release/release-version.sh
```

`scripts/release/release-version.sh` prefers the pipeline's answer, cross-checks
it against the VERSION file in this job's checkout, refuses an empty or
malformed value from either with an `::error` naming what each source said, and
— when both are usable and they *disagree* — publishes the pipeline's and emits
a `::warning` saying `main` moved after the release started. That disagreement
was previously invisible by construction; it is now the only place it is
visible. This is the same shape as issue #119b's `image-tags.sh`: one job
computes the answer, and every job that needs it is handed the same one.

`version_is_sane` accepts `MAJOR.MINOR.PATCH` and nothing else — deliberately
narrower than semver, because the two bump callers do `IFS='.' read -r MAJOR
MINOR PATCH` then `$((PATCH + 1))`, and a pre-release suffix makes `PATCH` the
string `0-rc`, which is an arithmetic error rather than a version. Accepting a
shape the consumers cannot use would move the failure further from its cause.

**Coverage.** `experiments/test-issue123-release-version.sh`, 86 assertions.
It reproduces the pre-fix step byte for byte from `git show HEAD:` and requires
it to publish the empty version; drives every failure mode of the helper; checks
each of the five call sites for the `changes:` map *at that call site* rather
than counting five of them anywhere in the file; sweeps for both the hand-rolled
read and the `git pull origin main || true` returning, with comment lines
excluded in both directions so the fix's own explanation of the line it removed
cannot satisfy a sweep for the line; and mutates the shipped helper twice —
loosening the version pattern alone does *not* reopen the hole (the emptiness
guard still refuses), while removing that guard does, which is the assertion
proving the suite can see the defect at all.

One of those assertions exists for a failure that surfaces a long way from its
cause. `check-checkout-credentials.mjs` classifies a job by following every
`scripts/...` string in that job's closure, transitively, and calls the job a
writer to the remote if anything it reaches pushes. The helper's error message
originally named `scripts/release/apply-changesets.sh` **by path** — in prose it
only ever *prints* — and `apply-changesets.sh` calls `git-push-with-retry.sh`.
Measured, with the path restored:

```
$ node scripts/ci/check-checkout-credentials.mjs   # EXIT=1
17 ::error … writes to the remote, but this checkout drops the job token
```

17 errors in 17 distinct jobs — the ten build jobs, the five manifest jobs,
`detect-changes` and `create-release` — every one of them told to set
`persist-credentials: true` for a push none of them makes. Fixed at the source
by naming the script without its path, which reads identically to an operator:
taking the checker's advice instead would have left the job token in seventeen
non-writing jobs, quieting the gate by making the repository less safe. An
assertion pins that the helper spells no `scripts/` path outside a comment, and
that the checker is still green with it.

---

## RC-19 — a file no parser accepts, and four gates with opinions about it

**How it surfaced.** In this branch's own edit, three commits after RC-18 was
written. Three of the eighteen replaced steps had a fourth line in their `run: |`
block that the other fifteen did not, and the replacement left it stranded:

```yaml
run: bash scripts/release/release-version.sh
  echo "Building version: $VERSION"
```

`release-full.yml` was not YAML any more. `Psych::SyntaxError … line 175 column
33`. It was found by four experiment suites going red, and by **none** of the
eleven gates the pre-commit hook runs — including the four whose entire input is
workflow files. Each of those four was handed the broken file, and each exited 0
while printing a verdict about it:

```
check-status-gate-covers-all-jobs.mjs  EXIT=0  status covers all 3 other job(s).
check-timeout-budgets.mjs              EXIT=0  Every budget in 1 workflow(s) fits inside its job cap
check-workflow-path-coverage.mjs       EXIT=0  6 script(s) across 1 workflow(s); every file … can start a run
check-checkout-credentials.mjs         EXIT=0  3 checkout step(s) across 1 file(s); each one states …
```

(Measured with an explicit file argument, the way the hook invokes them. An
earlier reading of this — that two of the four exited 2 — was wrong: those exit
2s were usage errors from calling the gates with no arguments at all.)

**Root cause.** Not a bug in any of the four. All four read workflows line by
line *on purpose*: they ask questions about ordering and indentation that a
parsed tree throws away. A line-oriented reader cannot tell a file it disagrees
with from a file no parser accepts — so each of them assumes a guarantee that
nothing in the repository established. The missing piece is a floor, not a fix
to any of the four.

actionlint does catch it, and runs in CI — but it needs docker, so the
pre-commit hook cannot run it, and the broken file was committable and was
committed locally eleven green gates deep.

**The fix.** `scripts/ci/check-workflow-yaml.sh`: every tracked workflow and
composite action parses, checked with ruby's `psych` — the only offline YAML
parser available here (python `yaml`, node `yaml`, `yq` and actionlint are all
absent), present in the standard library on the runners and in the development
image, and costing milliseconds. It runs **first** in `run-precommit-checks.sh`,
before the three gates that read workflows line by line, and in `workflows.yml`
before the status-gate step. It discovers with `git ls-files` after anchoring at
`git rev-parse --show-toplevel` (issue #121) and fails closed when that listing
fails (RC-17, above), so it is driven by
`test-issue123-discovery-fail-closed.sh`'s fixtures rather than exempted with
the other workflow readers.

**What it does not catch, recorded next to it rather than implied.** An orphan
line with no colon in it is a legal plain-scalar continuation:

```yaml
run: bash scripts/release/release-version.sh
  echo hello
```

parses, as the string `bash scripts/release/release-version.sh echo hello`. YAML
validity is the floor, not the ceiling; actionlint's schema is what reads the
parsed tree. The three orphans that shipped here all contained `version: `,
which is why this floor was enough to find them.

**Coverage.** `experiments/test-issue123-workflow-yaml.sh`, 28 assertions, in
five parts: the break that actually shipped (file, line, reason, `::` defanging,
summary); the same broken file put back through the two gates that passed it, so
the reason this gate exists is a measurement in the suite and not a claim in a
comment; the stated limits, including that the header still says "the floor, not
the ceiling"; both could-not-run paths (an unreadable file, and an empty
repository, which must say "this check verified nothing"); and the wiring — the
hook, the workflow step, the `paths:` filter, and `--list-inputs` agreeing with
`git ls-files`.

The sweep that followed mattered more than the one file: all fifteen replacement
sites were re-read against `git show HEAD:`, exactly three carried an orphan, and
all six release workflows were re-parsed afterwards.

---

## RC-20 — a gate that failed the release over another project's changeset

**How it surfaced.** In this branch's own release run, on the commit before this
one: run `34435214054`, job `102738738078` (`Check for Changesets`), 2026-09-10
03:56:11Z, at `1a756e6`.

```
Found added changeset(s):
.changeset/issue-123-ci-false-positives.md
dev/log/issues/123/pulls/124/templates/go/.changeset/add-changeset-workflow.md
dev/log/issues/123/pulls/124/templates/go/.changeset/fix-ci-workflow-dependencies.md
dev/log/issues/123/pulls/124/templates/java/.changeset/fix-ci-workflow-dependencies.md
dev/log/issues/123/pulls/124/templates/js/.changeset/fix-all-open-pipeline-issues.md

Validating: .changeset/issue-123-ci-false-positives.md
Valid changeset format
Validating: dev/log/issues/123/pulls/124/templates/go/.changeset/add-changeset-workflow.md
##[error]Invalid changeset format in dev/log/…/templates/go/.changeset/add-changeset-workflow.md
Expected 'bump: patch|minor|major' in frontmatter
```

The whole release was red, and `pipeline-status` with it — over a file that
belongs to `go-ai-driven-development-pipeline-template`, written in the
changesets npm format (`'go-ai-driven-development-pipeline-template': minor`)
rather than in this repository's `bump:` format, committed here as pinned
evidence for the template comparison the issue asks for.

**Root cause.** The verdict was *true about the file* and *false about the
repository*: the file is not a changeset of this project, and nothing in the
release ever reads it. `validate-changeset.sh` selected its subject with

```bash
grep "^A.*${CHANGESET_DIR}/.*\.md$" | grep -v "README.md" | awk '{print $2}'
```

which has no anchor at all — `.changeset/` matched anywhere in the path — while
the two scripts that actually *consume* changesets, `apply-changesets.sh` and
`check-changesets.sh`, both read exactly
`find .changeset -maxdepth 1 -name '*.md' ! -name README.md`. A gate and its
consumer disagreeing about their subject is the same defect this issue is about
seen from one step further out: the gate reported a verdict about data it had no
business obtaining. Three smaller faults rode along in the same expression —
`${CHANGESET_DIR}` interpolated unescaped, so the `.` of `.changeset` matched any
character; `awk '{print $2}'` split a tab-separated `--name-status` line on
whitespace, truncating any path containing a space; and `grep -v "README.md"`
was unanchored in both directions.

**The fix.** The pattern is anchored at the repository root and the depth is the
consumer's:

```bash
CHANGESET_PATH_REGEX="^$(printf '%s' "$CHANGESET_DIR" | sed 's/\./\\./g')/[^/]+\.md$"
```

with the status/path split done by `awk -F'\t'` and the loop reading line by
line rather than word by word. Anchoring is the general fix, not an exclusion of
`dev/log/`: a `.changeset/` at any depth other than the root is not what the
release applies, whoever wrote it.

**Everywhere else this question had to be asked.** The pinned template evidence
puts 23 `.sh`, 87 `.mjs`, 15 `.py` and 34 `.yml` files belonging to seven other
repositories inside this tree, so every gate that discovers its own inputs was
re-measured against them rather than assumed safe:

| Gate | Inputs | Under `dev/log/` |
|---|---:|---:|
| `check-awk-portability.sh` | 259 | 0 |
| `check-file-line-limits.sh` | 316 | 0 |
| `check-heredoc-vars.sh` | 205 | 0 |
| `check-mjs-syntax.sh` | 19 | 0 |
| `check-py-syntax.sh` | 3 | 0 |
| `run-hadolint.sh` | 23 | 0 |
| `run-shellcheck.sh` | 206 | 0 |
| `run-shfmt.sh` | 206 | 0 |
| `check-workflow-yaml.sh` | 19 | 0 |
| `check-required-docs.sh` | 99 | 0 |

Every one of them already excludes `dev/log/` explicitly or anchors its pathspec
at the repository root, so `validate-changeset.sh` was the only unanchored
reader — the sweep is the evidence for that, not the conclusion assumed from
one green run. `run-secretlint.sh` deliberately *does* scan `dev/log/`, because
downloaded CI logs are exactly where a leaked token would land. The one
remaining unanchored match is `release.yml`'s `paths: ['.changeset/**']`
trigger, which is a GitHub path filter anchored at the root by GitHub's own
semantics and can only over-trigger a run, never fail one.

**Coverage.** Six assertions in `experiments/test-issue123-pr-diff-range.sh`: a
nested `.changeset/` belonging to another project is reported as *no* changeset
rather than an invalid one, the gate never names the foreign file, a foreign
changeset beside a valid own one does not fail the release, a file below
`.changeset/` is not validated because it is not applied, `apply-changesets.sh`
still reads only the top level, and the shipped pattern is still anchored. The
assertions are written against a generic nested directory rather than against
`dev/log/`, because the anchor is what makes them right.

---

## Considered and declined — census lines that are not defects

Every one of these is a `warn`/`error` line in the nine runs. Each was measured,
and each is left alone. Recording them matters as much as the fixes: the next
sweep should not have to rediscover them, and "we looked and it was fine" is only
worth anything with the measurement attached.

| Census line | Occurrences | Why it stays |
|---|---|---|
| `Warning: /home/linuxbrew/.linuxbrew/bin is not in your PATH.` | 2 | True when printed and answered three lines later: `ubuntu/24.04/php/install.sh:76-94` runs the Homebrew installer, then `eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"` immediately, appends the same line to `~/.bashrc`, and `full-box/Dockerfile:242` sets `ENV PATH`. The installer cannot see any of that. |
| `WARNING: seems you still have not added 'pyenv' to the load path.` | 2 | Same shape: `ubuntu/24.04/python/install.sh:28-55` — answered by lines 31–41 (`.bashrc`) and 51–55 (the current session). |
| `update-alternatives: warning: skip creation of …` | ~40 | Debian packaging, inside `apt-get install`, about man pages of link groups whose primary is not installed. Not ours to fix, not actionable, and suppressing it would need `-o Dpkg::Options` covering unrelated output. |
| CodeQL `ExtractionWarnings` / `ExtractionErrors` lines | 12 | These are **query files being loaded and evaluated**, not findings. The run reported `Found 0 raw diagnostic messages.` and `CodeQL scanned 19 out of 19 GitHub Actions files and 18 out of 18 JavaScript files`, `3 out of 3 Python files` — so this is *not* the "scanned nothing and passed" false negative it could have been, which is precisely why it was checked rather than skimmed. |
| `notice … Summary report available at: …#summary-102518098621` | 1 | `lycheeverse/lychee-action` emits it with `core.notice` when `output:` is set. It reports where the report is, on a job that passed. The only way to remove it is to stop asking lychee for a report. |
| `curl -sL 'https://go.dev/VERSION?m=text' \| head -n1` | 2 | Looks like RC-6 and is not: the endpoint returns **35 bytes in one write**, so `head` cannot close the pipe mid-write. Both sites are planted in `test-issue123-sigpipe-writers.sh` as fixtures that the sweep must **not** flag. |
| `assertion` / `action-help` / `step-script` classes | 633 | The word appearing in a script's own text, an action's `--help`, or a test name (`test-issue104-vfs-warning.sh`, `run-with-budget-warning.sh`, `Checked 270 tracked files … (warning at 1350)`). Classified by `census-warnings-errors.sh` before the classes that can hold a defect, so a real line cannot hide in them. |

**apt hardening, declined with a measurement.** RC-1's 60-minute overrun invited
an obvious "add retries and timeouts to apt". `../apt/README.md` measures apt's
own defaults on the full box: `Acquire::Retries` is already at least as high as
the value `apt_update_with_retry` pins (3 retries here and in `ubuntu:24.04`, 1
on the `ubuntu-24.04` runner — so the pin is a no-op in the images and a
strengthening on the runner, never a downgrade), and
`Acquire::http::Timeout` bounds an **idle** connection — the mirror in question
was delivering at 20 kB/s, never idle, so no value of that option would have
helped. Shipping it would have been a change that looks like a fix and prevents
nothing.

**Dead code, recorded rather than removed.** `ensure_box_user` and
`is_docker_build` are the only 2 of 32 functions in `ubuntu/24.04/common.sh` with
no caller anywhere in the tree. Not a CI defect and not in scope for this issue;
noted here so the observation is not lost, and left in place because
`ensure_box_user` is where RC-10's skel restore lives and removing it would drop
the fix from the file most likely to be copied next.

## Roads not taken

| Instead of | We could have | Why not |
|---|---|---|
| RC-1's process-table liveness check | raised `timeout-minutes` | Makes the symptom rarer and the report no truer. |
| RC-2's per-job question | compared against the branch head at run-creation time | Passes this run; still excuses a genuine overrun in any run older than one push. |
| RC-3's `stop-commands` | stripped `##[` from the commit message | The message *is* the documentation of the defect; rewriting it is a second false report. |
| RC-5's failing banner | `--no-online-audits` | Honest about being narrower, and silently drops `known-vulnerable-actions`. |
| RC-6's bounded readers | `\|\| true` or `2>/dev/null` | Hides a real producer failure, or hides the line and keeps the status. |
| RC-7's step-outcome condition | `if-no-files-found: error` alone | Makes every early job failure fail twice, the second time misleadingly. |
| RC-10's `useradd -M` plus selective restore | moved the `WORKDIR` below the `useradd` | Measured: leaves the non-interactive login shell UNSET, and adopting skel's `.bashrc` breaks `entrypoint.sh`. |
| RC-11's helper | `set -o pipefail` on the existing pipelines | Fixes the status and not the message: the caller still cannot say *why* the range failed, which is what cost a re-run. |

## Where each of these came from, and where it went

* Evidence for every claim: `../ci-logs/`, `../runs/`, `../annotations/`,
  `../zizmor/`, `../apt/`, `../useradd/`, `../npm-force/`.
* The sequence that made RC-2 fire on this push: `TIMELINE.md`.
* The requirement each fix discharges: `REQUIREMENTS.md`.
* Existing components weighed before writing anything: `PRIOR-ART.md`.
* The same defects in the seven templates, and the 20 reports filed:
  `../upstream/README.md`.
