# Warning/error text census for all nine issue #125 runs

Regenerate with `bash experiments/issue-125/census-warnings-errors.sh`.
The raw TSV columns are source, class, job, text.

| Class | Lines | Distinct texts |
| --- | ---: | ---: |
| `annotation` | 3 | 2 |
| `tool` | 1851 | 46 |
| `bracketed-text` | 1 | 1 |
| `assertion` | 16 | 15 |
| `action-help` | 42 | 3 |
| `step-script` | 571 | 21 |
| `docker-build` | 114 | 114 |

## Every `annotation` line, deduplicated

```text
      1 pipeline-status | ##[error]Process completed with exit code 1.
      1 pipeline-status | ##[error]Failing jobs: measure-disk-space
      1 Measure Component Disk Space | ##[error]Process completed with exit code 1.
```

## Every `tool` line, deduplicated

```text
    900 Measure Component Disk Space | scripts/ci/run-with-budget-warning.sh: line 156: /tmp/budget-status.mwvhb9/stdout: No such file or directory
    900 Measure Component Disk Space | scripts/ci/run-with-budget-warning.sh: line 156: /tmp/budget-status.mwvhb9/stderr: No such file or directory
      1 security / secretlint | Running secretlint with a 180s budget (warning at 126s).
      1 security / secretlint | Running secretlint gate fixtures with a 120s budget (warning at 84s).
      1 security / CodeQL (python) | [command]tar -x --zstd --ignore-zeros --warning=no-unknown-keyword --overwrite -f - -C /opt/hostedtoolcache/CodeQL/2.27.0/x64
      1 security / CodeQL (python) | [39/45] Loaded /opt/hostedtoolcache/CodeQL/2.27.0/x64/codeql/qlpacks/codeql/python-queries/1.8.10/Diagnostics/ExtractionWarnings.qlx.
      1 security / CodeQL (python) | [2/45 eval 2.2s] Evaluation done; writing results to codeql/python-queries/Diagnostics/ExtractionWarnings.bqrs.
      1 security / CodeQL (python) | Starting evaluation of codeql/python-queries/Diagnostics/ExtractionWarnings.ql.
      1 security / CodeQL (python) | Interpreting /opt/hostedtoolcache/CodeQL/2.27.0/x64/codeql/qlpacks/codeql/python-queries/1.8.10/Diagnostics/ExtractionWarnings.ql...
      1 security / CodeQL (python) | Interpreted diagnostic query "Python extraction warnings" (py/diagnostics/extraction-warnings) at path /home/runner/work/_temp/codeql_databases/python/results/codeql/python-queries/Diagnostics/ExtractionWarnings.bqrs.
      1 security / CodeQL (python) |  ... found results file at /home/runner/work/_temp/codeql_databases/python/results/codeql/python-queries/Diagnostics/ExtractionWarnings.bqrs.
      1 security / CodeQL (python) |   expect-error: false
      1 security / CodeQL (python) |     "suppressesMissingFileBaselineWarning": true
      1 security / CodeQL (javascript-typescript) | [command]tar -x --zstd --ignore-zeros --warning=no-unknown-keyword --overwrite -f - -C /opt/hostedtoolcache/CodeQL/2.27.0/x64
      1 security / CodeQL (javascript-typescript) | [85/89] Loaded /opt/hostedtoolcache/CodeQL/2.27.0/x64/codeql/qlpacks/codeql/javascript-queries/2.4.5/Diagnostics/ExtractionErrors.qlx.
      1 security / CodeQL (javascript-typescript) | [2/89 eval 1.6s] Evaluation done; writing results to codeql/javascript-queries/Diagnostics/ExtractionErrors.bqrs.
      1 security / CodeQL (javascript-typescript) | Starting evaluation of codeql/javascript-queries/Diagnostics/ExtractionErrors.ql.
      1 security / CodeQL (javascript-typescript) | Interpreting /opt/hostedtoolcache/CodeQL/2.27.0/x64/codeql/qlpacks/codeql/javascript-queries/2.4.5/Diagnostics/ExtractionErrors.ql...
      1 security / CodeQL (javascript-typescript) | Interpreted diagnostic query "Extraction errors" (js/diagnostics/extraction-errors) at path /home/runner/work/_temp/codeql_databases/javascript/results/codeql/javascript-queries/Diagnostics/ExtractionErrors.bqrs.
      1 security / CodeQL (javascript-typescript) |  ... found results file at /home/runner/work/_temp/codeql_databases/javascript/results/codeql/javascript-queries/Diagnostics/ExtractionErrors.bqrs.
      1 security / CodeQL (javascript-typescript) |   expect-error: false
      1 security / CodeQL (javascript-typescript) |     "suppressesMissingFileBaselineWarning": true
      1 security / CodeQL (actions) | [command]tar -x --zstd --ignore-zeros --warning=no-unknown-keyword --overwrite -f - -C /opt/hostedtoolcache/CodeQL/2.27.0/x64
      1 security / CodeQL (actions) |   expect-error: false
      1 security / CodeQL (actions) |     "suppressesMissingFileBaselineWarning": true
      1 scripts / shellcheck | ==> shellcheck --severity=warning over 207 tracked shell script(s)
      1 scripts / shellcheck | ==> No shellcheck findings at or above severity 'warning'
      1 scripts / regression suites | Running every experiment suite with a 600s budget (warning at 420s).
      1 scripts / regression suites | RUN   test-issue104-vfs-warning.sh
      1 scripts / regression suites | ==> RUN  test-issue104-vfs-warning.sh
      1 scripts / regression suites |   if-no-files-found: error
      1 links / lychee | | 🚫 Errors      | 0     |
      1 file sizes / line limits | scripts/ci/run-with-budget-warning.sh
      1 file sizes / line limits | experiments/test-issue104-vfs-warning.sh
      1 file sizes / line limits | experiments/issue-123/census-warnings-errors.sh
      1 file sizes / line limits | Checked 317 tracked files against a 1500-line limit (warning at 1350).
      1 file sizes / line limits | == Part 3: the warning threshold fires before the limit does ==
      1 Measure Component Disk Space | Running disk space measurement with a 2400s budget (warning at 1680s).
      1 Measure Component Disk Space |   if-no-files-found: error
      1 95_preflight | ==> 2 registry credential(s) accepted a write, 0 warning(s).
      1 92_detect-changes |   scripts/ci/run-with-budget-warning.sh
      1 92_detect-changes |   experiments/issue-123/census-warnings-errors.sh
      1 92_detect-changes |   dev/log/issues/123/pulls/124/templates/rust/scripts/run-with-budget-warning.sh
      1 92_detect-changes |   dev/log/issues/123/pulls/124/templates/python/scripts/run-with-budget-warning.sh
      1 92_detect-changes |   dev/log/issues/123/pulls/124/templates/php/scripts/run-with-budget-warning.sh
      1 92_detect-changes |   dev/log/issues/123/pulls/124/templates/js/scripts/run-with-budget-warning.sh
      1 92_detect-changes |   dev/log/issues/123/pulls/124/analysis/warnings-errors.raw.tsv
      1 92_detect-changes |   dev/log/issues/123/pulls/124/analysis/warnings-errors.census.md
      1 48_full _ docker-build-push | Running full box smoke test with a 600s budget (warning at 420s).
      1 38_dind _ build-dind-arm64 (swift) | ERROR: copy sha256:50bddea1d9d1a229913d611a0ab79ea69f6641ee048b1e7d91521efecc2f9cd1 from ghcr.io/link-foundation/box-swift-dind:2.10.0-arm64 to docker.io/***/box-swift-dind:latest-arm64: failed to copy: stream error: str
      1 23_dind _ build-dind-arm64 (php) | ERROR: copy sha256:aa933b1fa633f2db3b6f33d63eabbee08f04b6e49ba25c3e29ddd96902fab8f4 from ghcr.io/link-foundation/box-php-dind:2.10.0-arm64 to docker.io/***/box-php-dind:latest-arm64: failed to copy: stream error: stream
      1 18_dind _ build-dind-arm64 (full) | ERROR: copy sha256:3aec53af083b8e240d54ea5af7f1bfe2719679290ebbbe445bbe7f45b46fd1f3 from ghcr.io/link-foundation/box-dind:2.10.0-arm64 to docker.io/***/box-dind:latest-arm64: failed to copy: stream error: stream ID 51; P
      1 17_dind _ build-dind-amd64 (rocq) | ERROR: copy sha256:0ad6c95a2fd3800787439b6808aa3baccd17a56b53e45eb7771f315bffa31c6e from ghcr.io/link-foundation/box-rocq-dind:2.10.0-amd64 to docker.io/***/box-rocq-dind:latest-amd64: failed to copy: stream error: strea
```

