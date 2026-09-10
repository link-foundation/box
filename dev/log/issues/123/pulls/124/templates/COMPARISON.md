# The template comparison issue #123 asks for

> "Use all the best practices from `link-foundation/js-ai-driven-development-pipeline-template`
> and `link-foundation/python-ai-driven-development-pipeline-template`, compare the
> full file tree of every GitHub workflow and CI/CD script."

This is that comparison, done against **seven** templates rather than the two the
issue names, because the same role is often spelled differently in each and one
template alone cannot tell a missing practice from a naming difference.

Two earlier comparisons already exist and are **not repeated here**:

* `dev/log/issues/115/pulls/116/TEMPLATE-COMPARISON.md` - the first file-by-file pass.
* `dev/log/issues/121/pulls/122/`, §13.1-13.4 of the case study - the pass that
  produced js-template#185 and declined `dependency-review`, the npm release path
  and `lint-changed-lines.mjs` in writing.

This document extends them: it is a **role matrix over the whole file tree**, so a
practice cannot hide behind a filename, and every one of the 91 roles box does not
have is dispositioned individually below.

## 0. What was compared, and at which revision

`experiments/issue-123/snapshot-templates.sh` stored `.github/**`, `scripts/**` and
the root tool configuration of each template, and wrote every path - including the
ones it did not store - to `<name>.file-tree.txt`. The revisions are pinned in
`SNAPSHOT.txt`:

| template | sha | committed | tracked files |
|---|---|---|---|
| js | `c3a6d23b` | 2026-09-09 | 393 |
| python | `470e1760` | 2026-09-09 | 96 |
| rust | `f63a061f` | 2026-09-09 | 158 |
| php | `15c327be` | 2026-09-10 | 211 |
| csharp | `83efb9e4` | 2026-08-28 | 60 |
| go | `548a7968` | 2025-12-29 | 21 |
| java | `450a10ec` | 2025-12-30 | 26 |

**js, python and rust are at the same commits #121 compared** - `c3a6d23b`,
`470e1760` and `f63a061f` appear verbatim in
`dev/log/issues/121/pulls/122/templates/SNAPSHOT.txt` and in the two upstream
reports filed from that branch. None of the three has moved since. So every
finding #121 recorded about them still describes the current template, and
re-deciding them here would be re-deciding the same file. php, csharp, go and java
had never been compared before; they are the reason this pass exists at all.

`box.file-tree.txt` is regenerated from `git ls-files '.github/*' 'scripts/*'` on
this branch, so the matrix includes the scripts this branch adds
(`pr-diff-range.sh`, `check-changeset-required.sh`).

## 1. How a "role" is defined

A role is a script's *job*, not its filename. The same job is
`check-file-size.mjs` in js, `check_file_size.py` in python, `check-file-size.sh`
in php and `CheckFileSize` in csharp. `experiments/issue-123/compare-template-roles.sh`
normalises a path to a role by dropping the extension, folding `*.test.*`,
`test_*` and `test-*` onto the role they test, and mapping `_` to `-`.

Reproduce either matrix offline:

```
bash experiments/issue-123/compare-template-roles.sh              # 160 script roles
bash experiments/issue-123/compare-template-roles.sh --workflows  #  17 workflow roles
```

## 2. The totals

**160 script roles** across the eight repositories:

| repo | roles |
|---|---|
| box | 69 |
| js | 49 |
| php | 39 |
| rust | 31 |
| python | 20 |
| csharp | 17 |
| java | 9 |
| go | 6 |

* **54** of box's 69 roles exist in no template.
* **15** are shared with at least one template.
* **91** template roles do not exist in box - §4 dispositions every one.

## 3. The 15 roles box shares with a template

