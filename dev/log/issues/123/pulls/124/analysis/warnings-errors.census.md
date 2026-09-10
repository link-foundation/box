# Every line in the nine runs that says `warn` or `error`

Regenerate with `bash experiments/issue-123/census-warnings-errors.sh`.
Columns of `warnings-errors.raw.tsv`: source, class, job, text.

| Class | Lines | Distinct texts |
| --- | ---: | ---: |
| `annotation` | 10 | 5 |
| `tool` | 47 | 39 |
| `assertion` | 17 | 15 |
| `action-help` | 42 | 3 |
| `step-script` | 574 | 21 |
| `docker-build` | 114 | 114 |

## Every `annotation` line, deduplicated

```
      2 pipeline-status | ##[warning]measure-disk-space. This run is no longer the head of main, so the cancellation reads as a supersede rather than an overrun.
      2 Measure Component Disk Space | ##[warning]disk space measurement has run for 1680s of its 2400s budget.
      2 Measure Component Disk Space | ##[error]disk space measurement did not finish within its 2400s budget and was terminated. Shorten the step or raise its budget (keeping it below the job's time
      2 Measure Component Disk Space | ##[error]The operation was canceled.
      2 Apply Changesets | ##[error]` while explaining a fix. `docker/setup-buildx-action` creates a `docker-container` builder, and since buildx v0.30.0 that driver bakes the whole `GITH
```

## Every `tool` line, deduplicated

