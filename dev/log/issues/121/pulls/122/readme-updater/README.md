# The job that commits the README could commit another run's numbers

`.github/workflows/measure-disk-space.yml` measures the box's components,
runs `scripts/update-readme-sizes.sh`, and commits `README.md` to `main`. The
script that decides what goes into that commit had three defects, all recorded
here against `b8ef077` — the tree of this branch before the fix.

| Defect | Symptom in CI |
| --- | --- |
| The table was rendered to `/tmp/markdown_table_content.txt`, one fixed path every invocation on the machine shares | another run's measurements written into this README, **exit 0** |
| The branch taken when the README has lost its markers read that file three lines *before* writing it | `FileNotFoundError`, exit 1, README untouched |
| `--readme-file` / `--json-file` set shell variables the `python3` children never received | the script announces one file and rewrites another |

`probes-before-fix.txt` is the three defects reproduced by hand, one probe
each. Probe 2 is the one to read: a leftover `/tmp/markdown_table_content.txt`
containing `STALE TABLE FROM ANOTHER RUN` ends up between the restored markers
and the script exits 0, which in the workflow is a commit to `main`.

`suite-before-fix.txt` is `experiments/test-issue121-readme-updater.sh` run
against that same tree: **passed 15, failed 10**. Against the fixed script it
is 25 passed, 0 failed.

Reproduce:

```bash
git stash                                   # or check out b8ef077
bash experiments/test-issue121-readme-updater.sh   # 10 failures
git stash pop
bash experiments/test-issue121-readme-updater.sh   # 25 assertions, 0 failures
```
