# CI logs

The eight workflows small enough for `gh run view --log` have complete aggregate
logs named `<run-id>.log.gz`. The release aggregate marker records GitHub CLI's
refusal to assemble a 99-job run because doing so exceeds its API-request cap.
It is not treated as an empty log.

`build-release-34455018919.zip` is GitHub's official log archive for that run,
downloaded directly from the Actions API. It contains logs for all 94 jobs that
ran. The other five jobs have conclusion `skipped` in
`../runs/34455018919.jobs.json` and correctly have no log payload. The 94
extracted per-job copies are independently gzipped to make the census
reproducible without another API request or ZIP extraction.

| Run | Workflow | Aggregate log |
| --- | --- | --- |
| 34455018688 | Links | `34455018688.log.gz` |
| 34455018700 | Workflows | `34455018700.log.gz` |
| 34455018611 | Docs | `34455018611.log.gz` |
| 34455018674 | File sizes | `34455018674.log.gz` |
| 34455018599 | Dockerfiles | `34455018599.log.gz` |
| 34455018650 | Security | `34455018650.log.gz` |
| 34455018681 | Scripts | `34455018681.log.gz` |
| 34455018634 | Measure Disk Space | `34455018634.log.gz` |
| 34455018919 | Build and Release | official zip plus 94 extracted job logs |

The named uncompressed `.log` files are collection working copies and are
ignored by this repository. The gzipped/zip payloads are the durable evidence.
