# Case Study: Issue #123 — Eight green runs, and twenty checks that did not know what they were reporting

## Executive Summary

[Issue #123](issue.md) names nine CI/CD runs on `main` at commit `1d9fb3e` and
asks for "all false positives, false negatives, warnings and errors" in them.
**Eight of the nine were green.** The ninth was cancelled by
`timeout-minutes: 60` — and its own status gate concluded `success` anyway.

The scope was measured before it was worked: `census-warnings-errors.sh`
classifies all **804** lines in those nine runs that contain `warn` or `error`,
and the API reports exactly **7** annotations across all nine. Three of the seven
were false. Nineteen root causes came out of the census, out of sweeping for
the siblings of each one, out of the first CI run of the finished branch — which
found the same defect in the tests written to measure the others — and out of
asking the census question of the branch's own gates and release path;
**six of the twenty were found in the eight green runs** (RC-3, RC-5,
RC-6, RC-7, RC-8, RC-10). A red run tells you where to look. A green run does
not, which is why this issue is a census and not a gate.

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
| RC-14 | A suite asserted apt's default retry count **equals** 3, and failed the branch on a runner where it is 1 | this branch's own `scripts / regression suites` job | `test-issue123-apt-retry-defaults.sh` pinned the spelling of an environment's constant. apt 2.8.3 defaults to 3 retries here and in `ubuntu:24.04` and to **1** on `ubuntu-24.04`, on the same Ubuntu 24.04.4; nothing in this repository depends on the number. | The invariant is a direction, not an equality: `-o Acquire::Retries=3` must never be a *downgrade*. The suite derives the default from its own connection count, prints `apt-config dump`, the apt.conf files naming the key, `APT_CONFIG` and whether `apt-get` is a wrapper, and sweeps all 137 tracked sources for a refresh that passes no retry option. |
| RC-15 | A suite's "SIGPIPE at its default" leg was whatever the machine was doing, and on a runner that is *ignored* | this branch's own `scripts / regression suites` job | `test-issue123-sigpipe-writers.sh` established one leg with `trap '' PIPE` and left the other to inherit. A step's shell starts with SIGPIPE `SIG_IGN` (actions/runner#2684 — the suite's own subject), an ignored disposition survives `exec`, and bash cannot reset one. Both legs were the same leg. | The default leg enters through `perl -e '$SIG{PIPE} = "DEFAULT"; exec …'` (`python3` where perl is absent), and a new part reads each leg's `SigIgn` mask out of `/proc/self/status` and asserts bit 13 — so the premise fails loudly instead of the conclusion failing mysteriously. |
| RC-16 | A fake `ps` fabricated an unkillable survivor that died with the process group it was standing in for | this branch's own `scripts / regression suites` job | `test-issue123-budget-enforcement.sh` faked a survivor for every process group **currently in the table**, so the lie was conditional on the truth: once SIGTERM took the real group, `group_members` returned empty and the wrapper correctly reported no survivors. Three assertions blamed the shipped wrapper for a race in the fixture. | The fake records every group id it has ever seen in a per-leg state file and re-reports all of them: an unkillable process is one that does not go away, and a stand-in for it must not either. |
| RC-17 | A linter reported a clean tree over 201 shell scripts it never opened | one red assertion in a full run of this branch's own experiment suites | `collect_files()` ended in `\| sort -u \|\| true`, so **any** failure of `git ls-files` — a busy index, an unreadable object, no `git` — became an empty list, and the gate read that as a fact about the repository. Measured against the shipped script with a `git` exiting 128: `==> No shell scripts to check`, status 0. Five of the eight gates that discover their own inputs ended their listing in that `|| true`, and the other three built theirs inside a process substitution, where a failure is equally invisible. Five of the eight already refused an *empty* set — which answers the second failure mode and says nothing about the first. | Every discovering gate separates "git could not answer" from "git answered, and there is nothing", and errors on each by name. `test-issue123-discovery-fail-closed.sh` drives all eight through both failures, and the hook driver that runs them, 94 assertions. |
| RC-18 | Eighteen release steps each re-derived the version being published, by reading a file | asking the census question of the release path instead of a linter | `VERSION=$(tr -d '[:space:]' < VERSION)`, three times in each of the six release workflows, sixteen of them behind `git pull origin main \|\| true`. An empty file is caught by nothing: `[] status=0`. In a build job it becomes the tag `…box-js:-amd64`; in the two bump jobs it becomes `$((MAJOR + 1))` over an empty string, which publishes **1.0.0** — below every version this repository has released. | One reader. `detect-changes` already published `version` and every call site already passed `changes:`, so `fromJSON(inputs.changes)['version']` was there all along; `scripts/release/release-version.sh` prefers it, cross-checks the file, refuses an empty or malformed value from either, and warns when the two disagree. |
| RC-19 | An unparseable workflow passed all four gates whose entire input is workflow files, each printing a confident verdict about it | a break this branch itself committed, caught by four experiment suites and by none of the eleven gates the hook runs | Three replaced steps left an orphan `echo` stranded, and `release-full.yml` stopped being YAML (`Psych::SyntaxError … line 175 column 33`). The four gates read workflows line by line **on purpose** — they ask about ordering and indentation a parsed tree discards — and a line-oriented reader cannot tell a file it disagrees with from a file no parser accepts. actionlint does catch it, and is pinned as `docker://`, which a pre-commit hook cannot run. | `check-workflow-yaml.sh` parses every tracked workflow and composite action with ruby's `psych` — the only offline parser present here — first in the hook and first in `workflows.yml`. The floor, not the ceiling: an orphan line with no colon is a legal plain-scalar continuation, and that limit is stated at the site and asserted in the suite. |
| RC-20 | A gate failed the whole release over a changeset belonging to another repository | this branch's own release run, 34435214054 | `validate-changeset.sh` selected its subject with `grep "^A.*${CHANGESET_DIR}/.*\.md$"` — no anchor, so `.changeset/` matched at any depth — while `apply-changesets.sh` and `check-changesets.sh` both read exactly `find .changeset -maxdepth 1`. The pinned template evidence this issue asks for carries six other projects' `.changeset/` directories, written in the changesets npm format, and the gate declared one of them an `Invalid changeset format`: true about the file, false about this repository. | The pattern is anchored at the repository root at the consumer's depth, the status/path split is `awk -F'\t'`, and the loop reads lines rather than words. Anchoring is the general fix, not an exclusion of `dev/log/` — and every other discovering gate was re-measured against the same evidence tree: 1355 inputs across ten gates, 0 of them under `dev/log/`. |