| role | also in |
|---|---|
| `check-changesets` | js |
| `check-file-line-limits` | js |
| `check-mjs-syntax` | js |
| `check-pipeline-status` | js,python,rust,php |
| `check-required-docs` | js,python,rust |
| `check-status-gate-covers-all-jobs` | js |
| `check-version` | js |
| `check-web-archive` | js,python,rust,php,csharp |
| `create-changeset` | php |
| `install-git-hooks` | js |
| `preflight-credentials` | js,python,rust,php |
| `recheck-broken-links` | js,python,rust,php |
| `run-with-budget-warning` | js,python,rust,php |
| `simulate-fresh-merge` | js,python,rust |
| `validate-changeset` | js,python,php,csharp,go,java |

Every one of these arrived by adoption: `check-required-docs`, `check-mjs-syntax`
and `install-git-hooks` in #121, the rest in #115 and #117. None has drifted -
`experiments/test-issue115-*.sh` and `experiments/test-issue121-*.sh` hold each
one's behaviour, and `scripts/ci/run-precommit-checks.sh` runs thirteen of the
gates before a commit is written.

## 4. The 91 template roles box does not have

Each row is dispositioned. The codes:

* **lib** - not a CI role at all: an internal class of one template's own library.
* **name** - box has the role, under a different name. The box path is given, and
  the equivalence was read, not guessed.
* **eco** - specific to a language ecosystem or package registry box does not
  publish to. box ships container images to GHCR and Docker Hub; it publishes no
  npm, PyPI, crates.io, NuGet or Packagist package, and declares no dependency
  manifest of its own.
* **declined** - box could adopt it and does not, with the measurement behind the
  decision.

