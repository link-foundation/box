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
a throwaway directory with `git checkout-index` (measured at 0.9 s to write this
repository's 774 tracked files, 2.8 s including the mirror's own index) and runs
the gates in there, so `git add -p`, a fix made after staging, or an unsaved
editor buffer cannot make the answer wrong in either direction.

Gates are scoped by what is staged:

| Staged                              | Gates                                              |
| ----------------------------------- | -------------------------------------------------- |
| `*.sh`, `.githooks/*`               | shfmt, shellcheck, heredoc-vars                     |
| `*.sh *.yml *.mjs *.js *.py`        | awk-portability                                     |
| `*.mjs`, `*.js`, `*.cjs`            | mjs-syntax                                          |
| `*.py`                              | py-syntax                                           |
| `.github/workflows/*.yml`           | workflow YAML, status-gate coverage, timeout budgets |
| `.github/workflows/*.yml`, `scripts/ci/*` | path coverage                                 |
| `*.sh`, `*.mjs`, `*.js`, `.github/workflows/*.yml` | checkout credentials              |
| `*.md`, `*.sh`, `.github/**`        | required-docs                                       |
| anything                            | file-line-limits, secretlint (on the staged paths)  |

The workflow-YAML gate runs before the three that follow it in that row, and it
checks the composite actions in `.github/actions/` as well. The other three read
workflows line by line — deliberately, since they ask about ordering and
indentation that a parsed tree discards — so none of them can tell a file they
disagree with from a file no parser accepts. That floor is established once,
here (issue #123).

Path coverage is scoped to both a workflow directory and a checker directory
because its two halves are edited in different places: a `paths:` filter lives
in `.github/workflows`, and the set of files a gate reads lives in
`scripts/ci`. Either one alone can make a check unreachable.

A full commit of this repository's shell takes about 13 seconds; a
markdown-only commit takes about 9. The slow gates — actionlint, zizmor,
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

The runner itself follows the same rule about its own input. If `git` cannot
list what is staged — a busy index, an unreadable object — the run ends with
`could not list the staged files`, git's own reason above it, and exit 2. It does
**not** report an empty commit, which is what it used to do (issue #123). An
index that genuinely stages nothing is still `Nothing staged; no checks to run`
and exit 0: the two look identical in the output of `git diff --cached`, and only
its exit status tells them apart.

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
bash scripts/ci/check-py-syntax.sh
bash scripts/ci/check-required-docs.sh
bash scripts/ci/check-file-line-limits.sh
bash scripts/ci/run-secretlint.sh
bash scripts/ci/run-hadolint.sh
bash scripts/ci/check-workflow-yaml.sh
node scripts/ci/check-status-gate-covers-all-jobs.mjs .github/workflows/*.yml
node scripts/ci/check-timeout-budgets.mjs .github/workflows/*.yml
node scripts/ci/check-workflow-path-coverage.mjs
node scripts/ci/check-checkout-credentials.mjs
bash scripts/ci/run-experiments.sh                   # every fixtures suite
```

Every one of these accepts `--verbose` or `BOX_VERBOSE=1`, which is off by
default, and most accept explicit file arguments so a single file can be
checked in isolation.

Every gate that finds its own work also answers `--list-inputs`: the files it
would check, one repository-relative path per line and nothing else. That is
not a convenience — `check-workflow-path-coverage.mjs` reads it to decide
whether a change to any of those files can start the workflow that runs the
gate, and it fails when a `scripts/ci` script discovers files with
`git ls-files` and cannot answer.

```bash
bash scripts/ci/run-shellcheck.sh --list-inputs | wc -l
```
