# The analysis, and the order to read it in

Nine documents. Together they answer issue #123's four questions — what was
asked, what happened, why, and whether anything already solved it — and each one
is written so its claims can be checked against the evidence in `../` rather
than taken on trust.

## Read in this order

| # | Document | Answers |
| --- | --- | --- |
| 1 | [`REQUIREMENTS.md`](REQUIREMENTS.md) | every requirement, from the issue body (A1–A7) and from the task message (B1–B10), each with the artefact that discharges it and what would falsify it |
| 2 | [`TIMELINE.md`](TIMELINE.md) | what happened at `1d9fb3e` on 2026-09-09, to the second, reconstructed from the run records and the step logs |
| 3 | [`ROOT-CAUSES.md`](ROOT-CAUSES.md) | the nineteen mechanisms, one section each: how it misreports, the log line proving it, the alternatives weighed, the fix, the sweep that keeps it fixed |
| 4 | [`PRIOR-ART.md`](PRIOR-ART.md) | what already exists — per root cause, adopted or declined with the reason and the source |
| 5 | [`BEST-PRACTICES-VERIFICATION.md`](BEST-PRACTICES-VERIFICATION.md) | the sixteen hive-mind practices, re-measured against this branch by running a command per row |

## The two sweeps behind them

| Document | What it is |
| --- | --- |
| [`warnings-errors.census.md`](warnings-errors.census.md) | all **804** lines in the nine runs matching `warn`/`error`, classified into six classes, with every distinct `annotation`, `tool` and `assertion` text listed — the input to root-cause analysis, and the reason "seven annotations" is not the same question as "all warnings" |
| [`warnings-errors.raw.tsv`](warnings-errors.raw.tsv) | the census unaggregated: source, class, job, text. Regenerate with `bash experiments/issue-123/census-warnings-errors.sh` |
| [`git-read-failure-sweep.md`](git-read-failure-sweep.md) | every place this repository reads git or `gh` where a failure could be mistaken for an answer — both queries that produced the list are in the document — the first one, which returned 24 plausible hits on `main` and could not match any of RC-17's five gates, and the corrected one, which returns 66 with all five among them. Five sites were fixed (three release gates, one `gh pr list`, and the hook
driver, whose index read had the same shape); the rest are dispositioned one by one with the reason each already errs strict, so the next person does not re-derive the list |

## What the analysis concluded, in four sentences

**Eight of the nine runs were green**, and six of the nineteen root causes live
in those eight — a green run is where this class of defect hides, because
nothing about it is red. The one cancellation was a real one-hour overrun, and
the status gate excused it as a supersede because the displacing push came from
the same run's own `Apply Changesets` job, 21 seconds after the runs were
created (`TIMELINE.md`). **Three of the seven annotations said something that
was not true** (`../annotations/README.md`). And no component exists to install
that would have caught any of it — warnings do not affect a conclusion and the
feature request is still open — so the answer is a census plus fifteen offline
suites, **541 assertions, 0 failures**, each with a mutation control
(`PRIOR-ART.md` §"The general question behind all nineteen").

## The shape all nineteen share

A check that reports a verdict about data it never obtained. `git diff` exiting
128 and the status discarded; `if-no-files-found: warn`; zizmor answering "no
findings" about audits it skipped; `kill -0` conflating "not permitted" with
"not running"; a supersede excusing a cancellation a supersede could not have
caused; `git ls-files` failing and the failure spelled `|| true`, so a linter
reports a clean tree over 201 files it never opened; `tr -d '[:space:]' <
VERSION` succeeding over an empty file, and the bump arithmetic turning the
empty string into `1.0.0`; four gates reading the same unparseable workflow line
by line and each printing a verdict about it. Each is stated once, with its
mechanism, in `ROOT-CAUSES.md`.

The suites written for this branch committed that same defect five times, and
the last three of those are RC-14, RC-15 and RC-16. Two were found by running
them here — a sweep matching its own fixture text, and a measurement read before
the data was in. Three were found only by the GitHub runner, on suites that were
green on every machine this branch was written on: an assertion that apt's
default retry count *equals* 3, which is a fact about a machine and not about
this repository; a "SIGPIPE at its default" leg that inherited the runner's
`SIG_IGN` instead of establishing anything, making both legs the same leg; and a
fake `ps` whose unkillable survivor died with the process group it was standing
in for. All five were fixed at the root rather than by loosening the assertion,
and each fix carries either a premise assertion or a mutation control.

RC-17 came from the sixth: a full experiment run of this branch went red once,
on an assertion that had discarded the linter's own stderr and so could say only
"does not see the hook". The trigger is still unproven; the defect it pointed at
is not, and had been in the two largest gates here since they were written —
`git ls-files … || true`, an empty list, and `==> No shell scripts to check`
with exit 0 over 201 unread files. Fixing it in all eight discovering gates
(requirement B10) then found two more doors into the same room: two gates whose
refusal named the wrong cause, and four that answered `--list-inputs` — the
contract the coverage gate reads — with an empty list and exit 0.

RC-18 and RC-19 close the loop from the other end. RC-18 is the same question
asked of the release pipeline rather than of a linter: eighteen steps across six
workflows each re-derived the version being published by reading a file, and an
empty file publishes `1.0.0` — below every version this repository has released
— because `tr` succeeds and the bump arithmetic reads the empty string as zero.
The pipeline had already computed the answer once and was already handing it to
every called workflow; one reader now uses it.

RC-19 is this branch's own edit. The RC-18 replacement stranded three orphan
lines and left `release-full.yml` unparseable, and every one of the eleven gates
the pre-commit hook runs passed it — including all four that read workflows,
each of which was handed that file and each of which exited 0 while describing
its contents. They read line by line on purpose, so none of them *can* ask the
question; the floor they all assume was never established anywhere. It is now,
by `check-workflow-yaml.sh`, and its limits are written next to it rather than
implied.