| role | in template(s) | disposition | box's answer / reason |
|---|---|---|---|
| `Actions` | php | lib | php's own PHP library under `scripts/src/`, loaded by its entry-point scripts |
| `ChangeDetector` | php | lib | php's own PHP library under `scripts/src/`, loaded by its entry-point scripts |
| `Changelog` | php | lib | php's own PHP library under `scripts/src/`, loaded by its entry-point scripts |
| `ChangelogFragments` | php | lib | php's own PHP library under `scripts/src/`, loaded by its entry-point scripts |
| `ChangesetValidator` | php | lib | php's own PHP library under `scripts/src/`, loaded by its entry-point scripts |
| `Cli` | php | lib | php's own PHP library under `scripts/src/`, loaded by its entry-point scripts |
| `FileSizeChecker` | php | lib | php's own PHP library under `scripts/src/`, loaded by its entry-point scripts |
| `Git` | php | lib | php's own PHP library under `scripts/src/`, loaded by its entry-point scripts |
| `GitHub` | php | lib | php's own PHP library under `scripts/src/`, loaded by its entry-point scripts |
| `Http` | php | lib | php's own PHP library under `scripts/src/`, loaded by its entry-point scripts |
| `LinkRecheck` | php | lib | php's own PHP library under `scripts/src/`, loaded by its entry-point scripts |
| `LycheeFailure` | php | lib | php's own PHP library under `scripts/src/`, loaded by its entry-point scripts |
| `Packagist` | php | lib | php's own PHP library under `scripts/src/`, loaded by its entry-point scripts |
| `PreflightCheck` | php | lib | php's own PHP library under `scripts/src/`, loaded by its entry-point scripts |
| `Process` | php | lib | php's own PHP library under `scripts/src/`, loaded by its entry-point scripts |
| `ProcessResult` | php | lib | php's own PHP library under `scripts/src/`, loaded by its entry-point scripts |
| `Project` | php | lib | php's own PHP library under `scripts/src/`, loaded by its entry-point scripts |
| `ReleaseDecider` | php | lib | php's own PHP library under `scripts/src/`, loaded by its entry-point scripts |
| `ReleaseDecision` | php | lib | php's own PHP library under `scripts/src/`, loaded by its entry-point scripts |
| `ReleaseNotes` | php | lib | php's own PHP library under `scripts/src/`, loaded by its entry-point scripts |
| `ReleasePreflight` | php | lib | php's own PHP library under `scripts/src/`, loaded by its entry-point scripts |
| `SemVer` | php | lib | php's own PHP library under `scripts/src/`, loaded by its entry-point scripts |
| `VersionReleaser` | php | lib | php's own PHP library under `scripts/src/`, loaded by its entry-point scripts |
| `WebArchive` | php | lib | php's own PHP library under `scripts/src/`, loaded by its entry-point scripts |
| `audit-dependencies` | python | declined | box tracks four dependency manifests and all four are template snapshots under `dev/log/`; it declares none of its own |
| `bootstrap` | php | eco | `composer install` for the php template's own package |
| `bootstrap-dependencies` | js | eco | `npm ci` for the js template's own package |
| `bump-version` | python,rust,csharp,java | name | `scripts/release/apply-changesets.sh` plus the version bump in `release.yml` |
| `changeset-version` | js | name | `scripts/release/apply-changesets.sh` |
| `check-cargo-lock` | rust | eco | Cargo lockfile freshness; box has no Cargo project |
| `check-changelog-fragment` | rust | name | `scripts/release/validate-changeset.sh` + `scripts/release/check-changeset-required.sh` |
| `check-crate-size` | rust | eco | crates.io upload budget; box measures image and file size in `file-sizes.yml`, `measure-disk-space.yml`, `check-file-line-limits.sh` |
| `check-docker-build` | js | name | the five `release-*.yml` build workflows plus `scripts/release/build-chain.sh` and `pr-tests.yml` |
| `check-docker-publish` | js | name | `scripts/release/check-publication.sh`, which asks the registries anonymously after the push |
| `check-file-size` | python,rust,php,csharp,go,java | name | `scripts/ci/check-file-line-limits.sh` |
| `check-package-manager` | js | eco | npm/yarn/pnpm agreement; box has no JS package at its root |
| `check-release-needed` | js,rust,php,csharp | name | `scripts/release/check-changesets.sh` decides whether to release; `check-publication.sh` decides whether the last one landed |
| `check-version-modification` | rust,php | name | `scripts/release/check-version.sh` |
| `collect-changelog` | rust,java | name | `scripts/release/apply-changesets.sh` |
| `create-changelog-fragment` | rust | name | `scripts/release/create-changeset.sh` |
| `create-github-release` | js,python,rust,php,csharp,go,java | name | `release.yml`'s `gh release create` step plus `scripts/release/build-release-notes.sh` |
| `create-manual-changeset` | js,python,java | name | `scripts/release/create-changeset.sh` |
| `debug-print` | js | eco | a js-module logging helper, not a CI role |
| `desktop-release-resolve` | rust | declined | the rust template ships a Tauri desktop app; box ships container images |
| `detect-code-changes` | js,python,rust,php,csharp,go,java | name | `scripts/ci/detect-changes.sh` |
| `docs-workflow-policy` | csharp | name | `scripts/ci/check-required-docs.sh` run by `docs.yml`, plus `check-workflow-path-coverage.sh` |
| `format-github-release` | js | name | `scripts/release/build-release-notes.sh` |
| `format-release-notes` | js,python | name | `scripts/release/build-release-notes.sh` |
| `format-release-notes-helpers` | js | name | `scripts/release/build-release-notes.sh` |
| `get-bump-type` | rust | name | `scripts/release/apply-changesets.sh` reads the bump type out of the changesets |
| `get-version` | rust | eco | a one-line read of the manifest; box reads `VERSION` inline |
| `git-config` | rust | name | `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_0` at workflow scope - measured present in 15 of box's 15 workflows |
| `install-rust-script` | rust | eco | installs `rust-script` so the rust template can run `.rs` CI scripts |
| `instant-version-bump` | js | eco | an npm-version convenience path |
| `js-paths` | js | eco | resolves `./` vs `js/` for a JS package |
| `land-via-pull-request` | js | name | `land_via_pull_request()` in `scripts/release/git-push-with-retry.sh` |
| `links-workflow-policy` | csharp | name | `links.yml` plus `scripts/ci/recheck-broken-links.mjs` and `experiments/test-issue115-links-gate.sh` |
| `lint` | js | declined | declined in #121: box tracks no JS or TS source of its own to lint |
| `lint-changed-lines` | js | declined | declined in #121: same reason, and box lints shell, awk, Dockerfiles and workflows over the whole tree |
| `merge-changesets` | js,csharp,go,java | name | `scripts/release/apply-changesets.sh` |
| `npm-registry` | js | eco | npm registry endpoint resolution |
| `package-desktop` | rust | declined | the rust template ships a Tauri desktop app; box ships container images |
| `package-info` | js | eco | reads `package.json` fields |
| `publish-crate` | rust | eco | crates.io publish |
| `publish-failure-classifier` | js | name | `scripts/release/docker-push-failure-classifier.sh` |
| `publish-retry` | js | name | `scripts/release/docker-push-with-retry.sh` |
| `publish-to-npm` | js | eco | npm publish |
| `publish-to-pypi` | python | eco | PyPI publish |
| `push-failure-classifier` | js | name | `scripts/release/git-push-failure-classifier.sh` |
| `push-main-with-rebase-retry` | js | name | `scripts/release/git-push-with-retry.sh` |
| `read-manifest` | python | eco | reads `pyproject.toml` |
| `release-naming` | js,python,rust,csharp | name | `scripts/release/image-tags.sh` computes the tag list once for the whole release |
| `release-workflow-policy` | csharp | name | `check-timeout-budgets.mjs`, `check-status-gate-covers-all-jobs.mjs`, `read-job-cancel-in-progress.mjs`, `run-zizmor.sh` |
| `run-command` | js | eco | a js-module subprocess helper |
| `rust-paths` | rust | eco | resolves `./` vs `rust/` for a crate |
| `sanitize-npm-userconfig` | js | eco | npm userconfig handling |
| `scripts` | rust | eco | the rust template's own runner for its `.rs` CI scripts; box runs shell directly and `scripts.yml` checks it |
| `security-workflow-policy` | csharp | name | `security.yml` plus `scripts/ci/run-zizmor.sh` and `scripts/ci/run-secretlint.sh` |
| `setup-npm` | js | eco | npm auth setup |
| `smoke-test-nuget-package` | csharp | name | `scripts/release/check-publication.sh` + `scripts/release/assert-base-image.sh` pull the published artifact anonymously |
| `smoke-test-package` | js | name | `scripts/release/check-publication.sh` + `scripts/release/assert-base-image.sh` pull the published artifact anonymously |
| `smoke-test-published-crate` | rust | name | `scripts/release/check-publication.sh` + `scripts/release/assert-base-image.sh` pull the published artifact anonymously |
| `smoke-test-published-package` | python | name | `scripts/release/check-publication.sh` + `scripts/release/assert-base-image.sh` pull the published artifact anonymously |
| `update-preview-images` | js | declined | the js template regenerates README screenshots of its example app; box has none |
| `use-module` | js | eco | a dynamic-import helper for js CI modules |
| `version-and-commit` | js,python,rust,php,csharp,go,java | name | `scripts/release/apply-changesets.sh` writes the commit, `git-push-with-retry.sh` lands it |
| `wait-for-crate` | rust | name | `scripts/release/registry-probe.sh` |
| `wait-for-npm` | js | name | `scripts/release/registry-probe.sh` |
| `wait-for-nuget` | csharp | name | `scripts/release/registry-probe.sh` |
| `wait-for-packagist` | php | name | `scripts/release/registry-probe.sh` |
| `workflow-injection-policy` | csharp | name | `scripts/ci/run-zizmor.sh`, widened in #121 to the composite actions; the quoting half re-measured here as 0 unquoted of 69 `$GITHUB_OUTPUT` redirections |

