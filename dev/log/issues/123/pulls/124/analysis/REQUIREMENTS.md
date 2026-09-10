# Every requirement in issue #123, and where each one is answered

The issue is two documents in one: the body konard wrote, and the task message
that dispatched this branch. Both are requirements, so both are enumerated here.
Each row names the artefact that discharges it, so a reader can check the claim
rather than accept it.

Nothing here is marked done because a file exists. A row is "held" only when
something in the tree fails if the requirement stops being held, or — where
that is not possible, as for "report it upstream" — when the delivery has a URL
that can be opened.

## A. From the issue body

| # | Requirement (issue's words) | Held by | Falsifiable by |
| --- | --- | --- | --- |
| A1 | "Check for all false positives, false negatives, warnings and errors in CI/CD **and fix them all**" — over the nine listed runs at `1d9fb3e` | `warnings-errors.census.md` + `warnings-errors.raw.tsv` classify all 804 lines; `ROOT-CAUSES.md` dispositions every distinct one | re-run `census-warnings-errors.sh`; every line it prints is in the disposition table |
| A2 | The nine runs are the scope, including the one `cancelled` run | `../ci-logs/` (all nine run logs + all 99 jobs of the release run), `../runs/`, `../annotations/` | `collect-ci-evidence.mjs` refetches nothing and reports a refusal rather than an empty log |
| A3 | "Use all the best practices from CI/CD templates **(check full file tree to compare for all GitHub workflow and CI/CD scripts file)**" | `../templates/COMPARISON.md` — 160 script roles and 17 workflow roles across **eight** repositories, 91 gaps dispositioned individually | `bash experiments/issue-123/compare-template-roles.sh` reproduces the matrix offline from the pinned snapshot |
| A4 | "if the same issue is found in template **report issue also in templates**" | `../upstream/README.md` — 19 issues + 1 comment, six defect classes, each carrying its reproduction fixture | every URL in `../upstream/filed/index.tsv` |
| A5 | "We should compare all files, so we don't have more CI/CD errors in the future" | the comparison is snapshot-pinned in `../templates/SNAPSHOT.txt`, so the next comparison starts from a fixed revision rather than from "current HEAD" | `SNAPSHOT.txt` names the seven SHAs the comparison was made against |
| A6 | "Follow the CI/CD best practices collected in hive-mind `docs/CI-CD-BEST-PRACTICES.md`" | `BEST-PRACTICES-VERIFICATION.md` — all sixteen re-measured, each with the command behind the verdict | the document stores the practices file it read, at a pinned commit, beside itself |
| A7 | "plan and execute everything **in this single pull request** … until each and every requirement is fully addressed" | PR #124; 18 commits, no second branch, no follow-up issue opened against this repository | `git log main..HEAD` |

Two things A1 needs stated plainly, because the issue's title invites a count
and a count is the wrong instrument:

* **Seven annotations, not "all warnings".** GitHub's annotation API sees only
  what a tool emitted as a `##[…]` command or what the runner itself failed. The
  nine runs carry seven. Every other warning in them exists only as log text, in
  no API — which is why A1 is discharged against the *logs* (804 matching lines)
  and not against the annotation endpoint.
* **A green run is the interesting case.** Eight of the nine were green. Six of
  the twenty root causes on this branch were found in those eight.

## B. From the task message

| # | Requirement | Held by |
| --- | --- | --- |
| B1 | "Download all logs and collect data … into `./dev/log/issues/123/pulls/124`" | 7.4 MB: `ci-logs/` (113 files), `templates/` (269), `upstream/` (58), `runs/` (22), `annotations/` (10), `zizmor/` (7), `apt/` (2), `useradd/` (2), `npm-force/` (1), `analysis/` (this directory) — see `README.md` |
| B2 | "deep analysis (search online for additional facts and data)" | `PRIOR-ART.md` §1–§4: the runner's `ActionCommand` source, GitHub's own docs for `steps.<id>.outcome` and `if-no-files-found`, zizmor's offline-mode change, useradd's skel rule, apt 2.8.3's compiled-in defaults |
| B3 | "reconstruct the timeline/sequence of events" | `TIMELINE.md` — second-resolution, from the run records and the job logs |
| B4 | "list each and every requirement from the issue" | this document |
| B5 | "find the root cause of each problem" | `ROOT-CAUSES.md` — one entry per defect, mechanism first, fix second |
| B6 | "propose possible solutions and solution plans for each requirement" | `ROOT-CAUSES.md` carries the alternatives considered for each defect and why the shipped one won; the four rejected-with-measurement cases are §"Roads not taken" |
| B7 | "check online for known existing components/libraries that solve a similar problem" | `PRIOR-ART.md` §5 — nine candidate tools/actions, each with the reason it was adopted or declined |
| B8 | "if there is not enough data … add debug output and a verbose mode … keep the default state switched off" | `BOX_VERBOSE` / `PR_DIFF_RANGE_VERBOSE` in `scripts/release/pr-diff-range.sh` (commit `320491d`), default off, traces on stderr; nine assertions in `test-issue123-pr-diff-range.sh` cover it. The second unanswered question — why apt's default retry count is 1 on `ubuntu-24.04` (RC-14) — is instrumented rather than guessed: the suite prints its measured default, `apt-config dump Acquire::Retries`, every apt.conf file naming the key, `APT_CONFIG` and whether `apt-get` is a wrapper, and `experiments/issue-123/measure-apt-retry-timing.sh` times every connection of a leg |
| B9 | "report issues on GitHub for that project … reproducible examples, workarounds, and suggestions for fixing the issue in code" | `../upstream/` — every body carries a fixture, a workaround and a diff |
| B10 | "double-check that the requirements are fully applied to the entire codebase: if an issue exists in multiple places, apply it in all of them" | the multi-site column of `ROOT-CAUSES.md`, and the sweep assertion each fix ships with |