```
      2 zizmor |  WARN audit: zizmor: zizmor is running in offline mode by default; some audits and auto-fixes will not be available. see https://docs.zizmor.sh/usage/#operating
      2 security / secretlint | tr: write error: Broken pipe
      2 Measure Component Disk Space | Running disk space measurement with a 2400s budget (warning at 1680s).
      1 security / secretlint | Running secretlint with a 180s budget (warning at 126s).
      1 security / secretlint | Running secretlint gate fixtures with a 120s budget (warning at 84s).
      1 security / CodeQL (python) | [40/45] Loaded /opt/hostedtoolcache/CodeQL/2.26.4/x64/codeql/qlpacks/codeql/python-queries/1.8.9/Diagnostics/ExtractionWarnings.qlx.
      1 security / CodeQL (python) | [2/45 eval 1.1s] Evaluation done; writing results to codeql/python-queries/Diagnostics/ExtractionWarnings.bqrs.
      1 security / CodeQL (python) | Starting evaluation of codeql/python-queries/Diagnostics/ExtractionWarnings.ql.
      1 security / CodeQL (python) | Interpreting /opt/hostedtoolcache/CodeQL/2.26.4/x64/codeql/qlpacks/codeql/python-queries/1.8.9/Diagnostics/ExtractionWarnings.ql...
      1 security / CodeQL (python) | Interpreted diagnostic query "Python extraction warnings" (py/diagnostics/extraction-warnings) at path /home/runner/work/_temp/codeql_databases/python/results/c
      1 security / CodeQL (python) |  ... found results file at /home/runner/work/_temp/codeql_databases/python/results/codeql/python-queries/Diagnostics/ExtractionWarnings.bqrs.
      1 security / CodeQL (python) |   expect-error: false
      1 security / CodeQL (python) |     "suppressesMissingFileBaselineWarning": true
      1 security / CodeQL (javascript-typescript) | [83/89] Loaded /opt/hostedtoolcache/CodeQL/2.26.4/x64/codeql/qlpacks/codeql/javascript-queries/2.4.4/Diagnostics/ExtractionErrors.qlx.
      1 security / CodeQL (javascript-typescript) | [2/89 eval 2.2s] Evaluation done; writing results to codeql/javascript-queries/Diagnostics/ExtractionErrors.bqrs.
      1 security / CodeQL (javascript-typescript) | Starting evaluation of codeql/javascript-queries/Diagnostics/ExtractionErrors.ql.
      1 security / CodeQL (javascript-typescript) | Interpreting /opt/hostedtoolcache/CodeQL/2.26.4/x64/codeql/qlpacks/codeql/javascript-queries/2.4.4/Diagnostics/ExtractionErrors.ql...
      1 security / CodeQL (javascript-typescript) | Interpreted diagnostic query "Extraction errors" (js/diagnostics/extraction-errors) at path /home/runner/work/_temp/codeql_databases/javascript/results/codeql/j
      1 security / CodeQL (javascript-typescript) |  ... found results file at /home/runner/work/_temp/codeql_databases/javascript/results/codeql/javascript-queries/Diagnostics/ExtractionErrors.bqrs.
      1 security / CodeQL (javascript-typescript) |   expect-error: false
      1 security / CodeQL (javascript-typescript) |     "suppressesMissingFileBaselineWarning": true
      1 security / CodeQL (actions) |   expect-error: false
      1 security / CodeQL (actions) |     "suppressesMissingFileBaselineWarning": true
      1 scripts / shellcheck | ==> shellcheck --severity=warning over 163 tracked shell script(s)
      1 scripts / shellcheck | ==> No shellcheck findings at or above severity 'warning'
      1 scripts / regression suites | Running every experiment suite with a 600s budget (warning at 420s).
      1 scripts / regression suites | RUN   test-issue104-vfs-warning.sh
      1 scripts / regression suites | ==> RUN  test-issue104-vfs-warning.sh
      1 scripts / regression suites |   if-no-files-found: warn
      1 preflight | ==> 2 registry credential(s) accepted a write, 0 warning(s).
      1 links / lychee | | 🚫 Errors      | 0     |
      1 full / docker-build-push | tr: write error: Broken pipe
      1 full / docker-build-push | grep: write error: Broken pipe
      1 full / docker-build-push | Running full box smoke test with a 600s budget (warning at 420s).
      1 file sizes / line limits | scripts/ci/run-with-budget-warning.sh
      1 file sizes / line limits | experiments/test-issue104-vfs-warning.sh
      1 file sizes / line limits | Checked 270 tracked files against a 1500-line limit (warning at 1350).
      1 file sizes / line limits | == Part 3: the warning threshold fires before the limit does ==
      1 detect-changes |   scripts/ci/run-with-budget-warning.sh
      1 detect-changes |   dev/log/issues/121/pulls/122/upstream/setup-buildx-post-rm-warning.md
      1 detect-changes |   dev/log/issues/121/pulls/122/templates/python-ai-driven-development-pipeline-template/tests/test_run_with_budget_warning.py
      1 detect-changes |   dev/log/issues/121/pulls/122/templates/python-ai-driven-development-pipeline-template/scripts/run-with-budget-warning.sh
      1 detect-changes |   dev/log/issues/121/pulls/122/templates/js-ai-driven-development-pipeline-template/tests/run-with-budget-warning.test.js
      1 detect-changes |   dev/log/issues/121/pulls/122/templates/js-ai-driven-development-pipeline-template/scripts/run-with-budget-warning.sh
```

## Every `docker-build` line that is a warning, deduplicated

The class is large (a package name containing `error` is in it) and
almost all of it is neither a warning nor an error, so this is the subset
where a tool inside the build said the word in the first person. The
`#NN N.NN` BuildKit prefix is stripped so the same line from two
architectures folds together.