Two of the twenty are the shape inverted rather than repeated: RC-3 is text
that was **not** a verdict being read as one, and RC-4 is a record that existed
and was then erased. The other seventeen are all the same defect — a verdict
about data the checker never had. Four of those seventeen — RC-13 through RC-16
— are in code this branch wrote to measure the others, which is §7. The last
three arrived later still, from three directions: one red assertion in a full
experiment run (RC-17), the census question asked of the release path rather
than of a linter (RC-18), and a break this branch itself committed, which four
workflow-reading gates each passed while describing it (RC-19). RC-20 came from
the branch's own release run, and is the same question asked one step further
out: not "did the check read its input?" but "was that input its subject?".

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
  empty file would have been one more root cause of exactly this shape.
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

* `Acquire::Retries` is already at least as high as the pin. Counting
  connections to a local fixture mirror at 0, 1, 2, 3 and 5 retries gives 2, 4,
  6, 8 and 12 for 2 index items, everywhere it has been run; apt's *default*
  gives 8 here and inside `ubuntu:24.04` (3 retries) and 4 on the `ubuntu-24.04`
  runner (1 retry). The pin is therefore a no-op in the images and a
  strengthening on the runner, never a downgrade.
* `Acquire::http::Timeout` bounds an **idle** connection. The mirror in question
  was delivering, slowly. Measured: `Timeout=5` gives up after 10 s of silence,
  `Timeout=30` after 60 s — and never fires against a slow producer.

So no value of either option would have helped, and shipping them would have
been a change that looks like a fix and prevents nothing. That is the entry
this case study is proudest of: the issue is about checks that claim more than
they measured, and the same standard has to apply to the fixes.

