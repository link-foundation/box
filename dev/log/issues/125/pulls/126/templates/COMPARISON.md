# Full CI/CD tree comparison

Issue #125 asks for the full GitHub workflow and CI/CD-script trees of the
JavaScript, Python, Rust, and PHP templates. `snapshot-templates.sh` cloned the
current default branches, recorded every tracked path, and copied every
`.github/**`, `scripts/**`, and CI-consumed root configuration/documentation
file. The complete trees—not merely a filename search—are the four
`*.file-tree.txt` files in this directory.

## Revisions

| Template | Revision | Tracked files | Stored CI files |
| --- | --- | ---: | ---: |
| JavaScript | `c3a6d23b693972a70097430f01e69fcee5a51ad2` | 393 | 65 |
| Python | `470e17605fc37b33fd7ea4e8aa8d16eaab1d9253` | 96 | 32 |
| Rust | `f63a061fb3e23e647de0455886528a121b997678` | 158 | 45 |
| PHP | `15c327be682deab6b65c69d48ef43e069d60bd01` | 211 | 49 |

All four revisions are identical to those in issue #123's exhaustive
eight-repository comparison. That matters: the 84 template-only roles map
one-for-one to the already recorded per-role dispositions in
`dev/log/issues/123/pulls/124/templates/COMPARISON.md`; no upstream code changed
between that audit and this one. The files were nevertheless freshly fetched
and compared so the conclusion does not depend on assuming they stayed still.

## Role-level result

Filenames differ across languages, so `compare-template-roles.sh` normalizes
extensions, test prefixes, and underscore/dash spelling. Its two complete
matrices are stored beside this document.

| Scope | Union | box | JS | Python | Rust | PHP |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| CI/CD script roles | 155 | 71 | 49 | 20 | 31 | 39 |
| workflow roles | 17 | 15 | 5 | 5 | 5 | 5 |

For scripts, box has 56 roles unique to its container/release pipeline, shares
15 roles with at least one template, and lacks 84 template roles. The absent
roles remain one of:

- language/package-specific (`npm`, PyPI, crates.io, Packagist, desktop
  packaging), inapplicable because box publishes images and has no root package
  manifest;
- a differently named box implementation (change detection, changesets,
  versioning, release notes, retry, publication checks);
- internal PHP classes rather than standalone CI gates;
- previously measured and declined, chiefly dependency review for a repository
  with no dependency manifest outside evidence snapshots.

The raw matrix names all 84. The prior comparison's table records the exact box
equivalent or reason for every row, and the pinned upstream identity proves
those dispositions still address the same code. No missing practice was found.

## The semantic comparison that found this issue

The shared `run-with-budget-warning` role was read in all five repositories;
matching a role name alone would have missed the defect.

| Repository | Completion mechanism | Private files under child `TMPDIR` | Affected by cleanup race |
| --- | --- | --- | --- |
| box before fix | atomic status file; captured stdout/stderr | yes, all three | **yes** |
| JavaScript template | atomic status file | yes | **yes** |
| Python template | child/process polling | no | no |
| Rust template | child/process polling | no | no |
| PHP template | child/process polling | no | no |

The same minimum fixture fails on the box baseline and JavaScript template. It
passes after box selects `RUNNER_TEMP`; results are in
`../analysis/reproducer-*.log.gz`. The JavaScript finding was reported upstream as
[issue #189](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/189).

## Whole-codebase reach

box owns a single implementation of the wrapper and invokes it 15 times across
measurement, security, pull-request builds/tests, and regression suites. There
is no copied implementation to patch independently. The central correction
therefore covers every live call site. Copies below `dev/log/` are immutable
evidence from other projects and are not executable repository code.

The later verbose-secret sweep also searched these four complete snapshots.
None contains a shell or workflow xtrace entry point, so the three
credential-tracing defects found in box have no template counterpart. The
budget-state defect remains the only issue #125 finding requiring an upstream
template report.