### B10 in detail — every fix that had more than one site

The issue's instruction is the one most easily satisfied in appearance and
missed in fact, so each fix on this branch carries a repository-wide sweep in
its own suite, and the sweep is itself mutation-tested: a planted offender must
make it fail, or its silence means nothing.

| Defect | Sites found | Sweep that keeps it at zero |
| --- | ---: | --- |
| `brew link … \| grep -v Warning \|\| true` | 4 | `test-issue123-brew-link-status.sh` part 5 |
| `useradd` meeting an existing home | 5 (1 Dockerfile + 4 shell) | `test-issue123-home-skel.sh` parts 6–7 |
| unbounded writer into an early-exiting reader | 2 fixed, 3 safe sites left alone | `test-issue123-sigpipe-writers.sh` part 4, 3 mutation fixtures |
| PR-authored text printed with commands live | 10 (5 `git commit`, 1 `git pull`, 4 changeset echoes) | `test-issue123-log-command-injection.sh` |
| `tee /dev/stderr` capture | 4 | `test-issue123-log-capture-truncation.sh` |
| `git diff …BASE…HEAD` with the status discarded | 3, plus 2 `gh` reads | `test-issue123-pr-diff-range.sh` part 1 (a range query as an assertion) |
| `if-no-files-found: warn` | 2 | `test-issue123-artifact-upload-fail-closed.sh` scans every workflow **and** composite action |
| `npm … --force` | 1 | `test-issue123-npm-force.sh` sweeps `ubuntu/`, `scripts/`, `.github/` |
| zizmor invoked without a token | 3 (2 workflow passes + the local suite) | `test-issue123-zizmor-token.sh`, 36 assertions |
| supersede excusing a cancellation | 1 script, asked of all 31 jobs | `test-issue123-overrun-not-supersede.sh` part 6 |
| `apt-get update` inheriting a retry count instead of passing one | 3 refresh sites, 135 sources swept | `test-issue123-apt-retry-defaults.sh` part 4, over **logical** lines — all three real sites spell the option on a `\`-continuation |
| `git ls-files … \|\| true` — a git that could not answer read as a clean tree | 8 discovering gates (5 fixed, 3 confirmed) + the hook driver that runs them | `test-issue123-discovery-fail-closed.sh` part 1 requires every `scripts/ci` script matching `git +ls-files` to be either driven by the suite's two failure fixtures or exempt **in writing**, with the exemption checked against the tree so it cannot go stale |
| a release step re-deriving the version it publishes from a file | 18 reads across 6 workflows, 16 of them preceded by `git pull origin main \|\| true` | `test-issue123-release-version.sh` sweeps for both lines with comments excluded in *both* directions, and checks the `changes:` map at each of the five call sites rather than counting five of them anywhere in the file |
| a workflow no parser accepts, passed by every gate that reads workflows | 1 file, 3 orphan lines, all 15 replacement sites re-read | `test-issue123-workflow-yaml.sh` — and the gate itself, which is the floor the other four assume; part 2 puts the same broken file back through two of them so the reason it exists is a measurement rather than a claim |
| a gate whose input pattern had no anchor, so another project's file became its subject | 1 unanchored gate; all 10 discovering gates re-measured against the evidence tree, 1355 inputs, 0 under `dev/log/` | `test-issue123-pr-diff-range.sh` — six assertions written against a generic nested `.changeset/` rather than against `dev/log/`, because the anchor is what makes them right, plus both directions of the agreement with `apply-changesets.sh`'s `-maxdepth 1` |

The remaining sites where a git or `gh` read could be mistaken for an answer are
listed one by one, with the disposition of each, in `git-read-failure-sweep.md`.
None of them is a defect — every one errs in the strict direction already — and
the point of writing them down is that the next person to ask does not have to
re-derive the list.

That document also records the one case where a sweep on this branch was itself
the defect it hunts. Its original query could not match any of the five gates in
the row above: it required a `$(` command substitution, and all five were bare
pipelines in a function body, three of them with the `|| true` on a backslash
continuation. It returned 24 plausible-looking hits on `main` and none of the
five. The corrected query — continuations joined, comments dropped, substitution
not required — returns 66 on the same tree with all five among them, and the
disposition of every remaining hit is tabulated there.