Totals: **24 lib, 39 name, 22 eco, 6 declined**. 24 + 39 + 22 + 6 = 91.

### 4.1 The 24 `lib` rows

php's `scripts/src/*.php` - `Actions`, `ChangeDetector`, `Changelog`,
`ChangelogFragments`, `ChangesetValidator`, `Cli`, `FileSizeChecker`, `Git`,
`GitHub`, `Http`, `LinkRecheck`, `LycheeFailure`, `Packagist`, `PreflightCheck`,
`Process`, `ProcessResult`, `Project`, `ReleaseDecider`, `ReleaseDecision`,
`ReleaseNotes`, `ReleasePreflight`, `SemVer`, `VersionReleaser`, `WebArchive`.

`command grep -c 'scripts/src/' php.file-tree.txt` returns 24. These are the
classes php's entry-point scripts load, not jobs the pipeline runs; the jobs they
implement are counted once more as the entry points in `scripts/*.php`, which the
matrix already lists. Counting them as roles box lacks would say box is missing a
`SemVer` class - a statement about how php factored its own code.

### 4.2 The six `declined` rows, with the measurement

**`audit-dependencies` (python).** #121 declined the templates' `dependency-review`
job on the grounds that box tracks zero dependency manifests. Re-measured on this
branch:

```
git ls-files | grep -E '(^|/)(package\.json|package-lock\.json|requirements.*\.txt|Pipfile|pyproject\.toml|Cargo\.toml|Cargo\.lock|composer\.json|go\.mod|.*\.csproj|pom\.xml|Gemfile)$'
```

