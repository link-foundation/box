# zizmor: the offline default, measured

Evidence for the zizmor half of issue #123 — the Workflows job that reported
"No findings to report" while telling the log it had switched off part of its
audit set.

| File | What it is |
| --- | --- |
| `offline-regular.txt` | The regular pass exactly as run 34366975873 ran it: `docker run` with no `-e GH_TOKEN`. One offline banner. |
| `online-regular.txt` | The same pass with `-e GH_TOKEN`. No banner, `No findings to report. Good job! (246 ignored, 248 suppressed)`, exit 0. |
| `online-pedantic.txt` | The pedantic pass with a token: `No findings to report. Good job! (488 ignored, 6 suppressed)`, exit 0. So switching this repository to online mode costs nothing today. |
| `offline-vs-online-fixture.txt` | `experiments/reproduce-issue123-zizmor-offline-audits.sh` over a fixture pinning `tj-actions/changed-files@v44` (CVE-2025-30066). This is the finding the offline default removes. |
| `runner-regular.txt`, `runner-pedantic.txt` | Both shipped passes through `scripts/ci/run-zizmor.sh` after the fix. |

The difference the fixture measures, zizmor 1.30.0, same analyser and same
input, twice:

```
offline  known-vulnerable-actions: 0   offline banner: 1   7 findings (3 suppressed, 1 unsafe fixes): 0 informational, 0 low, 2 medium, 2 high
online   known-vulnerable-actions: 2   offline banner: 0   8 findings (3 suppressed, 4 unsafe fixes): 0 informational, 0 low, 2 medium, 3 high
```

Root cause: since zizmor 1.0 the analyser runs offline unless it is given a
GitHub API token, and `docker run` forwards no environment, so neither pass had
one — the job could not have run `known-vulnerable-actions` even in principle.
The audit asks the GitHub Advisory Database whether a pinned action has a
published advisory, which is the only check here that can catch a compromise of
an action the repository already trusts.

Fix: `scripts/ci/run-zizmor.sh` passes the token by name and fails the job on
the banner; `experiments/test-issue123-zizmor-token.sh` asserts it offline.
