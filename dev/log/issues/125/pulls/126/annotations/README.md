# Annotations for every issue #125 run

The collector paginated every check run's annotations endpoint and wrote one
JSON array per workflow run. Counts come from those arrays, not log parsing.

| Run | Conclusion | Notice | Warning | Failure |
| --- | --- | ---: | ---: | ---: |
| 34455018688 Links | success | 1 | 0 | 0 |
| 34455018700 Workflows | success | 0 | 0 | 0 |
| 34455018611 Docs | success | 0 | 0 | 0 |
| 34455018674 File sizes | success | 0 | 0 | 0 |
| 34455018599 Dockerfiles | success | 0 | 0 | 0 |
| 34455018650 Security | success | 0 | 0 | 0 |
| 34455018681 Scripts | success | 0 | 0 | 0 |
| 34455018634 Measure Disk Space | failure | 0 | 0 | 3 |
| 34455018919 Build and Release | success | 0 | 0 | 0 |

The Links notice is lychee's pointer to its successful summary. The three
failures are the measurement process exit, the terminal gate's named failing
job, and the terminal gate's process exit. `../analysis/ROOT-CAUSES.md` explains
why only the first underlying verdict is fixed and propagation remains intact.