returns **4** paths, and all four are template snapshots under
`dev/log/issues/115/…` and `dev/log/issues/121/…` - evidence this repository
stores about *other* repositories. box declares none of its own. A dependency
audit here would be a check that can only ever pass, which is the exact class of
defect issue #123 exists to remove.

**`lint`, `lint-changed-lines` (js).** Declined in #121, unchanged: box tracks no
JavaScript or TypeScript source of its own outside `scripts/`, `experiments/` and
`docs/` - the measurement is that `git ls-files '*.js' '*.ts' '*.mjs' '*.cjs'`
returns nothing under any other path - and the thirteen `.mjs` modules under
`scripts/` are parsed by `scripts/ci/check-mjs-syntax.sh` on every run. `lint-changed-lines`
narrows a linter to the changed lines of a pull request - a useful idea when a
large legacy corpus makes a whole-tree lint impractical. box lints its whole tree
already: shfmt, shellcheck, awk portability, hadolint, actionlint, zizmor,
secretlint and the mjs/py parsers all run over every tracked file, in about the
time the narrowing would save.

**`package-desktop`, `desktop-release-resolve` (rust).** The rust template ships a
Tauri desktop application and releases installers for it; `desktop-release.yml` is
its workflow (§5). box ships container images.

**`update-preview-images` (js).** The js template regenerates the README
screenshots of its example application. box has no example application - its
`example-app.yml` counterpart does not exist for the same reason (§5) - and the
one generated section box's README does carry, the component-size table, is
written by `scripts/ci/update-readme-sizes.sh` and validated by
`check-required-docs.sh`'s marker check since #121.

### 4.3 The 39 `name` rows are the substance of this comparison

They are what makes the raw count meaningless on its own: box does not lack 91
practices, it lacks 6. The equivalences worth stating explicitly, because a reader
counting filenames would get them wrong:

