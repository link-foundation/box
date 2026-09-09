# Job logs, release run 34293699247 and neighbours

Every file here is `gh run view <run-id> --log` output, gzipped because
`.gitignore` excludes `*.log` and because the two job logs are ~1.6 MB raw.
The uncompressed copies are what the analysis was done against; read one with
`zcat <file>.log.gz`.

| File | What it is |
|---|---|
| `release-34293699247.log` | the release run's own summary line |
| `job-js-build-amd64-102285690450.log` | the amd64 half of `js / build-js-amd64`. No warning annotations at all; the `Free disk space` step removes `azure-cli`, `firefox`, `google-chrome-stable` and `powershell` successfully (`Removing …` at 00:09:43-00:09:45) |
| `job-js-build-arm64-102285690839.log` | the arm64 half of the same job, same commit, same step. Line 1528 `E: Unable to locate package google-chrome-stable`, line 1529 the resulting `##[warning]`. It is the job's only warning, and none of the six packages were removed - apt abandons the whole command at the first name it cannot resolve. This pair is the evidence for the `large-packages` finding of issue #121 |
| `workflows-34293699033.log` | the `workflows` check of the same push |
| `scripts-34293699072.log` | the `scripts` check |
| `security-34293699154.log` | the `security` check |
| `links-34293698989.log` | the `links` check |
| `file-sizes-34293699000.log` | the `file-sizes` check |
| `dockerfiles-34011750123.log` | the `dockerfiles` check, from the most recent run that reached hadolint. 10 advisory notices, all below the failure threshold |
| `measure-disk-34011750117.log` | the `measure-disk-space` run of the same push |

`experiments/test-issue121-reclaim-large-packages.sh` reads the two job logs, so
the claims in the table above are checked rather than asserted.
