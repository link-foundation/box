# Case Study: Issue #121 — Ninety-eight annotations, and two of them meant what they said

## Executive Summary

The eight runs [issue #121](issue.md) lists carried **98 annotations**: 58 at
level `failure`, 29 at `warning`, 11 at `notice`
(`dev/log/issues/121/pulls/122/analysis/annotations-main.tsv`). Seven of the
eight runs were green.

Two of the 98 were the run that was actually red, and they were reporting a test
assertion that could only pass on one calendar day. The other 96 were a commit
message being read back at the runner as if it were build output, a package
manager refusing to remove five packages it *could* have removed, a builder
cleanup on a machine about to be destroyed, and ten advisory notices from a
linter whose threshold was set below anything it could find.

A pipeline that annotates 96 times without meaning it is not merely noisy. It is
a pipeline whose annotations have stopped being evidence — which is the same
failure, in the other direction, as a check that cannot fail. This issue asked
for both halves: every false positive removed, and every false negative given a
way to go red.

| # | Finding | Where it showed | Root cause | Resolution |
|---|---|---|---|---|
| a | 56 `failure` annotations on a **green** release run | run [34293699247](https://github.com/link-foundation/box/actions/runs/34293699247) | Commit `a2e6420`'s message quotes `##[error]`. buildx bakes `GITHUB_EVENT_PATH` into the builder, `build-push-action` prints the metadata file verbatim, and the runner accepts `##[` **anywhere** in a line. | `BUILDX_METADATA_PROVENANCE: disabled` at workflow scope in all six building workflows. Three upstream reports: [buildx#4066](https://github.com/docker/buildx/issues/4066), [build-push-action#1612](https://github.com/docker/build-push-action/issues/1612), [runner#4692](https://github.com/actions/runner/issues/4692). |
| b | 28 `warning` annotations, exactly one per arm64 job | same run | `jlumbroso/free-disk-space` removes a fixed name list. Google publishes no arm64 apt repository, so apt exits 100 at `google-chrome-stable` — and removes **none** of the other five it could have. | `.github/actions/free-disk-space` wraps the action with `large-packages: false` and hands `scripts/ci/reclaim-large-packages.sh` the intersection of the action's patterns with what dpkg reports installed. |
| c | 1 `warning` on a green `full / docker-build-push` | same run | `docker buildx rm` bounds the whole removal with `--timeout` (20s, documented as "loading builder status"); deleting a full-box cache volume takes longer. Regression in buildx v0.36.0. | The composite passes `cleanup:` down, defaulting to `runner.environment != 'github-hosted'`. Upstream: [buildx#4067](https://github.com/docker/buildx/issues/4067), [setup-buildx-action#615](https://github.com/docker/setup-buildx-action/issues/615). |
| d | The one **red** run in the table | run [34293699072](https://github.com/link-foundation/box/actions/runs/34293699072) | `test-issue119-image-tags.sh` asserted "the date tag defaults to today in UTC" while its helper re-pinned `IMAGE_TAGS_DATE=20260908`. It passed on one day and reported working release tooling as broken every day after. | The helper takes `UNPINNED=1`; `experiments/test-issue121-clock-independence.sh` runs every clock-reading suite at three fixed dates. |
| e | 10 `notice` annotations no run could go red on | run [34011750123](https://github.com/link-foundation/box/actions/runs/34011750123) | `.hadolint.yaml` failed at `warning`; all ten findings are `info`. The runner mapped levels beside a threshold it never read. | All ten resolved (DL3015 measured per site, not blanket-ignored), threshold lowered to hadolint's default `info`, annotation level derived from the config. |
| f | A `Playwright Host validation warning` on both JS build jobs, exit 0 | same release run | `ubuntu/24.04/js/Dockerfile` was seven packages short of Playwright's own `deps['ubuntu24.04-x64']`. Only one surfaced, because host validation `ldd`s the browsers that were downloaded. | All seven installed; `assert_no_playwright_host_warning` turns the warning into a build failure. |
| g | `zizmor` reported no findings about files it never opened | every `workflows` run | The job scanned `.github/workflows` only. The four composite actions under `.github/actions/` had never been read by any linter — hiding a High-confidence `template-injection` in `dockerhub-login/action.yml:93`. | Scope widened to both directories; the interpolation moved into `env:`. |
| h | A declared policy with no auditor | every `workflows` run | `.github/zizmor.yml` declares `'*': hash-pin`, but the audits that read image references are **Pedantic-persona only**, so `uses: docker://rhysd/actionlint:1.7.7` passed every run since the policy was written. | A second pass at `--persona pedantic --min-severity high --min-confidence high`; the image pinned by digest. |
| i | A run that concluded grey while holding a job that had **failed** | run [34259552358](https://github.com/link-foundation/box/actions/runs/34259552358) | GitHub ranks a cancellation above a failure when folding job conclusions into a run conclusion. Everything that reads the run rather than its jobs — the badge, `gh run list`, the table in issue #121 itself — then sees "no verdict". | `scripts/ci/check-pipeline-status.sh` as a terminal gate in every entry-point workflow, plus `check-status-gate-covers-all-jobs.mjs` so a job cannot be added outside it. |
| j | A job killed by `timeout-minutes` names neither the step nor the number | structural | A backstop cancels the job; the run goes grey, every `if: always()` reporting step is skipped, and the annotation says only that the job was cancelled. Caps were guesses: 120 minutes against a measured maximum of 35.6, 180 against 23.3. | 22 long steps wrapped in `scripts/ci/run-with-budget-warning.sh`, caps sized from `measure-job-durations.sh`, and `check-timeout-budgets.mjs` keeping every budget under 70% of its cap — per matrix leg. |
| k | A links gate that fails on a connection reset and cannot be fixed without going blind | `links` | lychee classifies errors by phase and answers `false` for the connect phase, so `--max-retries` never applies ([lychee#2297](https://github.com/lycheeverse/lychee/issues/2297)). The cheap fix — an `.lycheeignore` entry — turns a real 404 on that host into permanent silence. | `scripts/ci/recheck-broken-links.mjs` re-asks only the URLs **no host answered**. Diverges from the template, whose `all_recovered` ignores answered failures: [js#184](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/184), [rust#170](https://github.com/link-foundation/rust-ai-driven-development-pipeline-template/issues/170). |
| l | Three jobs wrote to `main` with a bare `git push origin main` | `release`, `measure-disk-space` | A concurrency group orders writers; it does not rebase them. And a ruleset rejection and a race print the same word — classify a rule as a race and the job rebases, pushes, is declined identically, and blames a race that never happened. | `git-push-failure-classifier.sh` tests for a rule **before** a race; `git-push-with-retry.sh` answers a rule with a pull request. |
| m | A suite asserting "exactly 3 suites are skipped" | `scripts` | A hard-coded count fails when a justified exclusion is added, and passes when an entry silently stops matching. | It compares the runner's declared exclusions against the ones that actually apply. |
| n | A CI policy check that failed on the comment explaining it | `scripts` | Invariant 4 of `test-issue115-ci-policy.sh` grepped raw workflow text for `always()`. | It reads evaluated expressions, not prose. |
| o | The assertion written for finding **g** could not fail on the machine that ran it | `scripts` | It extracted a `run:` block with `awk '/^\s+run: \|/,0'`. `\s` is a GNU extension: under mawk (Debian's and Ubuntu's default `awk`) it matches nothing, the range never opens, and the negated grep passes. Under gawk — what GitHub's runner ships — `,0` never closes, so the "block" is the rest of the file and correct `with:` mappings are reported. | The block is bounded by indentation; `scripts/ci/check-awk-portability.sh` fails CI on any GNU-only escape in an awk program, over every tracked file. |
| p | Ten of this repository's fourteen JavaScript modules were parsed by nothing | structural | shellcheck, shfmt and `check-heredoc-vars.sh` discover `*.sh`; `run-experiments.sh` discovers `experiments/*.sh`; `check-file-line-limits.sh` reads `*.mjs` but only counts lines. Two of the four modules CI does execute run **only** on the recovery path, after the links check has already failed. | `scripts/ci/check-mjs-syntax.sh` parses every tracked module and resolves every relative import, ported from the js template's gate of the same name. |
| q | The job that commits the README could commit another run's numbers | `measure-disk-space` | `update-readme-sizes.sh` rendered its table to `/tmp/markdown_table_content.txt` — one fixed path, shared by every invocation on the machine — and the branch that runs when the README has lost its markers read that file three lines *before* writing it. With no leftover it died with a Python traceback naming a path in `/tmp`; with a leftover it wrote **that** run's table into this README and exited 0. `--readme-file` and `--json-file` were parsed into shell variables the Python child process never saw, so the script announced one file and rewrote another. | One render into a `mktemp` file of the run's own, one write path for both branches, and both paths exported. `experiments/test-issue121-readme-updater.sh` holds 25 assertions, 10 of which fail against the previous script; the transcripts are in `dev/log/issues/121/pulls/122/readme-updater/`. |
| r | The link checker resolved every link and checked no anchor | `links` | lychee stops at the document: `docs/RELEASING.md#making-the-ghcr-packages-public` passes because that file exists, whatever headings it contains. An anchor is the part of a link a heading rename breaks, and 27 links in the corpus carry one (14 into this repository, 13 remote). | `--include-fragments`. A mutation fixture pins that the flag is what does it — the same two files, both target headings renamed, report `2 OK 🚫 0 Errors` without it and `Cannot find fragment` twice with it. Turning it on found 4 errors on 3 URLs, each confirmed dead in a browser and fixed; the full corpus is then 678 links, 664 OK, **0 errors** in 12.8 s. Evidence: `dev/log/issues/121/pulls/122/doc-fragments/`. |
| s | A heading two scripts depend on could be renamed by anyone | structural | `update-readme-sizes.sh` inserts the generated table before README's `## License`, falling back to `## Documentation`; rename either and the section is appended to the end of the file with the job still green. `preflight-credentials.sh:222` sends an operator holding a rejected credential to "the 'Releasing' section of README.md", and two other scripts name `docs/RELEASING.md` — messages read on the worst day of a release, pointing at headings nothing verified. | `scripts/ci/check-required-docs.sh`: six documents, 24 sections, both component-sizes markers, and every `docs/…md` path named anywhere in `scripts/` or `.github/`. Ported from the js template's gate of the same name; run by a new `docs.yml`, whose triggers are the union of the markdown and the shell. 32 assertions in `experiments/test-issue121-required-docs.sh`, built from the checker's own `--list` so the fixtures cannot drift from the table. |

One sentence covers the whole table: **an annotation is a claim about the run,
and every mechanism here was making claims it had not checked** — in both
directions.

---

## 0. What was measured, and how

Nothing below is inferred from a workflow file alone. The evidence is in
`dev/log/issues/121/pulls/122/`, and every number in this document comes out of
it:

| Directory | What it holds |
|---|---|
| `analysis/` | all 98 annotations of the eight runs (`annotations-main.tsv`), plus job- and step-duration samples used to size the timeout caps |
| `run-conclusions/` | the 200 most recent runs (2026-09-06 .. 2026-09-09), each compared against its own jobs |
| `ci-logs/` | the job logs the claims are read from, gzipped because `.gitignore` excludes `*.log` |
| `templates/` | the two reference templates and the hive-mind best-practices document, at the two commits named in `SNAPSHOT.txt` — workflows, scripts and tests stored in full, plus `*.file-tree.txt` listings of every path so the file-tree comparison is answerable where the content is not stored |
| `probes/provenance-injection/` | four `docker buildx build` runs and their metadata files, which is what turned finding (a) from a theory into a chain |
| `upstream/` | the bodies of the reports filed on other projects, kept verbatim so this stays readable if one is edited or closed |
| `push-rejection/`, `apt-recommends/`, `playwright-deps/`, `cancelled-survey/`, `readme-updater/`, `doc-fragments/` | the transcripts behind findings (l), (e), (f), (i), (q) and (r) |
| `git-hooks/` | the mirror, cost and mutation measurements behind the pre-commit adoption (§13.2 row 8), including the false positive it found on its first run |

The survey in `run-conclusions/README.md` is worth stating on its own, because
it bounds the problem:

> **No run in 200 concluded `success` while holding a job that did not
> succeed.** The green half of the pipeline does not lie.

That is what made the 96 false annotations the interesting half. The pipeline
was not hiding failures behind green; it was spending failures on things that
had not failed, which costs the same thing — the next real annotation is one
more line in a list nobody reads.

---

## 1. Fifty-six failures printed by the commit that fixed something else

Release run 34293699247 finished with every build job green and 58 annotations
at level `failure` against those same green jobs. Fifty-six of them were one
string: the body of commit `a2e6420`, the issue #119 fix, which explains a
crash and quotes `##[error]Process completed with exit code 143.` while doing
so.

The path from a commit message to an annotation has four links, each verified
against the source it comes from:

1. `docker/setup-buildx-action` creates a `docker-container` builder. Since
   buildx v0.30.0 that driver writes the whole GitHub event payload into the
   builder container — `provenance.d/github_actions_context.json`, read whole
   from `GITHUB_EVENT_PATH` — at builder **create** time. That last detail is
   why the first attempt to reproduce this locally showed nothing: exporting
   `GITHUB_EVENT_PATH` for the build alone changes nothing, because the builder
   already exists (`probes/provenance-injection/build4.log`).
2. `provenance: false` does not stop it. That flag drops the attestation
   attached to the *image*; buildx still resolves provenance for
   `--metadata-file`, and the default `min` mode strips BuildConfig and Metadata
   only, so `invocation.environment.github_event_payload` survives.
3. `docker/build-push-action` prints that file verbatim:
   `core.info(JSON.stringify(metadata, null, 2))`. A JSON string value is one
   physical line, so an entire multi-paragraph commit message arrives as a single
   line of log with `##[error]` somewhere in the middle.
4. The runner matches the legacy form **anywhere** in a line.
   `ActionCommand.TryParse` uses `message.IndexOf("##[")`; `TryParseV2` trims and
   requires `::` at the start. The asymmetry is the whole exposure.

So any commit message quoting `##[error]` annotates the next release's builds as
failed. And `error` is not the worst of the registered commands: `stop-commands`
is in the same set, so a line the runner accepts can switch command processing
off for the rest of a step — from data that anyone who can write a commit
message, or a pull request title, controls.

**Fix.** `BUILDX_METADATA_PROVENANCE: disabled`, at *workflow* scope in all six
workflows that build, so a job added later inherits it rather than being the one
job whose log can be written by whoever wrote the last commit message. buildx
then writes no provenance to the metadata file at all — the
`resolving provenance for metadata file` step does not even run — so there is
nothing to print and nothing to misread. `min` is not an alternative: `min` is
what produced the annotations.

`provenance: false` stays on all ten build steps and `--provenance=false` on all
ten retry calls. The two settings govern different things, and dropping the
first would put `unknown/unknown` back into every published index — issue #119
arriving through a different door.

**Reported upstream**, because all three links are defects in projects that are
not ours: [buildx#4066](https://github.com/docker/buildx/issues/4066) (a user
who asked for no provenance still gets the webhook body),
[build-push-action#1612](https://github.com/docker/build-push-action/issues/1612)
(the file is handed to the runner unescaped; `docker/bake-action` has the same
line), and [actions/runner#4692](https://github.com/actions/runner/issues/4692)
(the V1/V2 asymmetry — `OutputManager` already strips `##[start-action` from
user output "to prevent injection", so the exposure is recognised; the
protection just stops short of the commands that annotate). Each carries the
reproduction, the workaround, and a fix suggestion in diff form.

**Tests.** `experiments/test-issue121-log-injection.sh` — 23 offline assertions:
the runner's V1 and V2 parse rules modelled in bash, a recorded metadata dump
scanned with them, and the workflow policy.
`experiments/test-issue121-provenance-metadata-leak.sh` — 11 assertions against
a real `docker buildx build`, showing the payload present by default, absent
with `disabled`, and still present under `min`.

Asserting the policy caught its own false negative first: `provenance: false`
carries a trailing comment in `release-full.yml`, so an anchored `$` in the
first draft reported two protected workflows as unprotected.

---

## 2. A warning for a package that architecture never had — and five it did

The same green release run carried 28 `warning` annotations, one per arm64 job,
all of them this:

```
##[warning]The command [sudo apt-get remove -y azure-cli google-chrome-stable
firefox powershell mono-devel libgl1-mesa-dri --fix-missing] failed to complete
successfully. Proceeding...
```

`jlumbroso/free-disk-space@v1.3.1` removes that fixed list of names. Google
publishes no arm64 apt repository, so on `ubuntu-24.04-arm` apt stops at
`E: Unable to locate package google-chrome-stable` and exits 100. The amd64 half
of the same release, on the same commit, removes all four packages present there
and says nothing (`ci-logs/job-js-build-amd64-102285690450.log.gz` line 1528
against its arm64 sibling).

The annotation was wrong in **both** directions at once, which is what makes it
worth a section:

- It reported the absence of a package on an architecture that never had it — a
  false positive, and the one [issue #108](../issue-108/CASE-STUDY.md) read as
  "benign by design … cannot be suppressed without forking the action".
- apt, having failed to resolve one name, removes **none** of the others in the
  same command. So the warning was simultaneously the only notice that every
  arm64 job was keeping the five packages the reclaim existed to take. The
  earlier reading was right about the mechanism and wrong about the cost.

**Fix.** The set apt should be given is "the packages matching the action's
patterns that dpkg reports installed", so that is what is computed.
`scripts/ci/reclaim-large-packages.sh` intersects the action's own 14 patterns
with `dpkg-query -W -f='${Package}\t${db:Status-Status}'`, skipping anything in
state `config-files`, and hands apt only names that resolve.
`.github/actions/free-disk-space` wraps the upstream action with
`large-packages: false` and runs the script instead, passing every other input
through with the upstream defaults, so all 15 call sites read as they did.

A failure now means apt could not remove something that *is* installed, which is
worth a warning — so it still emits one, with a title saying why it is worth
reading. The reclaim never fails the job: running out of disk is the build's
report to make, not the cleanup's.

**Tests.** `experiments/test-issue121-reclaim-large-packages.sh` — 47
assertions, including reading the two committed job logs, so the claims in the
table above are checked rather than remembered, and a policy check that no
workflow can reach the upstream action directly again.

---

## 3. The check that could only pass on 2026-09-08

The `Scripts` workflow is the one red run in the issue's table, and it had
failed on every commit since 2026-09-09 00:00 UTC. Nothing was wrong with what
it checks.

`experiments/test-issue119-image-tags.sh` asserts "the date tag defaults to
today in UTC". Its `run()` helper pins `IMAGE_TAGS_DATE=20260908` unless a test
overrides it, and the assertion tried to say "no date named" with
`unset IMAGE_TAGS_DATE` — which the helper cannot tell apart from "this test did
not name a date". So it re-pinned `20260908` and compared it against
`date -u +%Y%m%d`:

```
FAIL: the date tag defaults to today in UTC
  got: latest 2.7.0 20260908 fd4742b
```

The assertion never exercised the default it names. It passed on exactly one
day, and reported working release tooling as broken every day after — a false
positive with a fuse in it.

**Fix.** The helper takes `UNPINNED=1` to mean "use the script's own defaults",
which has to be said out loud precisely because unsetting cannot say it. The
assertion reads the day on both sides of the call and accepts either, so a run
straddling midnight UTC is the script working rather than a flake waiting to
happen. `scripts/release/image-tags.sh` is unchanged — it was correct.

**Guard.** `experiments/test-issue121-clock-independence.sh` puts a `date` stub
first on `PATH` (forwarding to the real `date` with `--date=@epoch` prepended, so
a caller naming its own date still wins), **discovers** every suite that reads
the clock rather than listing them, and runs each at 2020-01-01, 2030-12-31 and
23:59:30 on a New Year's Eve. It also checks that the stub actually moves the
clock, so a green result is not vacuous.

Verified to fail on the pre-fix tree with the exact CI message at all three
clocks, and to pass after.

---

## 4. A threshold below what the repository already satisfied

`.hadolint.yaml` failed at `warning`, one step looser than hadolint's own
default, and all ten findings in this repository are `info`: nine DL3015 and one
DL3059. Every run printed them as GitHub notices and no run could ever go red on
one, which is the same thing as not checking.

The runner made the gap invisible in the other direction too. It mapped
error/warning to `::error` and everything else to `::notice` beside a threshold
it never read — so *lowering* the threshold would have produced a failing run
whose every annotation said "notice".

**Fix.** DL3015 was resolved per site, measured rather than blanket-ignored,
because in a development environment a "recommended" package is a tool the user
expects to find. `experiments/measure-issue121-apt-recommends.sh` resolves each
apt plan twice inside `ubuntu:24.04` and diffs them:

| site | with | without | what `--no-install-recommends` drops |
| --- | --- | --- | --- |
| `essentials-box:32` (acl) | 1 | 1 | nothing |
| `rocq:11` (bubblewrap) | 1 | 1 | nothing |
| `js:27` (Playwright/Puppeteer) | 136 | 71 | systemd, dbus-user-session, python3, … |
| `js:17` (curl git sudo …) | 53 | 32 | openssh-client, less, patch, netbase, … |
| `php:47` (php-cli …) | 50 | 43 | ca-certificates, openssl, … |
| `Dockerfile:62` (r-base cmake clang …) | 379 | 149 | build-essential, gcc, g++, make, perl, … |

The flag is added where it is a measured no-op and where upstream itself passes
it — Playwright's `dependencies.ts` installs its list with
`--no-install-recommends`, which is what makes that list complete without
recommends by construction. It is **not** added where the recommends are the
product: `openssh-client` is how a box clones a private repository over `ssh://`,
and dropping `build-essential` from the full box would leave `r-base` unable to
compile a CRAN package. Each of those sites carries `# hadolint
ignore=DL3015` with the measurement written above it, so the rule stays active
for every Dockerfile added later.

With all ten resolved the threshold moves to `info`, hadolint's default, the
gate exits 1 on the next finding, and the annotation level is derived from the
config instead of from a parallel table.

---

## 5. The browsers that shipped without the libraries they link against

`playwright install` prints, on both JS build jobs of the same release run:

```
Playwright Host validation warning:
║ Host system is missing dependencies to run browsers. ║
║     sudo apt-get install libavif16                   ║
```

and exits 0. Both jobs went green, because nothing reads a warning. So
`konard/box-js` shipped browsers linked against a library the image does not
have, and every check said fine.

Compared against Playwright's own `deps['ubuntu24.04-x64']`,
`ubuntu/24.04/js/Dockerfile` was **seven** packages short:
`fonts-tlwg-loma-otf`, `fonts-unifont`, `libavif16`, `libicu74`, `libx264-164`,
`xfonts-cyrillic`, `xfonts-scalable`. Only `libavif16` surfaced in the log,
because host validation `ldd`s the browsers that were actually downloaded — the
other six were equally absent and equally unreported. That is the shape worth
naming: **the warning was not the finding, it was one visible corner of it.**
`deps['ubuntu24.04-arm64']` is a straight copy of the x64 entry, so one list
covers both architectures the release builds.

**Fix.** All seven are installed, and `assert_no_playwright_host_warning` in
`ubuntu/24.04/common.sh` turns the warning into the build failure it is, naming
the packages on one line so the fix is readable from the job summary.
`JS_ALLOW_PLAYWRIGHT_HOST_WARNING=1` downgrades it, for the case where Playwright
adds a dependency Ubuntu has not published yet. Default off.

**Tests.** `experiments/test-issue121-playwright-deps.sh` holds the Dockerfile
against a recorded copy of the upstream list — offline, so it runs in the normal
tier rather than only where Docker and a network are. 89 assertions; deleting
`libavif16` from the Dockerfile fails it with the line to paste back. Three real
builds recorded in `playwright-deps/` show the warning before, no warning after,
and the mutation failing with exit 1 — which is the evidence that the new
assertion can fail at all.

---

## 6. Two audits that reported "no findings" about files they never opened

**The scope.** The `zizmor` job scanned `.github/workflows` and nothing else, so
the four composite actions under `.github/actions/` had never been read by any
linter. Widening the scope surfaced a High-confidence `template-injection` in
`dockerhub-login/action.yml:93`: `${{ inputs.registry }}` interpolated straight
into a `run:` block, substituted before bash parses the line. A composite action
executes inside the calling job, holding that job's credentials, so the
exclusion had it exactly backwards. The value reaches the script through
`env: REGISTRY` now, where it is data whatever it holds.

**The policy with no auditor.** `.github/zizmor.yml` declares `'*': hash-pin`.
The audits that read container image references — `unpinned-images` among them —
are **Pedantic persona only**, and the job ran the default `regular` persona. So
the policy was never applied to `uses: docker://` or `container:` at all, and
`docker://rhysd/actionlint:1.7.7` — a mutable tag of a repository we do not
control, run in a job that checks out the tree — passed every run since the
policy was written.

A declared policy that no mechanism enforces is the documentation-shaped version
of a check that cannot fail. A second pass floored at high severity **and** high
confidence restores the enforcement without importing pedantic's several hundred
stylistic findings; measured, it reports nothing once the image is pinned by
digest, verified against the registry with `docker buildx imagetools inspect`.

**And then the pin froze the wrong thing.** The first digest written here was
`sha256:887a259a…`, resolved from whatever the mutable tag pointed at, which
was v1.7.7 — January 2025. That closed the supply-chain hole and opened a
quieter one, because *a digest pin freezes the check set, not just the binary*.
The version an image reference resolves to stops being an implementation detail
the moment it can no longer drift: it becomes an invariant of the gate, and
nothing in the repository stated it.

What v1.7.7 could not report turns out to be this issue's own subject three
times over — each one a workflow that never runs, which is a check that cannot
fail wearing a different costume:

| Check | Added | What it reports |
|---|---|---|
| `glob` | v1.7.11 | a `paths:` entry beginning with `./` matches nothing, so the workflow never starts |
| `if-cond` | v1.7.9, extended v1.7.10 | `if: false` on a job that is still listed in the status gate's `needs` |
| `runner-label` | v1.7.8, v1.7.10 | a label GitHub has removed, so the job never starts |

`experiments/reproduce-issue121-actionlint-version-gap.sh` runs both pinned
images over one fixture per check plus a YAML merge key. v1.7.7 reports **one**
finding and describes it wrongly — it calls the merge key a node-type mismatch
and stops parsing that file there, which is why the fixtures are four separate
files; v1.7.12 reports **four**, including that GitHub Actions ignores `<<`
outright. Against this repository as it stands both are clean, so the bump costs
nothing today and is the only thing here that can make those three findings: the
`paths:`-coverage gate cannot see a dead entry that has a live sibling, because
it asks whether every input path is covered by some pattern, not whether every
pattern covers something.

The floor is asserted offline rather than left to the comment that explains it.
`test-issue121-workflow-audit-scope.sh` reads the version out of the `# v…`
trailer, fails below v1.7.11, and fails when the `docker run` line in the same
comment documents a different version than the pin — two places naming a linter
independently is how a local reproduction and a CI run end up disagreeing about
what passed. That had already happened once: `test-issue115-ci-policy.sh` was
still running the mutable tag `rhysd/actionlint:1.7.7` while the workflow had
moved to a digest, so the suite asserting the CI policy was not running the CI
policy's analyser. It reads the image out of the workflow now. A third assertion
sweeps `scripts/` and `experiments/` for any other command naming a version of
its own, excluding comments — the history of a pin is worth recording, and a
sentence about v1.7.7 does not run an analyser.

**The assertion that could not fail either.** The suite written to hold the
first of those two fixes in place — "no `run:` block in a composite action
interpolates a `${{ }}` expansion" — extracted the block like this:

```bash
awk '/^\s+run: \|/,0' "$ACTION" | grep -q '\${{'
```

That one line is wrong twice, in opposite directions.

`\s` is a GNU extension. POSIX awk does not define it, and mawk — the default
`awk` on Debian and Ubuntu, and therefore in every container the rest of these
checks shell into — does not implement it. It is not a syntax error: mawk
compiles the pattern, matches nothing, and says nothing. The range never opens,
awk prints nothing, `grep -q` finds nothing, and the negated test passes. On the
machine a developer runs it on, the check could not fail.

GitHub's `ubuntu-24.04` image ships gawk, where `\s` works — and there the
second defect takes over. A range `/x/,0` never closes, because no record is
ever numbered 0, so the "run block" is everything from the first `run: |` to end
of file: every later step's `with:` and `env:` mapping. Passing an input to an
action through `with:` is not an injection, so the job failed, in CI only,
naming lines that were correct.

Three answers — silent, correct, wrong — from one line, decided by which awk was
installed, and the silent one is the one on the developer's machine.
`experiments/reproduce-issue121-awk-run-block-range.sh` demonstrates both halves
under whichever awk is present, and runs in CI as an assertion rather than as a
note.

The extraction is bounded by indentation now, which is where a YAML block scalar
actually ends, and it covers all four composite actions rather than the one:
`.github/actions/*/action.yml` is clean, and mutating any of them to interpolate
inside a `run:` block fails the suite with the file and line. The workflows are
a separate question — they carry 220 expansions inside `run:` blocks, matrix
values and this repository's own step outputs — which is what the medium/medium
zizmor pass above judges; widening the assertion to them would be a rewrite, not
a check, and the case study says so rather than quietly scoping the assertion
down to one file again.

The class is worth more than the instance, because nothing warned:
`scripts/ci/check-awk-portability.sh` reads every awk program in every tracked
file — quote-aware, so a `\s` in the `sed` on the far side of a pipe is not
reported, and command substitution inside a double-quoted string is code again,
which is precisely the shape the first version of that scanner missed — and
fails the run on `\s \S \w \W \d \D \< \> \y`. Naming `gawk` explicitly
is the supported way to depend on them. A `# awk-portability: ignore` line
suppresses one finding, and suppressions are counted and printed.

**Tests.** `experiments/test-issue121-workflow-audit-scope.sh` — 23 offline
assertions, mutation-verified: unpinning the image, narrowing the scan back to
`.github/workflows`, reintroducing the interpolation and lowering the version
floor each fail the suite,
and the extractor is itself exercised against a fixture that interpolates and
one that does not. `experiments/test-issue121-awk-portability.sh` — 28
assertions covering six escapes that must be reported, nine constructs that must
not, the command-substitution shape the scanner originally missed, the
suppression, and the repository sweep.

---

## 7. Grey is not red

GitHub folds job conclusions into a run conclusion by rank, and a cancellation
outranks a failure. Run 34259552358 concluded `cancelled` while
`pr-tests / pr-test / dind-full` had concluded `failure` 26 minutes earlier:

```
run conclusion                     cancelled
pr-tests / pr-test / dind-full     failure     (20:34:56Z, on its own)
pr-tests / pr-test / full          cancelled   (21:00:52Z, with the run)
```

It is the only such run in the last 200, and it *was* superseded — the commit it
tested was two behind the pull request's head — so grey was a defensible colour
that time. What makes it worth a gate is that **nothing in the colour said so**.
A job cancelled on its own — a `timeout-minutes` overrun, or one of this
repository's 14 per-job `concurrency: cancel-in-progress` groups firing —
produces exactly the same grey with no such excuse.

**Fix.** `scripts/ci/check-pipeline-status.sh` (a shell port of the reference
template's) is a job whose own conclusion carries the verdict, because a gate
job's conclusion *is* a job conclusion: when it errors, the run is red no matter
what else was cancelled. A failure is always an error; a cancellation is an error
only when this run is still the head of its branch, and a warning otherwise,
which is the difference between an overrun and a supersede. An unresolvable head
counts as "not superseded" — a missed supersede costs one noisy error, a missed
overrun costs a silent failure.

It selects failures **by exclusion** rather than by name, so a result spelling it
has never heard of (`timed_out`, `action_required`, both of which the jobs API
reports and the `needs` context does not document) fails rather than reading as
"nothing wrong".

The gate is `if: ${{ !cancelled() }}`, never `always()`, and the survey is why:
all ten cancelled runs in the sample were whole-run supersedes, and painting
those red would have been ten false positives — the opposite of what this issue
asks for. `cancelled()` is run-level, so the cases with no such excuse still
arrive.

**A gate is only as good as its `needs`.** A job left out of it is invisible by
construction, which is the failure mode that would quietly undo all of this six
months from now. `scripts/ci/check-status-gate-covers-all-jobs.mjs` derives the
list from each workflow instead of trusting a written one, and the `actionlint`
job runs it: adding a job to any workflow now fails CI until the gate names it.
Workflows that only ever run via `workflow_call` are exempt — their conclusion
propagates to the job that calls them, which a caller's gate already covers.

`release-dind.yml` was the one release family without a `status` job or
`workflow_call` outputs; it has both now, mirroring `release-languages.yml`.
Those four `status` jobs summarise and deliberately do **not** assert: they feed
`on.workflow_call.outputs`, and a job that fails or is skipped empties the
outputs it reports, which would break the honest partial release from issue #115.
Reporting and gating are different jobs on purpose.

**Tests.** `experiments/test-issue121-pipeline-status-gate.sh` — 67 offline
assertions. Fixture `needs` payloads drive every branch including the measured
shape of run 34259552358; mutation workflows prove the coverage check reports a
job left out of a gate by name and refuses an entry-point workflow with no gate
at all; and the third part **discovers** the entry-point workflows from their
triggers rather than listing them, so a new one cannot be added without a gate.

Fixing this broke a check that was documenting it: invariant 4 of
`test-issue115-ci-policy.sh` grepped the raw workflow text for `always()`, so a
comment explaining *why* a job uses `!cancelled()` failed the policy it was
explaining. It reads evaluated expressions now, not prose.

---

## 8. A backstop is not a deadline

`timeout-minutes` is the only per-step and per-job deadline GitHub offers, and it
cannot report. When it fires, GitHub reports the job as **cancelled**: the run
goes grey rather than red (section 7), the job stops where it stands so every
`if: always()` and `if: !cancelled()` reporting step is skipped, and the
annotation names neither the step nor the number that was exceeded.

The gate from section 7 turns that grey red. It still cannot say more than "the
job was cancelled", because no step owned a deadline. Now 22 of them do, via
`scripts/ci/run-with-budget-warning.sh`: `::warning` at 70% of the budget,
`::error` naming the label and the budget at 100%, SIGTERM to the process group,
then SIGKILL, exit 124.

A step has to *be* a command to be wrapped, so the five inline build blocks in
`pr-tests.yml` became `scripts/ci/build-chain.sh` — which also settles a drift
between the copies, one of which tagged the full box `box-test` where another
called the same image `box-full`, and derives the language list from the full
box's own Dockerfile instead of repeating it.

**The caps themselves were guesses, and not close ones.** Every one is now sized
from `scripts/ci/measure-job-durations.sh`, which reads the longest each job has
ever taken to *succeed*:

| job | slowest success | old cap | new cap |
|---|---|---|---|
| `pr-test` (js) | 7.9 min | 30 | 20 |
| `pr-test` (full) | 43.0 min | 90 | 90 |
| release `docker-build-push` | 35.6 min | 120 | 90 |
| `build-dind-amd64` | 19.2 min | 30 | **40** |
| `measure-disk-space` | 23.3 min | 180 | 60 |

A cap far above the work it bounds is not free caution — it is how many minutes
a hung job burns before anyone hears about it. `measure-disk-space` carried
`180  # 3 hours max for full installation measurement` against a slowest-ever
run of 23.3. One cap went **up**: `build-dind-amd64`'s slowest leg was at 64% of
its 30 minutes, too close to leave.

`scripts/ci/check-timeout-budgets.mjs` keeps it that way. A budget at or near its
cap is a check that can never fire, so each budget — and the budgets that can run
*together* in one job — must stay under 70% of it. Two rules beyond the template
it is ported from:

- **A budget the checker cannot read fails the check** rather than passing it.
  An unreadable value is the one case where silence is indistinguishable from
  compliance.
- **Every leg of a matrix is evaluated on its own terms.** This repository sizes
  both caps and budgets per leg (`${{ matrix.variant == 'full' && 90 || 60 }}`),
  so the checker enumerates the matrix and evaluates a restricted GitHub
  expression grammar for caps and `if:` conditions alike. A worst-case reading
  would charge `pr-test-dind` for all fourteen variants at once — a failure no
  run can produce, and a false alarm on every run trains people to ignore the
  check.

The full rule, the measured tables and the re-measuring procedure are in
[docs/CI-TIMEOUT-BUDGETS.md](../../CI-TIMEOUT-BUDGETS.md).

**Tests.** `experiments/test-issue121-timeout-budgets.sh` — 39 offline
assertions, every checker fixture in both a passing and a failing form. One of
them found a real subtlety: `kill -0` succeeds on a **zombie**, so the assertion
that an over-budget command's grandchild dies has to read the process state
rather than signal it — the same distinction the wrapper makes for its own
completion check, and the reason it uses a status file.

---

## 9. A retry that never applies, and the fix that would have gone blind

lychee classifies an error by the **phase** it happened in, and answers `false`
for the connect phase — so `--max-retries` never applies to a connection reset
([lycheeverse/lychee#2297](https://github.com/lycheeverse/lychee/issues/2297)).
A healthy host that resets one connection — routine for a CI address range
talking to a rate-limiting or load-shedding host — is reported broken without a
retry, and the links gate fails on it.

The cheap fix for that false positive is an `.lycheeignore` entry, and it is
worth spelling out why it is the wrong one: it converts a false positive into a
**permanent false negative**, because a real 404 on that host is now silent
forever. Every entry in that file is a check that has been switched off.

**Fix.** `scripts/ci/recheck-broken-links.mjs` asks those URLs again, outside
lychee, and only those: a failure carrying a status code means a host answered,
and its answer is final. `check-web-archive.mjs` then skips what the re-check
recovered, rather than looking a healthy URL up in the Wayback Machine.

Ported from the reference template, with **one deliberate divergence**. The
template writes `all_recovered=true` whenever every *unanswered* failure
recovered, without looking at the answered ones, and its `links.yml` gates both
the archive step and the failing step on `all_recovered != 'true'` — so a report
holding one 404 **and** one connection reset ends green with the 404 in it.
Reproduced verbatim against fresh clones of both templates that carry the
script:

```
Re-check: 2 lychee failure(s), 1 answered and final, 1 never got an answer
Re-check finished: 1 recovered, 0 still without an answer
== $GITHUB_OUTPUT ==
all_recovered=true
```

with `https://example.com/definitely-gone/` still an unforgiven `[404]` in the
report that `links.yml` was about to stop failing on. Filed as
[js#184](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/184)
and
[rust#170](https://github.com/link-foundation/rust-ai-driven-development-pipeline-template/issues/170),
each with the reduced offline reproduction, the two-condition fix, a
`links.yml`-only workaround, and the note that the other templates have no
re-check step to be wrong about yet. Here, `all_recovered` means the whole
report was noise.

**Tests.** `experiments/test-issue121-links-recheck.sh` — 39 assertions,
offline, where the "network" is a `python3 http.server` on `127.0.0.1`.

This gate also produced the one **true** positive of the branch, which is the
reason this file exists: `docs/case-studies/issue-108/CASE-STUDY.md` links twice
to this case study, and the `links` workflow failed on every run of the branch
until it was written.

---

## 10. A concurrency group orders writers; it does not rebase them

Three jobs wrote to `main` with a bare `git push origin main`: the release
workflow's version bump, `scripts/release/apply-changesets.sh`, and the
disk-space measurement commit. `actions/checkout` checks out `github.sha`, so
the second writer in the queue is behind the branch the instant the first one
lands. The measurement job runs about 18 minutes before it pushes, which is a
wide window to lose.

And the two rejections that matter print the same word. Reproduced against local
bare repositories (`push-rejection/`):

```
 ! [rejected]        HEAD -> main (fetch first)                 -> rebase fixes it
GH013: … Changes must be made through a pull request            -> no rebase ever will
```

Case 4 of that reproduction is the one that decides the design: a single push
where one ref is behind **and** another is rule-declined puts both signals in one
capture. Classify it as a race and the job rebases, the rebase succeeds, the
second push is declined identically, and the log blames a race that never
happened — after the version has already been committed on the runner.

**Fix.** `scripts/release/git-push-failure-classifier.sh` tests for a rule
**before** it tests for a race. `git-push-with-retry.sh` answers a rule with the
thing the rule asks for: a pull request, merged with `--merge` (a repository's
`allowed_merge_methods` may be `["merge"]` only), on a branch whose name carries
`GITHUB_RUN_ID` and is never reused or deleted (a `non_fast_forward`/`deletion`
rule on `~ALL` forbids both). On success it fast-forwards the checkout so the
rest of the job runs unchanged. Anything that is neither — auth, network, a
missing remote — fails the job and says so, rather than being retried as a race.

**Tests.** 52 offline assertions: `test-issue121-git-push-recovery.sh` (33)
drives the real scripts against stub `git`/`gh` binaries for all six outcomes,
and the reproduction (19) re-derives the strings from a live `git` rather than
from memory, so a future git that rewords a rejection fails here and not in a
release. Mutation-verified: dropping the rule-first guard, dropping the race
patterns, reintroducing a bare push, and rebasing on a rule rejection each fail
the suite.

---

## 11. Cleaning up a machine that is about to be destroyed

The last annotation on the green release run:

```
[command]/usr/bin/docker buildx rm builder-1e6b2f9a-…
failed to remove node builder-…0: Delete "…/volumes/
buildx_buildkit_builder-…0_state": context deadline exceeded
##[warning]ERROR: failed to remove one or more builders
```

20.05s between the command and the error, on buildx v0.36.1. That number is the
client's `--timeout`, which buildx's own `commands/root.go` documents as "the
default timeout for loading builder status" — and which v0.36.0 began applying to
the removal itself, so deleting a state volume holding a full-box build cache is
cut off mid-flight. The builder entry is dropped from the store regardless, which
leaks the volume: nothing is left that can name it.

`experiments/issue-121-buildx-rm-timeout/` reproduces it against the real daemon
without CI and without a large cache, with a proxy in front of the Docker socket
that forwards every byte unchanged and stalls only `DELETE /<api>/volumes/…`.
v0.36.1 fails at 20s while the delete is still in flight; v0.35.0 waits and exits
0. Bisected, and pinned to the one-line change `rm(ctx, …)` → `rm(timeoutCtx, …)`
in commit `8db02212`, which made the same change in `rmAllInactive`, so
`--all-inactive` inherits it too. Both `--timeout 0` and `--timeout 60s` fix it.

**Fix.** Not to make the removal faster: on a GitHub-hosted runner the whole
machine, volume included, is destroyed seconds later, so the cleanup had nothing
to clean. The composite passes `cleanup:` down — empty input means the runner
decides, `runner.environment != 'github-hosted'`, so a self-hosted runner that
outlives the job keeps the removal — and a caller can still force either answer.
All ten buildx setups in this repository go through the composite, which is
itself an assertion now: `experiments/test-issue121-buildx-cleanup.sh` fails if a
workflow reaches for `docker/setup-buildx-action` directly, and evaluates the
expression under GitHub's own truthiness rules rather than trusting the comment
next to it.

**Reported upstream** as
[buildx#4067](https://github.com/docker/buildx/issues/4067) and
[setup-buildx-action#615](https://github.com/docker/setup-buildx-action/issues/615)
— the action's post step builds the argv itself, passes no timeout, and turns
the resulting stderr into a `core.warning` while ignoring the exit code, which is
where a CI user actually meets this.

---

## 12. The cheapest place to find any of this

Every finding above was found by reading a run that had already happened. The
reference templates' best practice #8 says the obvious thing about that: the
same check costs seconds on a laptop and minutes on a runner, and the difference
is not the money, it is that the developer is still holding the change in their
head. Box had adopted fifteen of the sixteen practices; this was the one left,
recorded until now as "not adopted — the template's `install-git-hooks.mjs`
assumes a `package.json` lifecycle this repository does not have".

That reasoning was right about the tool and wrong about the practice. husky and
lint-staged need an npm project; `core.hooksPath` and `git checkout-index` need
git, which is already a hard dependency of every one of these scripts. So the
hook is `.githooks/pre-commit`, eleven lines, delegating to
`scripts/ci/run-precommit-checks.sh`, which runs the same ten gates CI runs, with
the same arguments, over the same content.

**The same content is the whole design.** `git commit` records the index, not the
working tree, and the two differ whenever somebody uses `git add -p`, or fixes
something after staging it. A hook reading the working tree is wrong in both
directions — it passes a commit that breaks CI when the fix is unstaged, and
fails a commit that is fine when the breakage is unstaged — which is this
issue's defect class, reproduced by the thing meant to prevent it. So the gates
run inside a throwaway mirror of the index: `git ls-files -z | git checkout-index
-z --stdin --prefix=…`, then `git init && git add -A -f`. Measured at 1357 ms for
658 files. lint-staged solves the same problem by stashing unstaged changes in
the real worktree; a mirror was chosen because a crash mid-run then leaves
nothing to recover.

`add -A -f` is load-bearing rather than defensive. Without `-f`, `.gitignore`'s
`*.log` drops the ten tracked `docs/case-studies/*/ci-logs/*.log` files and every
gate silently sees 648 files instead of 658 — a checker quietly not checking
something, which is finding (g) in a different costume. `dev/log/` stays in the
mirror for the same reason: it is where downloaded CI logs land, which is where
an accidentally pasted token would land, so the secret scan has to see it.

Three rules keep the hook from becoming a liability of its own:

- **It does not rewrite files.** lint-staged runs `prettier --write` and re-adds
  the result, which means `git commit` records something the author never read.
  Formatting failures print `run-shfmt.sh --fix` instead.
- **A gate that cannot run does not block.** No docker, no node, no network for
  `npx` — that is `could not run: <label> (exit N) — CI will run it`, and the
  commit proceeds. Blocking somebody because their docker daemon is down is a
  false positive with no defect behind it.
- **The hook is never the only place a check exists.** Part 7 of
  `experiments/test-issue121-git-hooks.sh` derives the gate list from the script
  itself and asserts that each one is also invoked by a workflow, so the previous
  rule can never turn into a hole.

The installer ports the template's *insight*, not its code. `install-git-hooks.mjs`
carries the comment that husky "exits 0 even when it fails", so the template
verifies the outcome afterwards instead of trusting the exit code. The same is
true of `git config --local core.hooksPath`, and of git silently ignoring a hook
that is not executable — so `scripts/install-git-hooks.sh` reads the key back and
stats the hook, and exits 1 with an annotation if either disagrees.

**It found a false positive on its first real run**, which is the argument for it
in one line. It failed `heredoc-vars` on its own test suite, claiming `$EXITS`
leaked out of a quoted heredoc. It does not: the suite writes
`export RECORD=… EXITS=…`, and pass 1 of `check-heredoc-vars.sh` matched the
keyword plus exactly one name, so every variable after the first in any `export`
statement looked unset to it. A gate that fails a correct commit is what this
issue is about, and it had been latent in the tree since the gate was written.
`collect_exports()` now walks the whole statement, tracking quote state so a
value containing spaces does not hide the names after it, and stopping at the
first token that is not a name so `export -f helper` still registers nothing.
Four fixtures hold both directions.

Cost, for a commit touching shell: about 14 s, of which secretlint is 3.9 s and
the two shell linters are 4.7 s. A markdown-only commit runs neither linter and
takes about 5 s. Gates are scoped by what is staged, `git commit --no-verify` and
`BOX_SKIP_HOOKS=1` are both documented by the failure itself, and
`docs/LOCAL-CHECKS.md` gives the copy-pasteable command for every gate for the
case where somebody would rather not install anything at all.

`experiments/test-issue121-git-hooks.sh` is 80 assertions with every gate stubbed
as a recorder, so it asserts *which* gate saw *which* content — including a
staged-versus-worktree pair proving the index is what is read, a tracked file
matching `.gitignore` proving `-f`, an initial commit with no `HEAD`, and a stub
`git` that accepts `config core.hooksPath` and drops it, reproducing husky's
"exit 0, did nothing" against our installer. Four mutations of the shipped
scripts each produce exactly one intended failure
(`dev/log/issues/121/pulls/122/git-hooks/`).

---

## 13. The requirement list, item by item

Issue #121 has three requirements, and the third is the one that generates work
after this pull request is merged: *"We should compare all files, so we don't
have more CI/CD errors in the future and reuse all the best practices from these
templates."* Both template trees were cloned and recorded verbatim under
`dev/log/issues/121/pulls/122/templates/` so the comparison is against a fixed
state rather than a moving one.

### 13.1 Every false positive, false negative, warning and error

| Requirement | Where it landed |
|---|---|
| No annotation that does not mean what it says | §1 (56), §2 (28), §11 (1) — 85 of the 96 removed at the source; §4's ten notices resolved and the threshold lowered with them. The 96th is lychee's own "Summary report available at", which is what a notice is for. §5's warning was never an annotation at all, which is exactly why nothing caught it |
| No check that cannot fail | §4 (hadolint threshold), §6 (zizmor scope and persona), §5 (Playwright warning), §8 (a budget above its cap) |
| No check that can fail for a reason unrelated to what it checks | §3 (the clock), §9 (a connection reset), §10 (a race that was a rule), (m) and (n) in the summary table |
| A red run must be reachable from a failed job | §7 — a terminal gate in every entry-point workflow, and a checker that keeps its `needs` complete |
| A long step must be able to report its own overrun | §8 — 22 wrapped steps, caps measured, budgets checked per matrix leg |

### 13.2 The hive-mind best practices, against this repository

Read from `templates/hive-mind-CI-CD-BEST-PRACTICES.md` as it stood on
2026-09-09.

| # | Practice | State |
|---|---|---|
| 1 | Run checks only on relevant file changes | Already held — every workflow carries `paths:`, and `scripts/ci/detect-changes.sh` scopes the rest |
| 2 | File size limits | Already held — `file-sizes.yml` with `check-file-line-limits.sh` (1500 hard, 1350 warn) |
| 3 | Automated code formatting | Already held — `shfmt -i 2 -ci -bn` over every tracked script |
| 4 | Static analysis and linting | Extended here — shellcheck and hadolint were already gates; §4 made hadolint's gate able to fail, §6 gave zizmor the files and the persona it needed |
| 5 | Fast-fail job ordering | Already held — the `scripts`, `file-sizes` and `workflows` checks are minutes; the builds are the tail |
| 6 | Changeset-based versioning | Already held — `.changeset/`, `check-changesets.sh`, `apply-changesets.sh` |
| 7 | Validate the actual merge result | Already held — `.github/actions/simulate-fresh-merge` in every check job |
| 8 | Pre-commit hooks | **Adopted in full here** — not the template's tool. `install-git-hooks.mjs` drives husky, which needs a `package.json` lifecycle this repository does not have, so the same guarantee is built from `core.hooksPath` and `git checkout-index` alone: `.githooks/pre-commit` → `run-precommit-checks.sh`, ten gates over the **index**, ~14 s. See §12 |
| 9 | Release automation | Already held — `release.yml` and its five called workflows |
| 10 | Concurrency control | Already held — 14 per-job groups plus `scripts/ci/supersede.sh`; §7 is what makes a cancellation from one of them visible |
| 11 | Secrets detection | Already held — `secretlint` in `security.yml` |
| 12 | Documentation validation | **Adopted in full here** — `links.yml` with the Wayback fallback (§9), now checking anchors as well as documents (finding **r**), plus `check-required-docs.sh` in a new `docs.yml` for the half no link checker can do (finding **s**) |
| 13 | Container images: native runners per architecture | Already held — `ubuntu-24.04-arm` for every arm64 job, which is how §2 was found at all |
| 14 | Lint the workflows themselves | Already held and now complete — actionlint with shellcheck inside the image, zizmor over workflows *and* composite actions |
| 15 | Audit the dependency tree | Held differently — no package manifest exists here; CodeQL and `assert-base-image.sh` are the equivalents |
| 16 | Prove you can publish before you build | Already held — `preflight-credentials.sh` and `registry-probe.sh` run before the release builds |

### 13.3 Template files with no counterpart here

Adopted in this pull request, ported rather than copied:
`check-pipeline-status.sh` (§7), `check-status-gate-covers-all-jobs.mjs` (§7),
`recheck-broken-links.mjs` (§9), `run-with-budget-warning.sh` (§8),
`check-mjs-syntax.sh`, `check-required-docs.sh`. `install-git-hooks.mjs` is the
one adopted at the level of the idea rather than the file, for the reasons in
§12.

The last one is finding **p**, and it is worth stating why a repository of
Dockerfiles and shell needs a JavaScript gate at all. `git ls-files '*.mjs'`
outside `dev/log/` and `docs/` returns fourteen files. Ten of them are named by
no workflow and no suite: the seven ranking fetchers under
`scripts/language-tops/` and the three `.mjs` probes in `experiments/`. Nothing
read them, because every shell gate here discovers `*.sh` and
`run-experiments.sh` discovers `experiments/*.sh`. Of the four that CI does
execute, two — `recheck-broken-links.mjs` and `check-web-archive.mjs` — run only
when `links` has already failed, so a syntax error in them would surface on the
one run that needed them and on no run before: a recovery path that is only
exercised in the emergency it exists for.

The port keeps `node --check` and changes two things. Discovery is
`git ls-files`, not the template's three hard-coded directory names, so a module
added anywhere is covered by the fact of being tracked. And a missing `node` is
exit 2, not a skip — the template's version would report success on a runner
without an interpreter, which is finding **h**'s shape.

One rule was added rather than ported: every *relative* import specifier must
resolve to a file that exists. `import { x } from './helpers.mjs'` after
helpers.mjs is renamed parses perfectly and throws `ERR_MODULE_NOT_FOUND` on
first load — the same dormant-until-needed failure one level up from syntax.
Bare specifiers are left alone: there is no `node_modules` here to resolve them
against, and resolving them against the runner's would make the gate report on
the machine instead of the tree. No module in this repository imports a relative
path today, so the rule is proved by fixtures rather than by the sweep —
`experiments/test-issue121-mjs-syntax.sh`, 31 assertions, of which three feed it
a specifier that resolves to nothing and four feed it specifiers it must leave
alone.

`check-required-docs.sh` is finding **s**, and the port changes more than the
mjs one did, because what a document owes the code is not the same in the two
repositories. The template checks that a fixed list of files exists. Here the
list is a table of file **and headings**, because two scripts read a heading at
runtime: `update-readme-sizes.sh` looks for `## License` and falls back to
`## Documentation` to decide where the generated component-sizes section goes,
and `preflight-credentials.sh` sends an operator to "the 'Releasing' section of
README.md" when a credential is rejected. Both of those are load-bearing strings
in a shell script pointing at a markdown heading, which is a dependency with no
compiler and, until now, no gate. Three rules follow from that: the heading must
match exactly (`## Licensing` and `### Releasing` are both failures — the first
is what a rename looks like, the second is what a demotion looks like, and the
`grep -Fxq "## $section"` that finds neither is the point), the component-sizes
marker pair must exist exactly once and in order, and every `docs/…md` path
named in `scripts/` or `.github/` must resolve to a tracked file.

That last rule is drawn narrowly on purpose, and the boundary was measured
rather than guessed. Matching any bare `NAME.md` fired on the checker's own
prose; broadening to any `dir/NAME.md` added `lychee/out.md` — an artefact path
that exists only mid-run — and the repository's own `README.md` from a
`$REPO_ROOT/README.md` expansion. `docs/…` is the prefix that means "a document
in this tree", so that is the prefix the rule uses; the excluded shapes are
asserted as out of scope in the fixtures, not left to be rediscovered. Two
defects in the checker were caught by its own fixtures before it was wired up: a
`grep` that found nothing inside a `while` loop aborted the loop under
`set -euo pipefail`, so the sweep reported OK after reading 3 files instead of
61; and `grep -oE '(^|[^A-Za-z0-9_/-])…'` matches nothing at all under GNU grep
3.11 while `( |^)` matches — a false negative that would have made the whole
rule inert.

It runs in a new `.github/workflows/docs.yml` rather than in `links.yml` or
`scripts.yml`, because it is the only gate whose input is both the markdown and
the shell: in `links.yml` a one-line change to a script would fetch every
external host in the corpus, and in `scripts.yml` a typo in a case study would
run shellcheck, shfmt and 68 experiment suites. The new file is also why
`test-issue115-fresh-merge.sh` now derives its list from the workflow directory
instead of from `list-release-workflows.sh` alone: a standalone check workflow
is not reachable from the release entry point, so adding one without
`simulate-fresh-merge` was a gap that suite could not see. Verified by adding a
throwaway workflow and watching it fail.

### 13.4 `security.yml`, `release.yml`, and the invariants every job is supposed to carry

The two files §15 left open, and the three job-level invariants the templates
apply more uniformly than this repository does. The result is no code change,
which is worth writing down at the same length as a fix would be — an
unrecorded "I checked and it was fine" gets checked again by the next person.

**`security.yml`.** Both templates run a `dependency-review` job and a
dependency audit (`npm-audit` there, `dependency-audit` in the python one).
Neither is adopted, for the same reason twice: outside `dev/log/`, which holds
other projects' files as evidence, this repository tracks **zero** dependency
manifests — no `package.json`, no lockfile, no `requirements.txt`, no
`pyproject.toml`, no `Cargo.toml`, no `go.mod`. `dependency-review-action`
compares the manifests a pull request changed; with none to change it reports
success on every run forever. Adding it would buy a green check that means
nothing, which is the exact defect this pull request spent 98 annotations
removing. The dependency surface here is real but lives somewhere those tools
do not look — apt packages and toolchains inside Dockerfiles, and the action and
image references in the workflows — and the second of those is audited: the
`hash-pin` policy of §6, now with a pass that can actually apply it.

**`release.yml`.** Most of the template's release job is npm's — trusted
publishing via OIDC, changeset versioning, lockfile declaration checks, the
smoke test of the published package — and none of it applies to a repository
that publishes container images and no package. The shared surface is the Docker
path, and there the two pipelines have the same shape: build each architecture
by digest, then merge the digests into one index, then mirror. This repository
reached that shape through issue #119 and holds it with
`scripts/release/image-tags.sh`, `create-multiarch-manifest.sh` and the tag
policy asserted by `test-issue119-tag-policy.sh`.

Comparing the two turned up one thing worth sending back rather than importing.
The python template's `docker-publish` verifies what it just published —
`docker buildx imagetools inspect` on the versioned tag, grepped for
`linux/amd64` and `linux/arm64`. The js template's `docker-publish` is the same
job, built from the same `imagetools create` call, with **no verification step
at all**. Two sibling templates disagreeing about whether to check a publish is
better evidence of an oversight than any argument about it, and the fix is
already written in one of them. It is issue #119's finding pointed at somebody
else's repository: *"it resolves" is not "it was published"*. Filed as
[js#185](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/185),
with the reachability path stated and the honest note that I did not observe it
firing there — `tests/docker-publish.test.js` asserts the matrix *declares* two
platforms, which is a test of the workflow file and passes in every run where
the published index has one.

**A second candidate that did not survive being checked.** The obvious next
report was the `paths:`-coverage class, generalising
[js#159](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/159)
— `.lycheeignore` missing from a filter, so adding an ignore entry did not
re-run the check it governs. Sweeping both templates for the same shape found
what looked like nine instances: no workflow's `paths:` filter names
`scripts/check-pipeline-status.sh`, which every one of them runs, and
`workflows.yml` names neither script it executes. Then the safety net turned up:
`release.yml` and `security.yml` have **no `paths:` filter at all**, so every
pull request runs them, and `release.yml` runs `npm test` over a suite that
covers those scripts. The change is exercised; what is missed is only its
re-evaluation in each workflow's own context. That is a much smaller thing than
the sweep implied, and not worth somebody else's triage time. Recording a
hypothesis that failed is cheaper than testing it twice — the same disposal
`run-with-budget-warning.sh`'s liveness got in §13.3.

**The invariants: `timeout-minutes`, `permissions`, `concurrency`.** A first
sweep over all 67 jobs here against the templates' 34 and 26 reported six jobs
with no `timeout-minutes`, 50 with no `concurrency` and 31 with no
`permissions`. All three numbers were wrong, and the way each was wrong is the
same way a CI check goes wrong:

- The six without `timeout-minutes` are `release.yml`'s `js`, `essentials`,
  `languages`, `full`, `dind` and `pr-tests` — every one a `uses:` job calling a
  reusable workflow, where GitHub **rejects** the key outright. Not a gap; a
  rule applied where it does not hold. `check-timeout-budgets.mjs:533` already
  knew this and says so. Counting jobs that can carry the key: 0 of 61 here, 0
  of 34, 0 of 26.
- The 31 without `permissions` counted the job level and ignored the
  workflow-level default. All 15 workflows here declare one, as do all 10
  across the templates. Real total: **0**, everywhere.
- Of the 50 without `concurrency`, 27 are inside the five `release-*.yml` files
  and `pr-tests.yml` — all six `workflow_call`-only, so they never run except as
  part of a `release.yml` run, which the caller's top-level group governs. The
  scan did not follow the call graph.

That leaves eight `pipeline-status` jobs genuinely carrying no concurrency
group, against a js template that gives its own one. That divergence is
deliberate and already argued in `workflows.yml`: a per-job group with
`cancel-in-progress` would cancel the gate in exactly the runs it exists to
report on, and this repository's gate is the thing that tells a superseded run
from an overrun (§7). A cancelled gate reports nothing at all.

So: three dimensions, no findings, and three false positives — produced here, by
me, in the course of looking for them. Each came from measuring a rule without
its exceptions, which is the shape of finding (b) and finding (d) in §0's table.
It is the cheapest possible demonstration of why this pull request measures
instead of asserts.

One of the three is additionally gated rather than merely true today. Run
zizmor exactly as this repository runs it (`--min-confidence medium
--min-severity medium`) against a workflow with no `permissions:` block and it
exits **13**, on `excessive-permissions` at Medium/Medium — above both floors.
The invariant that matters most of the three cannot silently lapse. Concurrency
has no such gate and does not get one here: the correct rule is not "every job"
— it is "every job except the one whose job is to survive a cancellation" — and
a gate encoding a rule with an exception nobody has needed twice is speculation,
not enforcement.

**`lint-changed-lines.mjs`** is the last js-template script with no counterpart
here, and it stays that way. It exists to report ESLint findings only on the
lines a pull request touched, so a repository with a backlog of tolerated
warnings can adopt a rule without a flag day. Neither half of that applies:
there is no ESLint here and no tolerated-warning tier — every gate in this
repository fails the run. Worse, the mechanism argues against this branch's
whole thesis. A checker that reports on changed lines only is one that cannot
fail on the file it was not pointed at, and §6, §3 and §1 are all instances of
that costing something. The judgement is the same one `install-git-hooks.mjs`
got in §12: the insight is worth having, the tool is not the one for this tree.

Deliberately diverged, with the divergence filed upstream: the template's
`all_recovered` (§9, [js#184](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/184)
and [rust#170](https://github.com/link-foundation/rust-ai-driven-development-pipeline-template/issues/170)),
and the budget checker's per-matrix-leg evaluation plus its "unreadable is a
violation" rule (§8).

Considered and deliberately **not** filed upstream:

- The python template's missing terminal status gates in `docs.yml`,
  `links.yml`, `security.yml` and `workflows.yml` — already open as
  [python#69](https://github.com/link-foundation/python-ai-driven-development-pipeline-template/issues/69).
- The python template's `scripts/run-with-budget-warning.sh` — a hypothesised
  liveness defect that did **not** reproduce: a probe with a SIGTERM-ignoring
  command holding a grandchild and a 3s budget gave exit 124, 5s elapsed and the
  grandchild killed with the process group, on both templates. Recording a
  hypothesis that failed is cheaper than testing it twice.

---

## 14. Existing components, and what was written instead

Nothing here was written before looking for something that already did it. The
survey, and the reason each answer went the way it did:

| Need | Existing component | Verdict |
|---|---|---|
| Turn a grey run red | The reference template's `scripts/check-pipeline-status.sh` | **Ported** to shell, with the supersede-versus-overrun distinction added, because this repository cancels superseded runs on purpose and the template does not |
| Keep a gate's `needs` complete | Nothing upstream | Written: `check-status-gate-covers-all-jobs.mjs`, derived from the workflow rather than from a list |
| Bound a long step and report it | The template's `run-with-budget-warning.sh` | **Adopted as-is**; the invariant checker around it is new |
| Free disk on a runner | `jlumbroso/free-disk-space` | Kept, with `large-packages: false` — the action is right about *what* to remove and wrong about *how* on arm64 (§2) |
| Retry a rejected push | The template's `push-failure-classifier.mjs` | Same idea, re-derived in shell against a live `git` (§10), because the strings are the contract and they are a git version's to change |
| Re-ask an unanswered URL | The template's `recheck-broken-links.mjs` | Ported, with one condition added (§9) |
| Parse the repository's JavaScript | The js template's `check-mjs-syntax.sh` | **Ported**, with `git ls-files` discovery instead of three hard-coded directories, a missing `node` as exit 2 rather than a skip, and relative-import resolution added (§13.3) |
| Check a link's anchor, not just its document | lychee's own `--include-fragments` | **Adopted** — the capability was already in the tool this repository runs; what was missing was the flag. Proved load-bearing by a mutation fixture rather than by reading the manual (finding **r**) |
| Keep a heading a script depends on | The js template's `check-required-docs.sh` | **Ported**, with the file list turned into a file-and-headings table, marker-pair checking, and `docs/…md` reference resolution over `scripts/` and `.github/` (§13.3) |
| Suppress a false link failure | `.lycheeignore` | **Rejected** — it converts a false positive into a permanent false negative |
| Stop a log injection | `provenance: false` | **Insufficient**, and the difference matters: it governs the attestation, not the metadata file (§1) |
| Run CI's gates before the commit exists | The templates' husky + lint-staged, driven by `install-git-hooks.mjs` | **Insight ported, tool rejected** — both need a `package.json` lifecycle absent here, and lint-staged's worktree stash can leave a developer's tree to recover after a crash. `core.hooksPath` + a `git checkout-index` mirror instead; what *was* taken from the template is that an installer must verify its own outcome rather than trust an exit code (§12) |
| Measure job durations | `gh run list` / the jobs API | Wrapped as `measure-job-durations.sh`, using `gh --jq` so no `jq` binary is required on a runner |

---

## 15. Still outstanding

- The template comparison is finished: §13.2 for the best-practices document,
  §13.3 for the scripts, §13.4 for `security.yml`, `release.yml` and the
  job-level invariants. Every js-template script now has a recorded verdict —
  ported, ported with changes, or judged and declined with the reason.
- Nothing in this pull request rewrites an annotation that is already published.
  The 98 annotations of run 34293699247 stay as they are; what changes is what
  the next release run produces.