| template role(s) | box |
|---|---|
| `check-file-size` (6 templates) | `scripts/ci/check-file-line-limits.sh` |
| `detect-code-changes` (7 templates) | `scripts/ci/detect-changes.sh` |
| `check-version-modification` | `scripts/release/check-version.sh` |
| `check-changelog-fragment` | `scripts/release/validate-changeset.sh` + `check-changeset-required.sh` |
| `create-changelog-fragment`, `create-manual-changeset` | `scripts/release/create-changeset.sh` |
| `collect-changelog`, `merge-changesets`, `changeset-version`, `bump-version`, `version-and-commit`, `get-bump-type` | `scripts/release/apply-changesets.sh` |
| `create-github-release`, `format-github-release`, `format-release-notes`, `format-release-notes-helpers` | `scripts/release/build-release-notes.sh` + `release.yml`'s `gh release create` |
| `check-release-needed` | `scripts/release/check-changesets.sh` (should we) + `check-publication.sh` (did the last one land) |
| `release-naming` | `scripts/release/image-tags.sh` |
| `push-failure-classifier` | `scripts/release/git-push-failure-classifier.sh` |
| `push-main-with-rebase-retry`, `land-via-pull-request` | `scripts/release/git-push-with-retry.sh` |
| `publish-failure-classifier`, `publish-retry` | `scripts/release/docker-push-failure-classifier.sh`, `docker-push-with-retry.sh` |
| `wait-for-npm`, `wait-for-crate`, `wait-for-nuget`, `wait-for-packagist` | `scripts/release/registry-probe.sh` |
| `smoke-test-package`, `smoke-test-published-package`, `smoke-test-published-crate`, `smoke-test-nuget-package` | `scripts/release/check-publication.sh` + `assert-base-image.sh` |
| `git-config` | `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_0` at workflow scope |
| csharp's five `*-workflow-policy.test.mjs` | §4.4 |

Three of these are worth a sentence each, because box's version is not merely
equivalent:

* `check-docker-publish` (js) asks whether the publish step succeeded.
  `check-publication.sh` asks the registries **anonymously**, which is the only
  view a reader has - issue #117 found the authenticated answer was 28 of 56 image
  references while the anonymous answer was 0 of 56.
* `push-main-with-rebase-retry` (js) answers every rejected push with a rebase.
  `git-push-with-retry.sh` classifies first, because #121 measured that a
  repository-rule rejection prints the same word as a lost race, and rebasing
  against a rule produces an identical second rejection blamed on a race that never
  happened.
* `land-via-pull-request` is a separate js script; in box it is a function inside
  the classifier's caller, reached only on the branch the classifier selects.

### 4.4 csharp's five workflow-policy tests

`docs-workflow-policy`, `links-workflow-policy`, `release-workflow-policy`,
`security-workflow-policy` and `workflow-injection-policy` are `*.test.mjs` files
that assert the *shape* of csharp's workflows. They are the closest thing in any
template to what issue #123 is about, so each assertion was read and checked
against box rather than waved through:

| csharp assertion | box |
|---|---|
| every job sets `timeout-minutes` | `scripts/ci/check-timeout-budgets.mjs`, plus #121's measurement of all 127 jobs and `docs/CI-TIMEOUT-BUDGETS.md` |
| jobs with skipped dependencies use a status-check function | `scripts/ci/check-status-gate-covers-all-jobs.mjs` fails CI when a job is added outside a gate |
| release runs on main are not cancelled by newer pushes | `scripts/ci/read-job-cancel-in-progress.mjs` |
| the default git branch is configured before checkout | measured here: **15 of box's 15 workflows** set `GIT_CONFIG_KEY_0: init.defaultBranch` |
| no workflow interpolates attacker-controlled context into `run:` | `scripts/ci/run-zizmor.sh`, widened in #121 to the composite actions; re-measured here (§6) |
| `$GITHUB_OUTPUT` redirections are quoted | re-measured here: **0 unquoted of 69** shell redirections across `.github`, `scripts`, `.githooks` |
| every workflow is linted with actionlint plus its shellcheck | `docker://rhysd/actionlint`, pinned to v1.7.12 in #121 with an offline version floor |
| documentation builds are independent of the Pages opt-in | box publishes no GitHub Pages site; `docs.yml` runs `check-required-docs.sh` |
| Codecov uploads are gated on an explicit token | box uploads no coverage |
| the links workflow uses least privilege and a bounded Wayback fallback | `links.yml` + `scripts/ci/recheck-broken-links.mjs` + `check-web-archive` |
| CodeQL analyses the language and GitHub Actions | `security.yml` |

The practice is held in every case where box has the thing the assertion is about.
The **packaging** differs: csharp expresses these as node test files, box as CI
scripts that a workflow runs and that `run-precommit-checks.sh` also runs before a
commit. box has no `package.json` at its root and therefore no node test runner -
the same fact that made #121 record the pre-commit-hook practice as "right about
the practice, wrong about the tool".

