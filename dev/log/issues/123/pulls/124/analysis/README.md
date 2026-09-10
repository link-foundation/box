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
| 3 | [`ROOT-CAUSES.md`](ROOT-CAUSES.md) | the thirteen mechanisms, one section each: how it misreports, the log line proving it, the alternatives weighed, the fix, the sweep that keeps it fixed |
| 4 | [`PRIOR-ART.md`](PRIOR-ART.md) | what already exists — per root cause, adopted or declined with the reason and the source |
| 5 | [`BEST-PRACTICES-VERIFICATION.md`](BEST-PRACTICES-VERIFICATION.md) | the sixteen hive-mind practices, re-measured against this branch by running a command per row |

## The two sweeps behind them

| Document | What it is |
| --- | --- |
| [`warnings-errors.census.md`](warnings-errors.census.md) | all **804** lines in the nine runs matching `warn`/`error`, classified into six classes, with every distinct `annotation`, `tool` and `assertion` text listed — the input to root-cause analysis, and the reason "seven annotations" is not the same question as "all warnings" |
| [`warnings-errors.raw.tsv`](warnings-errors.raw.tsv) | the census unaggregated: source, class, job, text. Regenerate with `bash experiments/issue-123/census-warnings-errors.sh` |
| [`git-read-failure-sweep.md`](git-read-failure-sweep.md) | every place this repository reads git or `gh` where a failure could be mistaken for an answer — the query that produced the list (23 hits) is in the document. Four sites were fixed (three release gates plus one `gh pr list`); the rest are dispositioned one by one with the reason each already errs strict, so the next person does not re-derive the list |

## What the analysis concluded, in four sentences

**Eight of the nine runs were green**, and six of the thirteen root causes live
in those eight — a green run is where this class of defect hides, because
nothing about it is red. The one cancellation was a real one-hour overrun, and
the status gate excused it as a supersede because the displacing push came from
the same run's own `Apply Changesets` job, 21 seconds after the runs were
created (`TIMELINE.md`). **Three of the seven annotations said something that
was not true** (`../annotations/README.md`). And no component exists to install
that would have caught any of it — warnings do not affect a conclusion and the
feature request is still open — so the answer is a census plus twelve offline
suites, **327 assertions, 0 failures**, each with a mutation control
(`PRIOR-ART.md` §"The general question behind all thirteen").

## The shape all thirteen share

A check that reports a verdict about data it never obtained. `git diff` exiting
128 and the status discarded; `if-no-files-found: warn`; zizmor answering "no
findings" about audits it skipped; `kill -0` conflating "not permitted" with
"not running"; a supersede excusing a cancellation a supersede could not have
caused. Each is stated once, with its mechanism, in `ROOT-CAUSES.md`.

Two of the suites written for this branch failed on their first full run for
exactly that reason — a sweep matching its own fixture text, and a measurement
reported before the data was in. Both were fixed at the root rather than by
loosening the assertion; the fixture-allowlist pattern and the quiescence loop
are documented in the suites themselves.