## BuildKit lines containing a warning token, deduplicated

```text
      4 update-alternatives: warning: skip creation of /usr/share/man/man1/unlzma.1.gz because associated file /usr/share/man/man1/unxz.1.gz (of link group lzma) doesn't exist
      4 update-alternatives: warning: skip creation of /usr/share/man/man1/lzmore.1.gz because associated file /usr/share/man/man1/xzmore.1.gz (of link group lzma) doesn't exist
      4 update-alternatives: warning: skip creation of /usr/share/man/man1/lzma.1.gz because associated file /usr/share/man/man1/xz.1.gz (of link group lzma) doesn't exist
      4 update-alternatives: warning: skip creation of /usr/share/man/man1/lzless.1.gz because associated file /usr/share/man/man1/xzless.1.gz (of link group lzma) doesn't exist
      4 update-alternatives: warning: skip creation of /usr/share/man/man1/lzgrep.1.gz because associated file /usr/share/man/man1/xzgrep.1.gz (of link group lzma) doesn't exist
      4 update-alternatives: warning: skip creation of /usr/share/man/man1/lzfgrep.1.gz because associated file /usr/share/man/man1/xzfgrep.1.gz (of link group lzma) doesn't exist
      4 update-alternatives: warning: skip creation of /usr/share/man/man1/lzegrep.1.gz because associated file /usr/share/man/man1/xzegrep.1.gz (of link group lzma) doesn't exist
      4 update-alternatives: warning: skip creation of /usr/share/man/man1/lzdiff.1.gz because associated file /usr/share/man/man1/xzdiff.1.gz (of link group lzma) doesn't exist
      4 update-alternatives: warning: skip creation of /usr/share/man/man1/lzcmp.1.gz because associated file /usr/share/man/man1/xzcmp.1.gz (of link group lzma) doesn't exist
      4 update-alternatives: warning: skip creation of /usr/share/man/man1/lzcat.1.gz because associated file /usr/share/man/man1/xzcat.1.gz (of link group lzma) doesn't exist
      2 update-alternatives: warning: skip creation of /usr/share/man/sv/man1/fakeroot.1.gz because associated file /usr/share/man/sv/man1/fakeroot-sysv.1.gz (of link group fakeroot) doesn't exist
      2 update-alternatives: warning: skip creation of /usr/share/man/sv/man1/faked.1.gz because associated file /usr/share/man/sv/man1/faked-sysv.1.gz (of link group fakeroot) doesn't exist
      2 update-alternatives: warning: skip creation of /usr/share/man/man1/open.1.gz because associated file /usr/share/man/man1/xdg-open.1.gz (of link group open) doesn't exist
      2 update-alternatives: warning: skip creation of /usr/share/man/man1/fakeroot.1.gz because associated file /usr/share/man/man1/fakeroot-sysv.1.gz (of link group fakeroot) doesn't exist
      2 update-alternatives: warning: skip creation of /usr/share/man/man1/faked.1.gz because associated file /usr/share/man/man1/faked-sysv.1.gz (of link group fakeroot) doesn't exist
      2 update-alternatives: warning: skip creation of /usr/share/man/man1/f95.1.gz because associated file /usr/share/man/man1/gfortran.1.gz (of link group f95) doesn't exist
      2 update-alternatives: warning: skip creation of /usr/share/man/man1/f77.1.gz because associated file /usr/share/man/man1/gfortran.1.gz (of link group f77) doesn't exist
      2 update-alternatives: warning: skip creation of /usr/share/man/man1/c++.1.gz because associated file /usr/share/man/man1/g++.1.gz (of link group c++) doesn't exist
      2 update-alternatives: warning: skip creation of /usr/share/man/fr/man1/fakeroot.1.gz because associated file /usr/share/man/fr/man1/fakeroot-sysv.1.gz (of link group fakeroot) doesn't exist
      2 update-alternatives: warning: skip creation of /usr/share/man/fr/man1/faked.1.gz because associated file /usr/share/man/fr/man1/faked-sysv.1.gz (of link group fakeroot) doesn't exist
      2 update-alternatives: warning: skip creation of /usr/share/man/es/man1/fakeroot.1.gz because associated file /usr/share/man/es/man1/fakeroot-sysv.1.gz (of link group fakeroot) doesn't exist
      2 update-alternatives: warning: skip creation of /usr/share/man/es/man1/faked.1.gz because associated file /usr/share/man/es/man1/faked-sysv.1.gz (of link group fakeroot) doesn't exist
      2 Warning: /home/linuxbrew/.linuxbrew/bin is not in your PATH.
      2 WARNING: seems you still have not added 'pyenv' to the load path.
```