## 5. The workflow matrix

17 workflow roles. box 15; js, python, rust, php and csharp 5 each; go and java 1
each.

| workflow | box | js | python | rust | php | csharp | go | java |
|---|---|---|---|---|---|---|---|---|
| `release` | x | x | x | x | x | x | x | x |
| `links` | x | x | x | x | x | x | . | . |
| `security` | x | x | x | x | x | x | . | . |
| `workflows` | x | x | x | x | x | x | . | . |
| `docs` | x | . | x | . | x | x | . | . |
| `dockerfiles` | x | . | . | . | . | . | . | . |
| `file-sizes` | x | . | . | . | . | . | . | . |
| `measure-disk-space` | x | . | . | . | . | . | . | . |
| `pr-tests` | x | . | . | . | . | . | . | . |
| `release-dind` | x | . | . | . | . | . | . | . |
| `release-essentials` | x | . | . | . | . | . | . | . |
| `release-full` | x | . | . | . | . | . | . | . |
| `release-js` | x | . | . | . | . | . | . | . |
| `release-languages` | x | . | . | . | . | . | . | . |
| `scripts` | x | . | . | . | . | . | . | . |
| `desktop-release` | . | . | . | x | . | . | . | . |
| `example-app` | . | x | . | . | . | . | . | . |

Two template workflows box does not have, both declined for the reason in §4.2:
rust's `desktop-release` (a Tauri app) and js's `example-app` (the template's
demonstration application). Ten box workflows exist in no template, and nine of
those ten are the container build and measurement pipeline no template has an
equivalent of; the tenth, `scripts.yml`, is the static-analysis workflow #115
added after a quoted heredoc referenced a parent-shell variable and broke main.

go and java have `release.yml` and nothing else. They are the two templates that
have not been touched since December 2025, and they are where the *absence* of a
practice says nothing: neither has a links workflow, a security workflow or a
status gate, so a role missing from them is not a decision anyone made.

## 6. Composite actions

| repo | `.github/actions/*` |
|---|---|
| box | `dockerhub-login`, `free-disk-space`, `setup-buildx-resilient`, `simulate-fresh-merge` |
| js | `publish-dockerhub`, `setup-buildx-resilient` |
| rust | `setup-buildx-resilient` |
| python, php, csharp, go, java | none |

`setup-buildx-resilient` is the one action all three share, and box's is the
superset: `diff` against js's copy shows box carries the `cleanup` input the other
two do not - the measured answer to the `docker buildx rm` timeout warning from
#121, filed upstream as docker/buildx#4067 and
docker/setup-buildx-action#615. js's and rust's copies are 109 and 110 lines
against box's 149; the rest of the difference is prose pointing at each
repository's own issue numbers.

js's `publish-dockerhub` is one composite that logs in, builds and pushes a
single platform-specific image by digest. box does the same three things in three
places, because it pushes many images from many jobs: `dockerhub-login` for the
credentials, `docker-push-with-retry.sh` for the push (with the failure classifier
js has no counterpart to), and `create-multiarch-manifest.sh` for the manifest
that joins the per-platform digests. box's `free-disk-space` and
`simulate-fresh-merge` exist in no template.

## 7. What this comparison changed on this branch

Nothing, and that is the finding. The 91-role gap resolves to 24 internal classes,
39 renames, 22 ecosystem-specific scripts and 6 declined practices, each declined
with a measurement above. The practices worth adopting were adopted in #115, #117
and #121; what #123 found in the templates is recorded in §4.4 as held.

The defects #123 does fix were found in box's own tree, not in the gap against a
template - which is itself worth recording, because "compare against the template"
is the cheapest hypothesis and it came back empty. The one template-derived
question that was still open, csharp's `$GITHUB_OUTPUT` quoting assertion, was
answered by measurement (0 of 69 unquoted) rather than by adopting a test that
could not fail.
