# Case Study: Issue #123 — Eight green runs, and thirteen checks that did not know what they were reporting

## Executive Summary

[Issue #123](issue.md) names nine CI/CD runs on `main` at commit `1d9fb3e` and
asks for "all false positives, false negatives, warnings and errors" in them.
**Eight of the nine were green.** The ninth was cancelled by
`timeout-minutes: 60` — and its own status gate concluded `success` anyway.

The scope was measured before it was worked: `census-warnings-errors.sh`
classifies all **804** lines in those nine runs that contain `warn` or `error`,
and the API reports exactly **7** annotations across all nine. Three of the seven
were false. Thirteen root causes came out of the census and out of sweeping for
the siblings of each one; **six of the thirteen were found in the eight green
runs** (RC-3, RC-5, RC-6, RC-7, RC-8, RC-10). A red run tells you where to look.
A green run does not, which is why this issue is a census and not a gate.

One sentence covers every row below: **each of these is a check that reported a
verdict about data it never obtained.**

| # | Finding | Where it showed | Root cause | Resolution |
|---|---|---|---|---|
| RC-1 | A budget annotated `…did not finish within its 2400s budget and was terminated` — and the step ran for **19 m 21 s** more | run [34366975927](https://github.com/link-foundation/box/actions/runs/34366975927), `Measure Component Disk Space` | `kill -0` fails with **exit 1 for both** EPERM ("alive, not yours to signal") and ESRCH ("gone"). The survivors were root-owned `apt-get` children of a `sudo`; the wrapper read them as finished, skipped its SIGKILL escalation, and exited 124. They also held the step's stdout — the pipe into `tee` — so the step could not end. | `run-with-budget-warning.sh` reads liveness from `/proc`, escalates SIGTERM → SIGKILL → SIGKILL under `sudo`, names any survivor in an `::error`, and relays the command's output so a survivor cannot hold the step open. `eacba67` |
| RC-2 | `##[warning]…This run is no longer the head of main, so the cancellation reads as a supersede` — on a job no supersede can reach | same run, gate job | `check-pipeline-status.sh` asked one question of the **run** and let the answer excuse every cancelled **job** in it. `measure-disk-space.yml` declares `cancel-in-progress: false`. And the run really was displaced — by a sibling job of its own push, 21 seconds after creation, which every release does. | `read-job-cancel-in-progress.sh` reads the effective value out of the workflow file `GITHUB_WORKFLOW_REF` names; a cancellation is excused only when the run is not the head **and** that job's value is `true`. Everything unreadable fails closed. `6a46916` |
| RC-3 | A `failure` annotation on a job that concluded `success` | run [34366976358](https://github.com/link-foundation/box/actions/runs/34366976358), `Apply Changesets` | `git commit` echoes the message it just recorded; the message is changeset text a pull request wrote; release 2.9.0's notes quoted `##[error]` while explaining issue #121's log injection; the runner's `ActionCommand.TryParse` accepts `##[` **anywhere** in a physical line. | `run-with-commands-stopped.sh` brackets a child's output with `::stop-commands::<fresh 128-bit token>` and always resumes. **15 call sites.** `4139d54` |
| RC-4 | A log that was written and then destroyed | found sweeping for RC-3's printers | `output="$(cmd 2>&1 \| tee /dev/stderr)"` — `/dev/stderr` is `/proc/self/fd/2`, so `tee` **reopens** the file behind fd 2 with `O_TRUNC`. Harmless when fd 2 is a pipe (a step), destructive when it is a file (a wrapped command, a local run). | `capture-and-stream.sh` tees into a temp file and streams through `>&2` — a duplicate of the descriptor, not a reopen. Four sites. `4139d54` |
| RC-5 | `WARN audit: zizmor is running in offline mode` on a green run reporting "no findings" | run [34366975873](https://github.com/link-foundation/box/actions/runs/34366975873) | zizmor is offline without a token; both passes were `docker run` without `-e GH_TOKEN`, and docker forwards no environment. Every online audit was skipped, `known-vulnerable-actions` among them — the one that can catch a supply-chain compromise of an action already trusted here. Measured over a `tj-actions/changed-files@v44` fixture: offline 7 findings, online 8, and 2 `known-vulnerable-actions` hits only online. | `run-zizmor.sh` pins image, floors and targets, passes the token by name, and **treats the offline banner as a failure**. `ZIZMOR_ALLOW_OFFLINE=1` for a local run; the suite asserts no workflow sets it. `82656ba` |
| RC-6 | `tr: write error: Broken pipe`, `grep: write error: Broken pipe` on two passing jobs | runs 34366975942 and 34366976358 | The runner starts a step's shell with SIGPIPE set to `SIG_IGN`, and bash passes an inherited `SIG_IGN` to the commands it starts — so `producer \| head` does not die silently: EPIPE, a stderr line, and under `pipefail` a non-zero pipeline. Upstream since 2023: [actions/runner#2684](https://github.com/actions/runner/issues/2684), still open. | Bound the **reader** at both sites so the writer reaches EOF: a bounded `/dev/urandom` loop in `run-secretlint.sh`, one `awk` that keeps the first match and still reads the 330 kB feed to EOF in `common.sh`. `2bc0814` |
| RC-7 | `if-no-files-found: warn` — an upload that could not fail | run [34366975837](https://github.com/link-foundation/box/actions/runs/34366975837) | The one outcome the step exists to prevent — the only record of a run not being kept — was reported as a line in the log of the run whose record is missing. `error` alone is wrong, because `if: ${{ !cancelled() }}` is also true when the job failed before the producing step ran. | Narrow the question, then require files: `steps.<id>.outcome == 'success' \|\| 'failure'` (positive form — the `steps` context holds only steps that ran) plus `if-no-files-found: error`. `cd25f22` |
| RC-8 | `npm warn using --force Recommended protections disabled.` on every JS build job | run 34366976358 | `--force` had ridden on the Playwright install since issue #84. Both plausible reasons (a bin conflict, the retry re-running over a partial tree) were tested on both images, fresh and re-install, before and after `npm install -g npm@latest`: **twelve runs**, twelve `exit=0`, twelve `Version 1.63.0`. | The flag is gone. `2b9fa1e` |
| RC-9 | Three invisible failure modes of `brew link` | found sweeping for RC-8's siblings | `brew link … 2>&1 \| grep -v "Warning" \|\| true` — a pipeline's status is its last command's, so what was tested was grep's opinion of the text, and `\|\| true` discarded even that. A failure that said why, a failure that said only `Warning:`, and the issue #53 hang's `timeout` 124 were all silent. | All four sites keep the filter on the output and the status on brew; a failure prints everything brew said, warnings included. `c151dd5` |
| RC-10 | `useradd: warning: the home directory /home/box already exists. Not copying any file from skel` | both JS build jobs | `WORKDIR /home/box` stands above the `useradd`, and Docker creates a `WORKDIR` that is not there. `useradd -m` populates from `/etc/skel` **only when it creates the directory**. No skel means no `~/.profile`, which is what sources `~/.bashrc` for a login shell — so every descendant image shipped a `box` user whose `ssh`, `su - box` and `bash -l` saw none of the PATH the install scripts append. | `useradd -M`, `.profile` and `.bash_logout` restored explicitly, `.bashrc` deliberately **not**, chown made recursive. The only one of four measured variants with no `UNSET` in any column. Five sites. `09549d9` |
| RC-11 | Three release gates read a failed `git diff` as "nothing changed" | found by taking upstream report **F** to our own tree | `git diff --name-only "origin/$BASE...HEAD"` exits **128 and prints nothing** when the range does not resolve — no `fetch-depth: 0`, a renamed base, a failed fetch, no merge base — and all three discarded the status. Two `gh` reads conflated "empty" with "failed". Reproduced: two of the three gates report the passing verdict. | `scripts/release/pr-diff-range.sh` — one place that asks what a pull request changed, three-dot, restores a base ref missing only locally, otherwise names the cause on **stderr** and returns 1. `45abc52` |
| RC-12 | The changeset gate demanded a changeset for the wrong set of paths | surfaced by extracting RC-11's inline step | `VERSION`, `.github/actions/` and `.githooks/` were absent from the regex, and the step echoed pull-request-controlled paths with command processing live — RC-3 inside our own workflow, two files from a script already doing it correctly. | `check-changeset-required.sh`, with the widened path set and the printer bracketed. `45abc52` |
| RC-13 | This branch's own template comparison came out with its summary lines in it, as roles | found by reading the matrix it produced | `compare-template-roles.sh` wrote `/tmp/roles-<name>.txt` and read them back with `cat /tmp/roles-*.txt`, which also matched `/tmp/roles-all.txt` from the same run. | A private `mktemp -d` with a trap, and a comment at the site. `320491d` |

Two of the thirteen are the shape inverted rather than repeated: RC-3 is text
that was **not** a verdict being read as one, and RC-4 is a record that existed
and was then erased. The other eleven are all the same defect — a verdict about
data the checker never had.

---

## 0. What was measured, and how

Nothing here is inferred from a workflow file alone. The evidence is
`dev/log/issues/123/pulls/124/` (7.4 MB, 494 files), and every number in this
document comes out of it:

| Directory | What it holds |
|---|---|
| `ci-logs/` | all nine run logs and all 99 job logs of the release run, gzipped |
| `runs/` | `*.run.json` and `*.jobs.json` for each of the nine |
| `annotations/` | all 7 annotations with their surrounding log lines |
| `analysis/` | the census of all 804 `warn`/`error` lines, the timeline, the root causes, the requirement list, the prior-art survey, the best-practices re-measurement, the git-read sweep |
| `templates/` | pinned snapshots of all seven template repositories and the role matrix over them |
| `upstream/` | the body of every report filed, and `filed/index.tsv` |
| `zizmor/`, `apt/`, `useradd/`, `npm-force/` | the four standalone measurements the decisions rest on |

Two properties of the collection matter more than its size:

* **It records what it could not get.** `collect-ci-evidence.mjs` stores a log it
  fails to fetch as `LOG UNAVAILABLE: <the error>`, not as an empty file. Eight
  of the nine run-level logs carry real content; the ninth is that recorded
  refusal, because `gh run view --log` declines a 99-job run — which is why the
  99 job logs were collected individually. A collector that silently wrote an
  empty file would have been the fourteenth root cause.
* **Every sweep is mutation-tested.** A sweep that finds nothing is worth nothing
  until a planted offender makes it fail. Each suite plants one.

---

## 1. The 21 seconds that produced a false positive

The full reconstruction is `dev/log/issues/123/pulls/124/analysis/TIMELINE.md`;
this is the causal core of it.

| time (UTC, 2026-09-09) | event |
|---|---|
| 14:56:47 | `1d9fb3e` committed |
| 14:56:51 | all **nine** runs created, every one at `1d9fb3e` |
| 14:57:06 | release run 34366976358 starts its own `Apply Changesets` job |
| 14:57:11.232 | the runner turns the commit message into a `failure` annotation (RC-3) |
| **14:57:12.641** | that job pushes `1d9fb3e..1e202f5  HEAD -> main` |
| 15:25:47.393 | `##[warning]disk space measurement has run for 1680s of its 2400s budget` — true |
| 15:37:47.616 | `##[error]…did not finish within its 2400s budget and was terminated` — false (RC-1) |
| 15:57:08.279 | `##[error]The operation was canceled.` — `timeout-minutes: 60`, 19 m 21 s later |
| 15:57:18 | the gate excuses the cancellation as a supersede (RC-2); the run concludes **`success`** |

The run was not the head of `main`. It was displaced by **a sibling job of its
own push**, 21 seconds after being created — and every release does this,
because applying changesets is what the release workflow is *for*. The supersede
excuse issue #121 added was not defeated by an unlucky race; it was defeated by
the ordinary operation of the pipeline it guards.

**Two independent false verdicts stacked into a silent failure.** RC-1 said it
had handled the overrun; RC-2 said the overrun was somebody else's push. Either
one alone would have left a red run. Together they produced a green one.

The 60-minute overrun itself is **not** a repository defect: 25.6 MB in 21 m 24 s
(≈20 kB/s) from `azure.archive.ubuntu.com`, on a job whose `apt-get update` in
the same minute reported `Fetched 9435 kB in 1s (8809 kB/s)`.

---

## 2. The apt hardening that was declined with a measurement

RC-1's overrun invites an obvious "add retries and timeouts to apt". It was
measured instead of shipped (`dev/log/issues/123/pulls/124/apt/`):

* `Acquire::Retries` is already set — apt 2.8.3's default is **3**, confirmed by
  counting connections to a local fixture mirror at 0, 1, 2, 3 and 5 retries
  (2, 4, 6, 8, 12 connections for 2 index items).
* `Acquire::http::Timeout` bounds an **idle** connection. The mirror in question
  was delivering, slowly. Measured: `Timeout=5` gives up after 10 s of silence,
  `Timeout=30` after 60 s — and never fires against a slow producer.

So no value of either option would have helped, and shipping them would have
been a change that looks like a fix and prevents nothing. That is the entry
this case study is proudest of: the issue is about checks that claim more than
they measured, and the same standard has to apply to the fixes.

Seven more census lines were dispositioned the same way and left alone — the
Homebrew and pyenv PATH warnings (both answered three lines later in the same
script), ~40 `update-alternatives` lines from Debian packaging, twelve CodeQL
`ExtractionWarnings` lines that are query files being **loaded**, not findings
(the run reported `19 out of 19 GitHub Actions files` scanned, so this was
checked rather than skimmed), lychee's `notice` saying where its report is, and
two `curl … | head -n1` sites that look exactly like RC-6 and are not, because
the endpoint returns 35 bytes in one write. Both are planted in the SIGPIPE
suite as fixtures the sweep must **not** flag.

---

## 3. Applying each fix everywhere it belongs

The task's instruction — *"if an issue exists in multiple places, apply it in
all of them"* — is the one most easily satisfied in appearance. Every fix on
this branch therefore ships a repository-wide sweep, in its own suite, with a
planted offender:

| Defect | Sites | Sweep |
|---|---:|---|
| `brew link … \| grep -v Warning \|\| true` | 4 | `test-issue123-brew-link-status.sh` |
| `useradd` meeting an existing home | 5 (1 Dockerfile + 4 shell) | `test-issue123-home-skel.sh` |
| unbounded writer into an early-exiting reader | 2 fixed, 3 safe sites named | `test-issue123-sigpipe-writers.sh` |
| PR-authored text printed with commands live | 10 fixed, 15 call sites now | `test-issue123-log-command-injection.sh` |
| `tee /dev/stderr` | 4 | `test-issue123-log-capture-truncation.sh` |
| `git diff …BASE…HEAD` with the status discarded | 3, plus 2 `gh` reads | `test-issue123-pr-diff-range.sh` |
| `if-no-files-found: warn` | 2 | `test-issue123-artifact-upload-fail-closed.sh` (workflows **and** composite actions) |
| `npm … --force` | 1 | `test-issue123-npm-force.sh` |
| zizmor without a token | 3 | `test-issue123-zizmor-token.sh` |
| supersede excusing a cancellation | 1 script, asked of all 31 jobs | `test-issue123-overrun-not-supersede.sh` |

A 24th site where a git or `gh` read could be mistaken for an answer cannot
appear unnoticed either: the remaining **23** are listed one by one with their
dispositions in `analysis/git-read-failure-sweep.md`, every one already erring in
the strict direction, and the production query is itself an assertion.

---

## 4. The verbose mode, default off

The task asks for debug output "if there is not enough data to find the actual
root cause… keep the default state switched off". Twelve of the thirteen root
causes were found in the evidence as collected. The thirteenth question — *what
did this pull request change, and how did the answer get computed?* — is the one
where a future failure would leave nothing behind, because the failing path
already explained itself and the **succeeding** path did not.

`PR_DIFF_RANGE_VERBOSE=1`, or `BOX_VERBOSE=1` repository-wide, makes every answer
carry the base ref it resolved, whether that ref had to be fetched, the range and
merge base it diffed, and how many paths came back. Default off, on **stderr**
(every caller reads the helper through a command substitution), and printed
through `run_with_commands_stopped`, because a branch name is not text this
repository writes. Nine assertions cover it.

---

## 5. What was filed upstream

Six defect classes, twenty deliveries: **19 new issues** across six template
repositories and **1 comment** on an existing one. Each body carries a
reproduction fixture that runs offline against a pinned template checkout, a
workaround, and the fix in diff form.

| Class | What it is | Filed |
|---|---|---|
| A | `check-pipeline-status.sh` excuses every cancellation in a superseded run, including jobs a supersede cannot reach | js#186, python#80, rust#171, php#14 |
| B | `run-with-budget-warning.sh` reports a command as finished while its children keep running (`kill -0` cannot tell EPERM from ESRCH) | js#187, python#81, rust#172, php#15 |
| C | pull-request-authored text printed to the CI log unbracketed | js#188, python#82, rust#173, csharp#60, go#7, java#7 |
| D | the same, from a `workflow_dispatch` input | go#8, java#8, csharp#53 (comment) |
| E | a template exec-injection variant found in the C# tree | csharp#61 |
| F | release checks that swallow a failed `git` read | java#9, rust#174 |

Every URL is in `dev/log/issues/123/pulls/124/upstream/filed/index.tsv`, and
prior art for A and B — the four closed issues that *added* those scripts — is
cited in each report, because the new claim is narrower: the second question has
to be asked of the job, not of the run.

---

## 6. The template comparison, and the best practices

Issue #123 asks to compare the **full file tree** against the templates. That was
done against **seven** repositories rather than the two named, because the same
role is often spelled differently in each and one template alone cannot tell a
missing practice from a naming difference: a **role matrix** over 160 script
roles and 17 workflow roles, with all **91** roles box does not have
dispositioned individually (`templates/COMPARISON.md`). The revisions are pinned
in `SNAPSHOT.txt`, so the next comparison starts from a fixed state — three of
them are the same commits issue #121 compared, which is what makes the two
comparisons composable.

The sixteen hive-mind CI/CD best practices were **re-measured**, not inherited:
each row of `analysis/BEST-PRACTICES-VERIFICATION.md` is a command that was run,
against the copy of the practices document stored beside it at commit
`f19f9f7a`. Issue #121 assessed the same sixteen; repeating the assessment rather
than citing it is the point, since this issue's whole subject is checks that
report a state they never verified. Fifteen are held, one (`audit the dependency
tree`) is n/a with the measurement attached.

---

## 7. The suites, and the two that failed on themselves

Twelve offline suites, **327 assertions, 0 failures**, each checker exercised in
a passing *and* a failing form:

| suite | assertions | | suite | assertions |
| --- | ---: | --- | --- | ---: |
| `pr-diff-range` | 62 | | `home-skel` | 23 |
| `zizmor-token` | 36 | | `log-capture-truncation` | 23 |
| `overrun-not-supersede` | 35 | | `budget-enforcement` | 20 |
| `sigpipe-writers` | 30 | | `brew-link-status` | 16 |
| `artifact-upload-fail-closed` | 29 | | `npm-force` | 14 |
| `log-command-injection` | 29 | | `apt-retry-defaults` | 10 |

(`apt-retry-defaults` reports 10 by default; three further legs measuring idle
timeouts cost ~130 s and sit behind `APT_MEASURE_TIMEOUTS=1`, with their recorded
output in `apt/`.)

Two of these suites failed on their first full run **for exactly the defect this
issue is about**, and both failures are worth more than the fixes:

* **`brew-link-status` matched its own text.** The sweep for `brew link … | grep`
  found a hit — in the suite's own `RETIRED=` fixture string. A sweep that can
  match itself is a check reporting a verdict about data it did not intend to
  read. It now carries a named `declare -A BREW_FIXTURES` allowlist, asserts each
  allowlisted path **exists** (so a renamed fixture cannot silently widen the
  allowlist), and plants two mutation fixtures: an offender that must produce
  exactly 2 matches, and a compliant one that must produce 0.
* **`apt-retry-defaults` read its count before the data was in.** A fixed
  `sleep 0.5` is a guess about scheduling, not a wait; and the fixture server
  reset each connection the moment it was accepted, racing apt's own write. Under
  four CPU busy loops the same leg reported 12, 8 and 4 connections on three
  consecutive runs. It is a quiescence loop now — poll until the total stops
  moving for five consecutive polls — and the server reads the request first,
  then resets, one thread per connection. Verified by running the suite six times
  under four busy loops: `Passed: 10  Failed: 0` on all six.

RC-13 belongs to the same group: a measurement of this branch's own, contaminated
by a glob. Three defects of the issue's own class, in the instruments built to
measure it.

---

## 8. The requirement list, item by item

The full table, with the falsifiable check for each row, is
`analysis/REQUIREMENTS.md`. In summary:

| Requirement | Where it landed |
|---|---|
| "check for all false positives, false negatives, warnings and errors… and fix them all" | all 804 `warn`/`error` lines classified (`analysis/warnings-errors.census.md`), every distinct one dispositioned — thirteen fixed, eight left alone with the measurement attached (§2) |
| the nine runs, including the cancelled one | `ci-logs/` (nine run logs + all 99 jobs of the release run), `runs/`, `annotations/` |
| "use all the best practices from CI/CD templates (check full file tree)" | the role matrix over seven templates, 91 gaps dispositioned individually (§6) |
| "if the same issue is found in template, report issue also in templates" | 19 issues + 1 comment, six classes, each with a fixture (§5) |
| "compare all files, so we don't have more CI/CD errors in the future" | the comparison is snapshot-pinned, so the next one starts from a fixed revision |
| "follow the CI/CD best practices collected in hive-mind" | all sixteen re-measured, each with the command behind the verdict (§6) |
| "download all logs and collect data into `dev/log/issues/123/pulls/124`" | 7.4 MB across ten directories, indexed by `README.md`, with unavailable logs recorded as unavailable (§0) |
| "reconstruct the timeline" | second-resolution, from the run records and job logs (§1) |
| "find the root cause of each problem" / "propose possible solutions" | `analysis/ROOT-CAUSES.md` — mechanism first, fix second, alternatives considered for each, and a "Roads not taken" table for the seven declined with a reason |
| "check online for known existing components/libraries" | `analysis/PRIOR-ART.md` — §9 below |
| "add debug output and a verbose mode… default off" | §4 |
| "if an issue exists in multiple places, apply it in all of them" | §3 |
| "plan and execute everything in this single pull request" | PR #124; 18 commits, no second branch, no follow-up issue against this repository |

Two things the first row needs stated plainly, because the issue's title invites
a count and a count is the wrong instrument. **Seven annotations, not "all
warnings":** the annotation API sees only what a tool emitted as a `##[…]`
command or what the runner itself failed, so the requirement is discharged
against the logs, not the endpoint. **And a green run is the interesting case:**
eight of nine were green, and six of the thirteen root causes are in them.

---

## 9. Existing components, and what was written instead

Nothing here was written before looking for something that already did it.
**Three of the thirteen fixes are an existing component**; the rest are not, and
`analysis/PRIOR-ART.md` says why for each.

| Need | Existing component | Verdict |
|---|---|---|
| Stop a log injection | GitHub's own `::stop-commands::` | **Adopted** — with a fresh 128-bit token per invocation, because the token is visible in the log and every call site prints text that is already fixed when the token is chosen |
| An analyser that reads the GitHub Advisories database | zizmor's online mode | **Adopted**, correctly: the missing part was never a tool but a policy — *an analyser that skipped its online audits must not report success* |
| An upload that fails when there is nothing to upload | `if-no-files-found: error` | **Existing option, wrong value** — plus a condition narrow enough for `error` to be right |
| Bound a long step and kill what survives | `timeout(1)` | **Used, and insufficient**: `--foreground` does not time out children, and the default mode kills the group — but the survivors were in the group *and* root-owned, so a runner-uid kill fails with EPERM either way |
| Ask whether a job could have been superseded | nothing | The value is in no context GitHub exposes at run time, which is exactly why the gate asked a question it *could* answer instead of the one it needed |
| Capture while streaming | `moreutils`, process substitution | Nothing to adopt; a footgun to stop using |
| "What did this pull request change?" | `dorny/paths-filter`, `tj-actions/changed-files` | **Declined with reasons**: three of the four callers are shell scripts that also run locally and in the pre-commit hook, where no action can run; and `changed-files`' own compromise ([CVE-2025-30066](https://nvd.nist.gov/vuln/detail/CVE-2025-30066)) is the fixture RC-5's measurement uses. The repository's `detect-changes.sh` had already answered this correctly — the fix is making the other three files agree with the one that was right |
| Fail a run that carries warning annotations | searched; **nothing exists** | Warnings do not affect a job's conclusion, and the [feature request](https://github.com/orgs/community/discussions/156778) is open. That absence is why this issue is a census rather than a gate |

The one upstream report that decides the most is
[actions/runner#2684](https://github.com/actions/runner/issues/2684) — "Action
runner ignores SIGPIPE" — open since 2023, labelled `bug`, no maintainer
response. It confirms RC-6 is not a local misconfiguration, so bounding the
reader is the right fix; and it is *still open*, which is why the fix does not
wait for it.

---

## 10. Still outstanding

- **RC-2's fix is bounded by what a workflow file can say.** A job whose
  `concurrency` value is an expression, or that the workflow does not declare,
  fails closed — one noisy error rather than a silent pass. That is the right
  bias and it is still a limitation.
- **Two dead functions are recorded rather than removed.** `ensure_box_user` and
  `is_docker_build` are the only 2 of 32 functions in `ubuntu/24.04/common.sh`
  with no caller. Not a CI defect and not in scope; `ensure_box_user` is where
  RC-10's skel restore lives, so removing it would drop the fix from the file
  most likely to be copied next.
- **The 20 upstream reports are delivered, not merged.** Each carries a
  reproduction and a diff; none of them is in this repository's control.
- Nothing here rewrites an annotation that is already published. The seven
  annotations of these nine runs stay as they are; what changes is what the next
  release run produces.