```
      4 update-alternatives: warning: skip creation of /usr/share/man/man1/unlzma.1.gz because associated file /usr/share/man/man1/unxz.1.gz (of link group lzma) doesn'
      4 update-alternatives: warning: skip creation of /usr/share/man/man1/lzmore.1.gz because associated file /usr/share/man/man1/xzmore.1.gz (of link group lzma) does
      4 update-alternatives: warning: skip creation of /usr/share/man/man1/lzma.1.gz because associated file /usr/share/man/man1/xz.1.gz (of link group lzma) doesn't ex
      4 update-alternatives: warning: skip creation of /usr/share/man/man1/lzless.1.gz because associated file /usr/share/man/man1/xzless.1.gz (of link group lzma) does
      4 update-alternatives: warning: skip creation of /usr/share/man/man1/lzgrep.1.gz because associated file /usr/share/man/man1/xzgrep.1.gz (of link group lzma) does
      4 update-alternatives: warning: skip creation of /usr/share/man/man1/lzfgrep.1.gz because associated file /usr/share/man/man1/xzfgrep.1.gz (of link group lzma) do
      4 update-alternatives: warning: skip creation of /usr/share/man/man1/lzegrep.1.gz because associated file /usr/share/man/man1/xzegrep.1.gz (of link group lzma) do
      4 update-alternatives: warning: skip creation of /usr/share/man/man1/lzdiff.1.gz because associated file /usr/share/man/man1/xzdiff.1.gz (of link group lzma) does
      4 update-alternatives: warning: skip creation of /usr/share/man/man1/lzcmp.1.gz because associated file /usr/share/man/man1/xzcmp.1.gz (of link group lzma) doesn'
      4 update-alternatives: warning: skip creation of /usr/share/man/man1/lzcat.1.gz because associated file /usr/share/man/man1/xzcat.1.gz (of link group lzma) doesn'
      2 useradd: warning: the home directory /home/box already exists.
      2 update-alternatives: warning: skip creation of /usr/share/man/sv/man1/fakeroot.1.gz because associated file /usr/share/man/sv/man1/fakeroot-sysv.1.gz (of link g
      2 update-alternatives: warning: skip creation of /usr/share/man/sv/man1/faked.1.gz because associated file /usr/share/man/sv/man1/faked-sysv.1.gz (of link group f
      2 update-alternatives: warning: skip creation of /usr/share/man/man1/open.1.gz because associated file /usr/share/man/man1/xdg-open.1.gz (of link group open) does
      2 update-alternatives: warning: skip creation of /usr/share/man/man1/fakeroot.1.gz because associated file /usr/share/man/man1/fakeroot-sysv.1.gz (of link group f
      2 update-alternatives: warning: skip creation of /usr/share/man/man1/faked.1.gz because associated file /usr/share/man/man1/faked-sysv.1.gz (of link group fakeroo
      2 update-alternatives: warning: skip creation of /usr/share/man/man1/f95.1.gz because associated file /usr/share/man/man1/gfortran.1.gz (of link group f95) doesn'
      2 update-alternatives: warning: skip creation of /usr/share/man/man1/f77.1.gz because associated file /usr/share/man/man1/gfortran.1.gz (of link group f77) doesn'
      2 update-alternatives: warning: skip creation of /usr/share/man/man1/c++.1.gz because associated file /usr/share/man/man1/g++.1.gz (of link group c++) doesn't exi
      2 update-alternatives: warning: skip creation of /usr/share/man/fr/man1/fakeroot.1.gz because associated file /usr/share/man/fr/man1/fakeroot-sysv.1.gz (of link g
      2 update-alternatives: warning: skip creation of /usr/share/man/fr/man1/faked.1.gz because associated file /usr/share/man/fr/man1/faked-sysv.1.gz (of link group f
      2 update-alternatives: warning: skip creation of /usr/share/man/es/man1/fakeroot.1.gz because associated file /usr/share/man/es/man1/fakeroot-sysv.1.gz (of link g
      2 update-alternatives: warning: skip creation of /usr/share/man/es/man1/faked.1.gz because associated file /usr/share/man/es/man1/faked-sysv.1.gz (of link group f
      2 npm warn using --force Recommended protections disabled.
      2 Warning: /home/linuxbrew/.linuxbrew/bin is not in your PATH.
      2 WARNING: seems you still have not added 'pyenv' to the load path.
```