It is also the entry that caught this branch committing the defect it was
written to remove. The suite behind that bullet asserted apt's default *equals*
3 retries, and the assertion went red on the runner — where the same apt 2.8.3
on the same Ubuntu 24.04.4 defaults to 1. Nothing in this repository depends on
that number being 3; what it depends on is `-o Acquire::Retries=3` not being a
*downgrade*. The suite had pinned the spelling of an environment's constant and
reported the verdict as a fact about the repository, which is precisely the
shape of RC-2, RC-5 and RC-12. It now derives the default from the measurement,
prints `apt-config dump`, the apt.conf files naming the key, `APT_CONFIG` and
whether `apt-get` is a wrapper script (the runner images replace it with one),
and fails only on a default *above* what the refresh sites pin. A second half
was added at the same time: a sweep of all 137 tracked shell, workflow and
Dockerfile sources for an `apt-get update` that inherits the environment's
default instead of passing its own — over logical lines, because every real
refresh site spells the option on a `\`-continuation and a per-line grep would
report all three as offenders.

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
root cause… keep the default state switched off". Seventeen of the twenty
root causes were found in the evidence as collected. Two questions were not
answerable from what the logs held, and each got output rather than a guess.

The first — *what did this pull request change, and how did the answer get
computed?* — is the one where a future failure would leave nothing behind,
because the failing path already explained itself and the **succeeding** path
did not.

`PR_DIFF_RANGE_VERBOSE=1`, or `BOX_VERBOSE=1` repository-wide, makes every answer
carry the base ref it resolved, whether that ref had to be fetched, the range and
merge base it diffed, and how many paths came back. Default off, on **stderr**
(every caller reads the helper through a command substitution), and printed
through `run_with_commands_stopped`, because a branch name is not text this
repository writes. Nine assertions cover it.

The second is RC-14: *why is apt's default retry count 1 on `ubuntu-24.04` and 3
on every other Ubuntu 24.04.4 with the same apt 2.8.3?* Nothing in the evidence
answers it. `actions/runner-images` writes `/etc/apt/apt.conf.d/80-retries`, but
the key in it is `APT::Acquire::Retries`, which apt does not read; its
`90assumeyes`, `99-phased-updates` and `99bad_proxy` files touch nothing related;
and `configure-apt-mock.sh` wraps `apt-get` in an *outer* 30-attempt loop, which
would raise the count, not lower it. So rather than assert a guess, the suite
prints what it would take to close the question on the next run — the measured
default, `apt-config dump Acquire::Retries`, every dumped key whose *name*
matches `retries` (the runner's `80-retries` sets `APT::Acquire::Retries`, which
apt does not read — a name without a value, and the first version of this report
blamed exactly that file for the 1 it cannot produce), every apt.conf line
mentioning retries with its file and contents, the `apt.conf.d` listing, and
`APT_CONFIG`'s contents — plus an assertion that the dumped value and the
measured default agree, so a wrapper deciding retries outside apt fails the run
instead of hiding behind it — and
`experiments/issue-123/measure-apt-retry-timing.sh` prints the arrival time of
every connection of a leg, so a retry can be distinguished from a redirect
rather than inferred from a total. This one is printed unconditionally: it is
five lines inside a suite whose whole output is measurements, and the failure it
explains happens on a machine nobody can attach to.

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

## 7. The suites, and the five times they failed on themselves

Fifteen offline suites, **551 assertions, 0 failures**, each checker exercised
in a passing *and* a failing form:

| suite | assertions | | suite | assertions |
| --- | ---: | --- | --- | ---: |
| `discovery-fail-closed` | 94 | | `workflow-yaml` | 28 |
| `release-version` | 86 | | `home-skel` | 23 |
| `pr-diff-range` | 70 | | `log-capture-truncation` | 23 |
| `zizmor-token` | 36 | | `budget-enforcement` | 20 |
| `overrun-not-supersede` | 35 | | `brew-link-status` | 16 |
| `sigpipe-writers` | 33 | | `apt-retry-defaults` | 15 |
| `artifact-upload-fail-closed` | 29 | | `npm-force` | 14 |
| `log-command-injection` | 29 | | | |

(`apt-retry-defaults` reports 15 by default; three further legs measuring idle
timeouts cost ~130 s and sit behind `APT_MEASURE_TIMEOUTS=1`, with their recorded
output in `apt/`.)

These suites failed on themselves **for exactly the defect this issue is
about** five times, and the failures are worth more than the fixes. Two of the five were
found by running them; three were found by the runner, which is the more
uncomfortable half of the finding — each of those three passed on every machine
this branch was written on and reported a verdict about `ubuntu-24.04` that it
had no basis for:

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

* **`apt-retry-defaults` pinned the spelling of an environment's constant.** It
  asserted apt's default *equals* 3 retries. It does here and in `ubuntu:24.04`;
  on the runner it is 1, with the same apt 2.8.3 on the same Ubuntu 24.04.4. The
  property this repository actually depends on is that `-o Acquire::Retries=3`
  is never a *downgrade*, and that is a direction, not an equality. §2 has the
  rest, including the debug output the suite now prints so the runner's 1 arrives
  explained rather than merely detected.
* **`sigpipe-writers` assumed the ambient signal disposition.** Its two legs are
  "SIGPIPE ignored" and "SIGPIPE at its default"; the first was established with
  a `trap`, the second was left to the machine. On a runner the machine's answer
  is *ignored* — that is the entire subject of the suite (actions/runner#2684) —
  so the two legs were one leg, and the suite reported "the retired shape already
  complains with default SIGPIPE": a true statement about its own fixture and no
  statement at all about the code under test. bash cannot undo an inherited
  `SIG_IGN`, so the default leg now enters through `perl` (or `python3`), which
  calls `signal(2)` before exec, and a new part reads each leg's `SigIgn` mask
  out of `/proc` so the premise fails loudly instead of the conclusion failing
  mysteriously.
* **`budget-enforcement` built a survivor that could not survive.** To test that
  an unkillable process is *reported* rather than called terminated, it faked
  `ps`. The fake listed the process groups currently in the table and fabricated
  a root-owned member for each — so the moment SIGTERM took the real group, the
  fabricated survivor went with it. Locally the group lingered past the grace
  period often enough to pass; on the runner it did not, and three assertions
  blamed the shipped wrapper for a race in the fixture. The fake now remembers
  every group it has ever seen and keeps reporting it: an unkillable process is
  one that does not go away, and a stand-in for it must not either.

The last three are RC-14, RC-15 and RC-16 in the root-cause list, and RC-13
belongs to the same group: a measurement of this branch's own, contaminated by a
glob. Six defects of the issue's own class, in the instruments built to measure
it — and the three that only the runner could find are the argument for why the
census had to be read line by line rather than trusted as green.

RC-17 came out of the same instruments and points the other way. A single
assertion in `test-issue121-git-hooks.sh` went red — `run-shellcheck.sh does not
see the hook` — and the trigger for that one red run was never reproduced. What
the investigation found instead was in the shipped gate: asked what it does when
discovery comes back short, `collect_files()` answered "the tree is clean" over
201 files it had not opened. The suite could not say more than it did, because
it called the gate with `2>/dev/null` and threw away the only diagnostic there
was; a flake that cannot be reproduced is still worth following, because the
question it forces — *what would this check say if it could not read anything?*
— has an answer whether or not the flake ever recurs.

---

## 8. The requirement list, item by item

The full table, with the falsifiable check for each row, is
`analysis/REQUIREMENTS.md`. In summary:

| Requirement | Where it landed |
|---|---|
| "check for all false positives, false negatives, warnings and errors… and fix them all" | all 804 `warn`/`error` lines classified (`analysis/warnings-errors.census.md`), every distinct one dispositioned — thirteen root causes fixed, eight lines left alone with the measurement attached (§2); three more of the same class came out of this branch's own tests on the runner (§7) |
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
eight of nine were green, and six of the twenty root causes are in them.

---

## 9. Existing components, and what was written instead

Nothing here was written before looking for something that already did it.
**Three of the twenty fixes are an existing component**; the rest are not, and
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
| Parse a workflow before four gates read it line by line | [actionlint](https://github.com/rhysd/actionlint) | **Already adopted, and still could not have prevented it**: the pin is `docker://rhysd/actionlint`, and a pre-commit hook cannot run docker. The floor is ruby's `psych` — measured as the only offline YAML parser present in both the image and the runner (`python3 -c 'import yaml'`, `node -e "require('yaml')"`, `yq` and `actionlint` are all absent locally), so the whole parse is one `ruby -ryaml` line rather than a dependency |
| "Which version is this release publishing?" | `actions/github-script` + a repository variable; `changeset status --output` | **Both declined**: a repository variable moves the single source of truth out of the tree, so a release could not be reproduced from a checkout, and adds a write scope to jobs that need none; and this repository does not run changesets as a package — `apply-changesets.sh` is its own implementation, and `VERSION` is the artefact it *writes*, so reading it back with the real tool would be a second source, which is the defect. The answer already existed: `detect-changes` computes it once and every call site is already handed it |
| A rule for what a check does when it cannot read its input | nothing to install | The "fail closed" rule was already applied in five of this repository's eight discovering gates; the work was finding the three that had been missed, and separating the two failure modes — "git could not answer" and "git answered, and there is nothing" — that were both being rendered as the same silence, then as success |

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
