---
'@link-foundation/example-package-name': patch
---

Fix every open CI correctness and resilience issue in the pipeline: scope the
Docker buildx cache, retry transient fetch and download failures, make the
budget wrapper escalate to SIGKILL, add a terminal status gate to every
workflow with supersede detection, verify the husky install, make the jscpd
gate analyse real files, guard the package manager declaration, turn on
command-stream errexit, gate staged formatting before release commits, add
release-preflight credential checks, and sweep zizmor/actionlint/persisted
credentials/link-recheck fixes across the workflows.
