# The upstream reports issue #123 produced, and where they went

Six defect classes, twenty deliveries: **19 new issues** across six template
repositories and **1 comment** on an existing one. Every one of them was found
by comparing this repository's workflow and script tree against the seven
`link-foundation/*-ai-driven-development-pipeline-template` repositories file by
file, which issue #123 asks for, and every one is reproduced by a fixture in
`experiments/issue-123/` that runs offline against a pinned template checkout.

| Report | Recipient | Filed |
| --- | --- | --- |
| A-js | js | [js#186](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/186) |
| A-python | python | [python#80](https://github.com/link-foundation/python-ai-driven-development-pipeline-template/issues/80) |
| A-rust | rust | [rust#171](https://github.com/link-foundation/rust-ai-driven-development-pipeline-template/issues/171) |
| A-php | php | [php#14](https://github.com/link-foundation/php-ai-driven-development-pipeline-template/issues/14) |
| B-js | js | [js#187](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/187) |
| B-python | python | [python#81](https://github.com/link-foundation/python-ai-driven-development-pipeline-template/issues/81) |
| B-rust | rust | [rust#172](https://github.com/link-foundation/rust-ai-driven-development-pipeline-template/issues/172) |
| B-php | php | [php#15](https://github.com/link-foundation/php-ai-driven-development-pipeline-template/issues/15) |
| C-js | js | [js#188](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/188) |
| C-python | python | [python#82](https://github.com/link-foundation/python-ai-driven-development-pipeline-template/issues/82) |
| C-rust | rust | [rust#173](https://github.com/link-foundation/rust-ai-driven-development-pipeline-template/issues/173) |
| C-csharp | csharp | [csharp#60](https://github.com/link-foundation/csharp-ai-driven-development-pipeline-template/issues/60) |
| C-go | go | [go#7](https://github.com/link-foundation/go-ai-driven-development-pipeline-template/issues/7) |
| C-java | java | [java#7](https://github.com/link-foundation/java-ai-driven-development-pipeline-template/issues/7) |
| D-go | go | [go#8](https://github.com/link-foundation/go-ai-driven-development-pipeline-template/issues/8) |
| D-java | java | [java#8](https://github.com/link-foundation/java-ai-driven-development-pipeline-template/issues/8) |
| D-csharp-53-comment | csharp | [csharp#53 (comment)](https://github.com/link-foundation/csharp-ai-driven-development-pipeline-template/issues/53#issuecomment-5611044703) |
| E-csharp-exec-injection | csharp | [csharp#61](https://github.com/link-foundation/csharp-ai-driven-development-pipeline-template/issues/61) |
| F-java-changeset-not-validated | java | [java#9](https://github.com/link-foundation/java-ai-driven-development-pipeline-template/issues/9) |
| F-rust-checks-swallow-git-failures | rust | [rust#174](https://github.com/link-foundation/rust-ai-driven-development-pipeline-template/issues/174) |

Machine-readable in `filed/index.tsv` (report, repository, URL).

## What each class is, and who got it

**A — `check-pipeline-status.sh` excuses every cancellation in a superseded
run.** The gate asks one question of the whole run ("is this still the branch
head?") and lets the answer excuse every cancelled job in it, including jobs
declaring `cancel-in-progress: false`, which a supersede cannot reach at all.
This is annotation 5 of run 34366975927 in `../annotations/README.md`, on our
own `main`. Filed to the **four templates that ship the script** — js, python,
rust, php; csharp, go and java have no `check-pipeline-status.sh` at all
(verified with `find`), and for csharp its absence is already
[csharp#55](https://github.com/link-foundation/csharp-ai-driven-development-pipeline-template/issues/55).
Prior art, all closed:
[js#167](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/167),
[python#69](https://github.com/link-foundation/python-ai-driven-development-pipeline-template/issues/69),
[rust#156](https://github.com/link-foundation/rust-ai-driven-development-pipeline-template/issues/156),
[php#9](https://github.com/link-foundation/php-ai-driven-development-pipeline-template/issues/9)
— those issues added the gate and its supersede test; this one is that the
second question has to be asked of the job, not of the run.

**B — `run-with-budget-warning.sh` reports a command as finished while its own
children keep running.** `kill -0` cannot distinguish EPERM ("alive, not yours
to signal") from ESRCH ("gone"), both exit 1, so a root-owned grandchild reads
as finished; the wrapper skips its SIGKILL escalation and exits 124 believing it
terminated the command, and the survivor holds the step open on the inherited
stdout until `timeout-minutes` cancels the job. That is exactly what happened in
34366975927 — the budget fired at 15:37:47 and the job ran on for 19m21s. Same
four recipients, same reason. Prior art, all closed:
[js#164](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/164),
[python#60](https://github.com/link-foundation/python-ai-driven-development-pipeline-template/issues/60),
[rust#153](https://github.com/link-foundation/rust-ai-driven-development-pipeline-template/issues/153),
[php#10](https://github.com/link-foundation/php-ai-driven-development-pipeline-template/issues/10).

**C — pull-request-authored text printed to the CI log unbracketed.** The
runner's `ActionCommand.TryParse` matches `##[` anywhere in a physical line, so
a changeset description quoting `##[error]` annotates the run — and
`::stop-commands::` in the same registered set means the same text can switch
command processing off or mask arbitrary output. Filed to the **six templates
with a measured printer**; php has none (`validate-changeset.php:42` and
`create-github-release.php:48/59` print fixed strings). The per-template printer
list, including two sites that turned out to be `if (dryRun)`-only and the
success-path `Description:` printers that run on *every* pull request, is
`evidence/log-injection-printer-census.txt`. No template mentions
`stop-commands` anywhere in its tree. Related upstream work from issue #121:
[actions/runner#4692](https://github.com/actions/runner/issues/4692),
[docker/buildx#4066](https://github.com/docker/buildx/issues/4066),
[docker/build-push-action#1612](https://github.com/docker/build-push-action/issues/1612),
and [box#121](https://github.com/link-foundation/box/issues/121) for the
56-annotation instance of the same mechanism with a different printer.

**D — `workflow_dispatch` inputs interpolated into `run:` scripts.** Filed to
the two templates that do it and had no report: go and java. rust fixed it in
[rust#111](https://github.com/link-foundation/rust-ai-driven-development-pipeline-template/issues/111)
and `release.yml:1163-1167` is the shape to copy; js, python and php interpolate
no dispatch input into any `run:` script. csharp already has it open as
[csharp#53](https://github.com/link-foundation/csharp-ai-driven-development-pipeline-template/issues/53),
so that one is a **comment, not a new issue** — and the comment corrects the
open issue rather than agreeing with it: two of the four sites it lists
(`:767`, `:770`) are inside a *quoted* heredoc and do not execute as described,
they are content injection until a newline arrives. Adding a finding is cheap;
letting a wrong one stand is what the audit is against.

**E — `version-and-commit.mjs` concatenates its `git commit` and `git tag`
command lines.** csharp only. `execSync(string)` runs through `/bin/sh -c`, so
the script's `.replace(/"/g, '\\"')` does not neutralise `$( )` — the release
description executes twice, once per command.

**F — checks that read a failed `git diff` as "nothing changed".** java's
`validate-changeset.mjs` falls back to `git diff --name-only HEAD`, which lists
uncommitted changes and is therefore empty on every CI checkout; rust's
`check-changelog-fragment.rs` and `check-version-modification.rs` take an empty
string from a failed `exec()` the same way, and the second ignores
`output.status` entirely, so a hand-written `version = "9.9.9"` passes in
silence. The other five templates err in the safe direction (validating the
whole changeset directory, or never asking git); the survey is in the reports
themselves.

## How these were produced and posted

`experiments/issue-123/render-upstream-reports.sh` renders A–D per recipient
from the placeholder documents in this directory (`A-supersede.md`,
`B-budget-survivor.md`, `C-log-injection.md`, `D-dispatch-injection.md`),
substituting each template's own code, line numbers and measured transcript
sections, so a report quotes the repository it is addressed to and not a
paraphrase of ours. E and F are hand-authored — one recipient each for E, two
different code shapes for F.

`experiments/issue-123/file-upstream-reports.sh` files them: first line of
`filed/<report>.md` is the title, the remainder is the body, and each body's
reproduction fixture is appended in a `<details>` block, because every report
says the fixture is "attached below" and an upstream reader must be able to run
it without cloning `box`. It is a dry run by default, writes the exact bytes it
would post to `rendered/`, appends each result to `filed/index.tsv`, and skips
anything already in the index, so an interrupted run resumes.

| Report | Fixture attached |
| --- | --- |
| A-* | `repro-supersede.sh` |
| B-* | `repro-budget-survivor.sh` |
| C-* | `repro-log-injection-changeset.sh` |
| D-* | `repro-dispatch-description-injection.sh` |
| E-csharp-exec-injection | `repro-csharp-exec-escaping.sh` |
| F-* | `repro-changeset-validation-fallback.sh`, `probe-shallow-base-ref.sh` |

Verified after posting, not assumed: `js#186`'s body read back through the API
is identical to `rendered/A-js.body.md` after whitespace normalisation (GitHub
strips trailing whitespace), and `rust#174` came back 25132 bytes against 25178
written, differing only in that stripping.

Templates were read at pinned HEADs, quoted in each report: js `c3a6d23b`,
python `470e1760`, rust `f63a061f`, php `15c327be`, csharp `83efb9e4`, go
`548a7968`, java `450a10ec`.

## Drafted, not filed: `G-runner-images-inert-retries-key.md`

One more report is written but **not posted**, and the distinction is
deliberate. `G` is addressed to a *third-party* repository —
[actions/runner-images](https://github.com/actions/runner-images) — not a
`link-foundation` template, so filing it is an outward-facing action on a repo
this project does not own. It reports a certain, separable bug: the runner
images' `configure-apt.sh` writes `APT::Acquire::Retries "10"` to
`/etc/apt/apt.conf.d/80-retries`, and apt reads `Acquire::Retries`, not the
`APT::`-prefixed name, so the file is inert (proven offline by
`experiments/issue-123/repro-apt-retries-key.sh`, transcript in
`evidence/repro-apt-retries-key.txt`).

It is held back for two reasons. First, it is outward-facing on a repository we
do not own, so it waits on a human decision rather than being posted by the
solver. Second, the inert key is in the *raising* direction and cannot by itself
explain the thing that motivated the investigation — the runner's measured
default of **1** retry, not 3 — so the honest report is scoped to the inert key
alone, and the branch's stance is to gather one more runner failure's diagnostic
(the apt suite now prints `apt-config dump` and every retry-setting line, and
fails if the dump and the measured default disagree) before filing anything that
claims to explain the 1. The draft is complete and ready to post the moment
either the human decision is made or the next run supplies the missing half.
