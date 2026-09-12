# Timeline

All times are UTC.

| Time | Event | Evidence |
| --- | --- | --- |
| 2026-09-10 08:24:45 | PR #124 merged as `90f1e2d95adbb0beb132da366b28d14a3746347c`. | `related-pr-124.json` |
| 08:24:48 | All nine workflows named by issue #125 were created for that merge. | `runs/index.json` |
| 08:24:51 | Disk-space validation and measurement jobs started in parallel. | `runs/34455018634.jobs.json` |
| 08:24:59 | Validation completed successfully. | same |
| 08:26:40.859 | The measurement wrapper announced its 2,400-second budget. Its state directory was `/tmp/budget-status.mwvhb9`. | `ci-logs/34455018634.log.gz` |
| 08:26:41.902 | The first missing `stdout` error appeared; missing `stderr` followed 1.4 ms later. The child had run `cleanup_for_measurement`, including `rm -rf /tmp/*`. | run log; `scripts/measure-disk-space.sh:201-210` |
| 08:26:41–08:42:00 | Each one-second poll failed to open both captured streams: 900 stdout and 900 stderr failures. Child output after cleanup was not relayed. | warning/error census |
| 08:41:59 | Despite the lost live output, the measurement generated a complete JSON document: 27 components, 4,835 MB total. | `artifacts/measure-disk-space/data/disk-space-measurements.json` |
| 08:42:00.485 | The command's bookkeeping could not recreate the deleted status path. The wrapper used its subshell's bookkeeping status and reported exit 1 after 920 seconds, well inside budget. | run log and baseline reproduction |
| 08:42:00.489 | GitHub recorded the measure step's process-exit failure. | annotation JSON/run log |
| 08:42:03 | The measurement job completed as failure, after its artifact upload succeeded. | jobs/artifact metadata |
| 08:42:10 | The terminal gate correctly named `measure-disk-space` and exited 1. | run log/annotations |
| 08:42:12 | The workflow completed as failure. | job metadata |
| 10:16:59 | The 99-job release workflow completed successfully. Four registry-copy first attempts had failed, and all four second attempts succeeded. | release job logs/run metadata |
| 2026-09-12 16:44:46 | Issue #125 was opened from those nine run results. | `issue.json` |
| 16:45:45 | Draft PR #126 was opened. | `pr.json` |
| 2026-09-12 | The local reproducer failed on the merge baseline and the current JavaScript template, then passed after state isolation. | `analysis/reproducer-*.log` |
| 2026-09-12 | The related JavaScript-template defect was reported as issue #189. | `upstream/js-issue-189.json` |
| 2026-09-12 | The deliberately forced-verbose final gate put the live GitHub token into each local zizmor log five times. Staged secretlint rejected the snapshot before commit or push. | local verification; `analysis/VERBOSE-SECRET-SWEEP.md` |
| 2026-09-12 | An offline canary regression reproduced credential disclosure in zizmor, registry-probe, and credential-preflight tracing: three functional passes and three secrecy failures. | `analysis/verbose-secret-redaction-before.txt` |
| 2026-09-12 | Raw xtrace was removed from the two registry credential paths and suspended around zizmor's token branch. The regression passed 6/6 and real online verbose zizmor passed in both modes without a token or placeholder in either saved log. | `analysis/verbose-secret-redaction-after.txt`; `local-tests/zizmor-*.txt` |

The ordering rules out an installation failure: the control directory vanished
one second after the wrapper began, the child continued for another 918 seconds,
and the completed result artifact is timestamped one second before the wrapper's
bookkeeping failure.
