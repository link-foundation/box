# Every place this repository reads git and could mistake failure for an answer

Issue #123 asks for false negatives, and upstream report **F**
([java#9](https://github.com/link-foundation/java-ai-driven-development-pipeline-template/issues/9),
[rust#174](https://github.com/link-foundation/rust-ai-driven-development-pipeline-template/issues/174))
is one shape of them: a check asks git a question, git fails, and the empty
string that comes back is read as the answer. It is only a defect when the
*passing* verdict is the empty one — then the check reports success precisely
when it learned nothing.

Filing that against six templates while the same shape sat in our own tree would
have been inconsistent with the issue's own instruction to apply a finding
everywhere it holds, so this is the sweep of this repository, site by site, with
the disposition of each.

## How the list was produced

```console
$ git grep -nE '\$\((git |gh )[^)]*(2>/dev/null|\|\| *(true|echo))' \
    -- ':!dev/log/*' ':!docs/*' | grep -v '^\S*: *#'
```

23 hits, plus a scan for the range form specifically:

```console
$ git grep -nE 'git (diff|log|rev-list)[^|]*origin/\$\{?[A-Za-z_]*BASE[A-Za-z_]*\}?\.\.\.?HEAD'
```

The second query is now an assertion —
`experiments/test-issue123-pr-diff-range.sh`, part 1 — so a fourth hand-built
range cannot be added without the suite failing.

## Fixed: three gates that read an unresolvable range as "nothing changed"

| Site (before this branch) | What the empty answer meant |
| --- | --- |
| `scripts/release/check-version.sh` | VERSION was not modified → **pass** |
| `.github/workflows/release.yml`, inline `changeset-check` step | no code files changed → **pass**, no changeset demanded |
| `scripts/release/validate-changeset.sh` | no changeset added → fail (right verdict, wrong reason) |

All three asked

```bash
git diff --name-only "origin/${BASE_REF}...HEAD"
```

and discarded the exit status. `git diff` exits 128 and prints **nothing** when
the range does not resolve: `actions/checkout` defaults to `fetch-depth: 1` so
`refs/remotes/origin/<base>` is absent, or the base branch was renamed or
deleted while the pull request was open, or the fetch failed, or there is no
merge base. Measured in
`experiments/issue-123/repro-version-gate-silent-pass.sh`; the before state was

```
  check-version.sh       exit=0   No manual version changes detected - check passed
  validate-changeset.sh  exit=1   ::error::No changeset found
  inline changeset-check exit=0   0 code file(s) seen
```

on a branch that had rewritten VERSION from 1.0.0 to 9.9.9 and changed a script
with no changeset. After:

```
  check-version.sh       exit=1   ::error::Cannot compare this pull request against its base branch
  validate-changeset.sh  exit=1   ::error::Cannot compare this pull request against its base branch
  changeset-required.sh  exit=1   ::error::Cannot compare this pull request against its base branch
```

The three now go through `scripts/release/pr-diff-range.sh`, which restores a
base ref that is only missing locally, and otherwise names the cause and returns
1. Two details are load-bearing and both are asserted:

- **The annotation goes to stderr.** Every caller reads the helper through
  `x="$(pr_changed_files)"`, so an error on stdout is captured as the answer
  rather than shown — which is how the first draft of the helper managed to exit
  1 and print nothing at all. The runner parses workflow commands on both
  streams, so the annotation still arrives.
- **`git diff A...HEAD`, three dots.** Two-dot would report changes the base
  branch made since the branch point as if this pull request had made them.
  Three-dot is the diff against the merge base, which is what every caller
  means — and it is the form that fails when no merge base exists, which is the
  state a gate must not read as "clean".

The jobs that run these gates do set `fetch-depth: 0` (6 of the 55 checkout
steps in the repository do), so the defect was latent rather than firing. It was
also silent, and nothing asserted the coupling; `test-issue123-pr-diff-range.sh`
asserts it now, reading `fetch-depth: 0` out of both jobs in `release.yml`.

Two further defects were found while extracting the inline step into
`scripts/release/check-changeset-required.sh`:

- `echo "$CODE_CHANGES"` printed pull-request-controlled file paths with command
  processing live — an instance of this issue's own class C inside our workflow,
  since `ActionCommand.TryParse` matches `##[` anywhere in a physical line.
  Routed through `run_with_commands_stopped` now.
- The path set the gate demanded a changeset for omitted `VERSION`,
  `.github/actions/` and `.githooks/`. The four composite actions are executed by
  every release build, so changing one changes the pipeline exactly as changing
  a workflow does.

## Fixed: a query whose failure was reported as its answer

`scripts/release/git-push-with-retry.sh:79` asked

```bash
url="$(gh pr list --head "$pr_branch" --base "$BRANCH" --state open --json url --jq '.[0].url // ""' 2>/dev/null || true)"
```

An empty `url` means "no pull request is open" — the ordinary case — *and* "the
query failed". The recovery is the same either way (create one), so the verdict
was never wrong; the log was. Worse, the create beneath it took
`… 2>&1 | tail -n1`, which discards the exit status with everything but the last
line, so a declined create handed a sentence of English to `gh pr merge` as if
it were a URL. Both are separated now, and
`experiments/test-issue121-git-push-recovery.sh` scenarios G and H drive them.

## Considered and left alone, with the reason

**`scripts/ci/check-pipeline-status.sh:105`** — the head of the branch, used to
decide whether a cancellation was a supersede:

```bash
head="$(git ls-remote "$GIT_REMOTE" "refs/heads/${BRANCH_NAME}" 2>/dev/null | awk 'NR == 1 { print $1 }')"
…
if [ -z "$head" ]; then
  echo "Could not resolve the head of ${BRANCH_NAME}; assuming this run is current." >&2
  return 1
fi
```

Empty already means the strict thing: `run_is_superseded` returns 1, so the
cancellation is **not** excused and the gate fails the run. The unknown answer
costs a false positive at worst, never a missed failure, and it says out loud
which way it decided. Left as is.

**`scripts/ci/simulate-fresh-merge.sh:139`** —
`CONFLICTS="$(git diff --name-only --diff-filter=U 2>/dev/null || true)"`. Reached
only after `git merge` has already failed, and the script prints
`::error title=Merge conflict::…` and exits 1 whether or not the list is empty;
the list is a display detail that names the files. Every other failure mode in
that script is separated already — a fetch that fails after three attempts exits
2, a missing merge base warns and exits 0 rather than reporting an "unrelated
histories" merge as a conflict. Left as is.

**`scripts/release/image-tags.sh:98`** — `SHA="$(git rev-parse --short=7 HEAD …|| true)"`.
An empty SHA drops one of four tags and says so:
`::warning title=image-tags.sh::No commit to tag (GITHUB_SHA unset and not a git
checkout); publishing latest 2.9.0 2026-09-10 only.` The three tags that identify
the release are unaffected. Left as is.

**`.githooks/pre-commit:26`** — `ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0`.
Deliberate: a hook that cannot find the repository must not block a commit, and
the same file states the rule for the neighbouring case ("Missing means 'nothing
to run here', not 'refuse the commit'"). CI runs the identical thirteen gates, so
the tolerance is not a hole — an assertion in `test-issue121-git-hooks.sh`
requires every gate the hook runs to also be run by a workflow. Left as is.

**`scripts/ci/check-awk-portability.sh:100`, `check-file-line-limits.sh:74`,
`check-mjs-syntax.sh:85`, `check-py-syntax.sh:71`, `check-required-docs.sh:148`** —
all of the form `if ! root="$(git rev-parse --show-toplevel 2>/dev/null)"; then`.
The status is tested, which is the whole fix. Left as is.

**`scripts/install-git-hooks.sh:90,100,110,146,166`** — `git config --get
core.hooksPath`. `git config --get` exits 1 when the key is unset, so empty
genuinely *is* the answer here, and line 166 is the read-back verification: an
empty result there disagrees with what was written and fails the install. Left
as is.

**`scripts/ci/detect-changes.sh:113`** — the site this fix is argued from, and
the one place in the repository that already answered correctly:

```bash
if files="$(git diff --name-only $range 2>/dev/null)"; then
  printf '%s\n' "$files"; return
fi
log "Range ${range} did not resolve; falling back to every tracked file" >&2
…
# Never under-build. With no usable range the safe classification is "all of
# it changed": a build that was not needed costs runner minutes, a build that
# was needed and skipped ships an unbuilt image.
git ls-files
```

Note that the safe direction is not the same in both places. For a *build
selector* it is "assume everything changed"; for a *gate* it is "refuse to
answer". Both are the same rule — never let a failed read produce the permissive
outcome — and the difference is only which outcome is permissive.

**The experiment fixtures** (`experiments/reproduce-issue121-*.sh`,
`experiments/issue-123/probe-shallow-base-ref.sh`) print `?` or `no` for a git
that cannot answer, which is what they exist to show. Left as is.

## What keeps it fixed

`experiments/test-issue123-pr-diff-range.sh` — 53 offline assertions, no docker
and no network, auto-discovered by `scripts/ci/run-experiments.sh` because of its
`test-issue123-*.sh` name. Parts 1–4 exercise each gate with the range resolving,
with it broken, and with the base ref merely missing locally. Part 5 mutates the
shipped scripts four times — dropping the range check, moving the annotation back
to stdout, dropping the `run_with_commands_stopped` guard, narrowing the path set
— and requires each mutation to change an outcome asserted above, so the suite
cannot pass by agreeing with its own fixture.
