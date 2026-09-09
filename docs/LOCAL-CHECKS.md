# Running the checks locally

Every gate in this repository's CI is a script in `scripts/ci/`, runnable on a
laptop with the same command CI uses. Nothing is hidden behind a workflow-only
step, so a failure can always be reproduced before pushing.

## Install the pre-commit hook

```bash
bash scripts/install-git-hooks.sh
```

This sets `core.hooksPath` to the tracked `.githooks/` directory and then
verifies the outcome — that the key reads back as `.githooks`, and that
`.githooks/pre-commit` exists and is executable. Git silently ignores a hook it
cannot execute, so an installer that only checks its own exit code can report
success over a repository where no hook will ever run.

```bash
bash scripts/install-git-hooks.sh --check      # is it installed?
bash scripts/install-git-hooks.sh --uninstall  # unset core.hooksPath
```

Setting `core.hooksPath` makes git stop reading `.git/hooks` entirely. If you
keep your own hooks there, the installer says so before it takes them out of
the loop.

## What the hook runs

`.githooks/pre-commit` delegates to `scripts/ci/run-precommit-checks.sh`, which
checks **the staged content** — not the working tree. It mirrors the index into
a throwaway directory with `git checkout-index` (measured at 1.4 s for this
repository) and runs the gates in there, so `git add -p`, a fix made after
staging, or an unsaved editor buffer cannot make the answer wrong in either
direction.

Gates are scoped by what is staged:

| Staged                       | Gates                                                     |
| ---------------------------- | --------------------------------------------------------- |
| `*.sh`, `.githooks/*`        | shfmt, shellcheck, heredoc-vars                            |
| `*.sh *.yml *.mjs *.js *.py` | awk-portability                                            |
| `*.mjs`, `*.js`, `*.cjs`     | mjs-syntax                                                 |
| `.github/workflows/*.yml`    | status-gate coverage, timeout budgets                      |
| `*.md`, `*.sh`, `.github/**` | required-docs                                              |
| anything                     | file-line-limits, secretlint (on the staged paths)         |

A full commit of this repository's shell takes about 14 seconds; a
markdown-only commit takes about 5. The slow gates — actionlint, zizmor,
hadolint, the link check, the experiment suites and the image builds — stay in
CI.

The hook does not rewrite files. Formatting failures print the command that
fixes them:

```bash
bash scripts/ci/run-shfmt.sh --fix
```

A gate that **cannot** run — no docker, no node, no network for `npx` — is
reported as `could not run` and does not block the commit; CI runs every one of
them on the same content. A gate that runs and fails does block.

Bypass a single commit with `git commit --no-verify`, or a whole session with
`BOX_SKIP_HOOKS=1`.

## Running a gate by hand

```bash
bash scripts/ci/run-precommit-checks.sh              # the staged content
bash scripts/ci/run-precommit-checks.sh --worktree   # the tree as it is now
bash scripts/ci/run-precommit-checks.sh --verbose    # show every gate's output

bash scripts/ci/run-shellcheck.sh                    # whole repository
bash scripts/ci/run-shfmt.sh --fix
bash scripts/ci/check-heredoc-vars.sh
bash scripts/ci/check-awk-portability.sh
bash scripts/ci/check-mjs-syntax.sh
bash scripts/ci/check-required-docs.sh
bash scripts/ci/check-file-line-limits.sh
bash scripts/ci/run-secretlint.sh
bash scripts/ci/run-hadolint.sh
node scripts/ci/check-status-gate-covers-all-jobs.mjs .github/workflows/*.yml
node scripts/ci/check-timeout-budgets.mjs .github/workflows/*.yml
bash scripts/ci/run-experiments.sh                   # every fixtures suite
```

Every one of these accepts `--verbose` or `BOX_VERBOSE=1`, which is off by
default, and most accept explicit file arguments so a single file can be
checked in isolation.
