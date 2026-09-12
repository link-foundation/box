# Hive-mind CI/CD practices reverified

The requested source is stored verbatim as
`../hive-mind-CI-CD-BEST-PRACTICES.md`. It was fetched from
`link-assistant/hive-mind` main at
`8d0f5fcf365067e1328400aefb1b13917981cf80` (version 2.27.0). Its SHA-256 is
`8ae31562b83000b61369c81802dbdde3b695acef7bad651aaee825c744b545f0`,
byte-for-byte identical to the document audited for issue #123. Each principle
was still remeasured against the current box tree.

| # | Practice | Result | Current measurement |
| ---: | --- | --- | --- |
| 1 | Run checks only on relevant changes | held | 8/15 workflows have path filters; `detect-changes.sh` classifies the release/PR matrices; path-coverage CI checks the mapping. |
| 2 | File-size limits | held | `check-file-line-limits.sh` scans maintained text and warns at 1,350/fails at 1,500 lines; evidence quotations are explicitly exempt. |
| 3 | Automated formatting | held | `run-shfmt.sh` checks every tracked shell script with a self-canary and is in CI/pre-commit. |
| 4 | Static analysis and linting | held | shellcheck, hadolint, actionlint, zizmor, secretlint, JS/Python syntax, heredoc, awk-portability, YAML, and policy checks are scripted gates. |
| 5 | Fast-fail ordering | held | cheap version, changeset, credential, and detection gates are `needs:` prerequisites of expensive build workflows; terminal status gates preserve failures. |
| 6 | Changeset versioning | held | `.changeset/` plus validation/application/release scripts; this fix includes a patch changeset. |
| 7 | Validate the actual merge result | held | composite `simulate-fresh-merge` plus a regression ensuring every relevant workflow uses it. |
| 8 | Pre-commit hooks | held | `.githooks/pre-commit` runs the staged snapshot through scoped local gates; failure to enumerate the index fails closed. |
| 9 | Release automation | held | `release.yml` coordinates five reusable build families, manifests, release notes, and publication checks. |
| 10 | Concurrency control | held | all 9 entry workflows carry the appropriate job/workflow concurrency policy; the 6 omissions are `workflow_call`-only and inherit their caller's run. |
| 11 | Secrets detection | held | secretlint runs in security CI and pre-commit with a canary proving the scanner actually inspected input. |
| 12 | Documentation validation | held | required headings/markers, local checks, workflow path coverage, and lychee fragment-aware links are checked. |
| 13 | Native architecture runners | held | five arm64 runner references build arm64 natively; no QEMU release-build path. |
| 14 | Lint workflows | held | real YAML parse is the floor, followed by pinned actionlint and online-token zizmor over workflows and composite actions. |
| 15 | Audit dependency tree | not applicable, measured | zero package/dependency manifests exist outside `dev/log/` quotations; base images and Dockerfiles—the dependencies box ships—are pinned/linted instead. |
| 16 | Prove publication access early | held | preflight opens/cancels registry blob-upload sessions before builds; post-publish checks read anonymously. |

## What this issue adds

The list is a floor, not proof that every implementation is correct. The broken
wrapper satisfied formatting, linting, timeout, and logging practices but
violated an ownership invariant none of those names express: parent control
state must not live in a namespace the child is allowed to erase. The new
regression makes that invariant executable.

The deliberately verbose final gate also demonstrated why practice 11 must
cover generated diagnostics, not merely source text: raw xtrace expanded a
live token before staged secretlint rejected the saved log. The fix removes
secret values from diagnostics at all three credential-consuming sites, and a
canary regression proves both function and non-disclosure. This tightens the
secrets-detection practice without assuming GitHub's masker is present in local
or third-party CI logs.

The selected `RUNNER_TEMP` fix also follows the source's broader principles:
use the platform-provided job scope, fail clearly when state cannot be created,
keep optional tracing off by default, and verify a failure path rather than
trusting configuration presence.
