---
bump: minor
---

Find and fix every false positive, false negative, warning and error in CI/CD (issue #115).

Twenty-three root causes, each with the evidence that proves it and a test that
fails without the fix, in `dev/log/issues/115/pulls/116/`. One theme runs through
almost all of them: **a check that cannot tell "I looked and found nothing" from
"I could not look" is not a check.** Every gate added or repaired here reports
what it examined, and exits non-zero when the answer is "nothing".

### The two runs the issue names

- **`measure-disk-space` died before it measured anything (RC-1).** The script
  generates a second script through a *quoted* heredoc — deliberately, so the
  `$HOME` and `$(…)` references inside are evaluated by the generated script at
  its own runtime. Commit `92d66aa` then added `$NODE_MAJOR`,
  `${NVM_INSTALL_VERSION}` and `${JAVA_MAJOR}` to the body, which exist only in
  the parent. The quotes keep them literal, `su - box` and `sudo -i -u box` start
  a login shell from a clean environment, and the generated script's own
  `set -u` aborted on the first one: `line 128: NODE_MAJOR: unbound variable`.
  The values are now handed over explicitly with `env` at the call site (a bare
  `VAR=value` prefix does not survive `sudo`'s `env_reset`), and each generated
  script asserts what it needs with `: "${NODE_MAJOR:?…}"`. The same latent bug
  was in `scripts/ubuntu-24-server-install.sh`, which no job runs — it is fixed
  there too. `scripts/ci/check-heredoc-vars.sh` now fails the build on any
  recurrence, tree-wide.
- **`measure-disk-space.yml` had no `pull_request` trigger (RC-2).** Its `paths:`
  list already named exactly the two files RC-1 broke — it just only looked after
  they had reached `main`. That is why #113 merged green.
- **The Docker Hub token was expired, and one `buildx` solve carried tags for two
  registries (RC-3).** The failed Docker Hub push destroyed the GHCR tags that had
  already been pushed in the same solve, and cancelled the `cache-to: type=gha`
  export with them, so the next run rebuilt from scratch. GHCR is now the registry
  of record — written with the per-run `GITHUB_TOKEN`, which cannot expire, and
  the registry every downstream `FROM` build-arg resolves to — and Docker Hub is
  mirrored separately by `scripts/release/mirror-to-dockerhub.sh`, guarded on the login
  outcome. A broken mirror credential degrades to a warning on a published
  release instead of failing it (RC-18: it used to mean no GitHub Release at all).

### False positives — green that meant nothing

- `skipped` was accepted wherever `success` was expected (RC-4), and 24 `always()`
  gates kept a cancelled run cascading instead of stopping (RC-7). Both are now
  `!cancelled()` with an explicit result check.
- Every pull-request check ran against a merge preview that could be days old
  (RC-19). All sixteen PR jobs go through `.github/actions/simulate-fresh-merge`,
  which deepens a shallow checkout first — `--depth 1` leaves no common ancestor,
  and the *unrelated histories* error that follows is not a merge conflict — and
  separates a real conflict (exit 1) from CI misuse (exit 2).
- An acceptance assertion forked a subshell to grep its own output and could not
  see its own exit status (RC-13).
- The new heredoc gate read `<<'EOF_BOX'` *inside a string literal* as a real
  heredoc opener (RC-23). It now tracks quote state across `$( … )` the way the
  shell parser does.

### False negatives — checks that were absent, or looked at nothing

- Nothing linted the CI configuration itself (RC-6). actionlint 1.7.7 with
  shellcheck over every `run:` block, and zizmor 1.30.0, now gate the workflows;
  third-party actions are pinned to full commit SHAs and `permissions:` is
  least-privilege throughout.
- Nothing ran the regression suites (RC-15); `scripts/ci/run-experiments.sh`
  discovers and runs every suite under `experiments/`, and fails when the
  directory is empty rather than passing.
- Four language directories were built by no job (RC-11), and the box acceptance
  checks existed as four hand-maintained copies that had drifted apart (RC-10) —
  now one `scripts/ci/test-box.sh` with per-profile assertions.
- **Every Lean box shipped elan and no Lean (RC-14).** `elan-init
  --default-toolchain` records the default and exits 0 without installing it, and
  `~/.elan/bin/lean` is a shim that downloads on first use — so `lean --version`
  passed against an image containing no Lean. The assertion is now
  `test -d ~/.elan/toolchains/*`, which a shim cannot satisfy.
- `opam` was not on `PATH` in the rocq box or the full box (RC-12).
- **The secret scanner's silence was unverified (RC-16).** `run-secretlint.sh`
  plants a random AWS key and requires the same invocation to detect it before
  the clean result is believed. CodeQL analyses our own code, not the vendored
  evidence under `dev/log/`.
- 107 documentation links pointed at nothing, 85 of them advertising images that
  were never published (RC-17). All fixed, and lychee gates them.

### Warnings, and the maintainability cause behind the recurrences

- Permanent registry failures were retried three times (RC-5).
  `docker-push-failure-classifier.sh` tells an expired token or a denied
  repository apart from a 403, a 5xx, a reset or a `TOOMANYREQUESTS`; the ten
  copy-pasted inline retry loops collapse into `scripts/release/buildx-retry.sh`.
- Every job that runs steps now declares `timeout-minutes` — 46 declarations, 31
  of them new — so a hung step is killed inside its own budget rather than at
  GitHub's six-hour one. The six remaining jobs are `uses:` callers, which GitHub
  does not allow to carry the key; their budgets live in the called workflow.
- **`release.yml` was 3432 lines, 30 jobs, with the four-tag build block copied
  about ten times (RC-8), and that size was itself a root cause** — RC-3, RC-4,
  RC-5 and RC-7 are each a defect that copy-paste duplicated rather than a defect
  anyone wrote twice on purpose. It is split by image family, and
  `scripts/ci/check-file-line-limits.sh` keeps it that way: `git ls-files` rather
  than `find`, so an untracked build artefact cannot fail the gate, and exit 2
  when it matches no files at all.
- Nothing formatted the shell this repository is written in (RC-20); shfmt now
  gates it. Two defects the fix itself caused are fixed and pinned: shfmt
  rewrote `[node-lts-integration-test.sh]` to `[node - lts - integration - test.sh]`
  and silently disabled the skip list of the runner that runs every check (RC-21),
  and a workflow that matched a script by its formatting broke when the formatter
  reflowed it (RC-22) — it reads the heredoc through
  `scripts/ci/extract-quoted-heredoc.sh` now, not through a `sed` range.

### Reported upstream

Six reports, each with a reproduction, a workaround and a suggested code fix:
[elan #210](https://github.com/leanprover/elan/issues/210),
[secretlint #1688](https://github.com/secretlint/secretlint/issues/1688),
[shellcheck #3534](https://github.com/koalaman/shellcheck/issues/3534), and
[#174](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/174),
[#175](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/175)
and [a comment on #167](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/167#issuecomment-5556797713)
against the reference pipeline template. Four further candidates were dropped
after reproduction showed the defect was ours and not theirs;
`dev/log/issues/115/pulls/116/UPSTREAM-REPORTS.md` records those decisions and
their evidence too.

`BOX_VERBOSE=1` (default off) traces the generated measurement script and the new
CI helpers line by line.
