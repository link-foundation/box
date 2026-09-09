# The pre-commit hook: what was measured before it was adopted

Hive-mind best practice #8 — "local quality gates prevent broken commits from
reaching CI" — is the one item of the reference templates' practice that this
repository had not adopted. The templates get it from husky + lint-staged, an
npm lifecycle box does not have: no `package.json` at the root, and the tree is
Dockerfiles and shell. The adoption here is `core.hooksPath` + git alone
(`scripts/ci/run-precommit-checks.sh`, `.githooks/pre-commit`,
`scripts/install-git-hooks.sh`), so the numbers below are what justified each
decision that departs from the template.

## The index, not the working tree

`git commit` records the index. A hook that reads the working tree answers a
different question and can be wrong in **both** directions: passing a commit
that breaks CI (the fix is unstaged) and failing a commit that is fine (the
breakage is unstaged). Both are the defect class issue #121 is about, so the
gates run inside a throwaway mirror of the index built with
`git checkout-index`.

Measured on this repository, 2026-09-09:

| Mirror | Time | Size | Files |
| --- | --- | --- | --- |
| whole index, including `dev/log/` | 1357 ms | 91 MB | 658 |
| index without `dev/log/` | 1121 ms | 81 MB | 373 |

236 ms and 10 MB is not worth excluding `dev/log/` from the *mirror*: that
directory is where downloaded CI logs land, which is precisely where a token
pasted by accident would land, so the secret scan has to be able to see it. It
is excluded from the per-file gate lists, which is where the cost would
otherwise be.

lint-staged solves the same problem by stashing unstaged changes in the real
worktree. A mirror was chosen instead because a crash mid-run leaves nothing to
recover — the developer's tree is never touched.

`git add -A -f` inside the mirror is load-bearing, not defensive: without `-f`,
`.gitignore`'s `*.log` line drops the ten tracked `docs/case-studies/*/ci-logs/*.log`
files and every checker silently sees 648 files instead of 658.

## Cost, per commit shape

A 6-path shell commit, end to end, on this machine:

| Gate | ms |
| --- | --- |
| mirror | ~1400 |
| shfmt | 1207 |
| shellcheck | 1325 |
| heredoc-vars | 48 |
| awk-portability | 222 |
| required-docs | 675 |
| file-line-limits | 1695 |
| secretlint | 3654 |

About 14 s for a commit touching shell; about 5 s for a markdown-only commit,
which runs neither linter. The slow gates (actionlint, zizmor, hadolint, the
link check, the experiment suites, the image builds) stay in CI.

## It found a false positive on its first real run

Its first run over its own commit failed `heredoc-vars` on
`experiments/test-issue121-git-hooks.sh:319`, claiming `$EXITS` leaked out of a
quoted heredoc. It does not: the suite writes `export RECORD=... EXITS=...`.
`check-heredoc-vars.sh`'s pass 1 matched the keyword plus **one** name, so only
`RECORD` was ever recorded as exported and every later name in the same
statement looked unset. A checker that fails a correct commit is exactly the
defect this issue is about; it is fixed (`collect_exports()` walks the whole
statement, tracking quotes, and stops at the first token that is not a name) and
four fixtures in `experiments/test-issue115-heredoc-unbound-vars.sh` hold both
directions of it — including that a `NAME=` inside a quoted value is still prose,
and that `export -f` registers no variable.

## Are the assertions load-bearing?

`mutation-probes.txt` records the answer: four mutations of the shipped scripts,
each producing exactly the failure it should and no other, against a 70/0
unmutated baseline. The suite stands at 80 assertions now.

Reproduce:

```bash
bash experiments/test-issue121-git-hooks.sh          # 80 passed, 0 failed
bash scripts/install-git-hooks.sh --check            # is it installed here?
bash scripts/ci/run-precommit-checks.sh --verbose    # every gate's output
```
