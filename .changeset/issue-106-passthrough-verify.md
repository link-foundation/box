---
bump: patch
---

dind-box: verify host-image passthrough actually seeded the nested daemon, and stop falsely reporting success when it did not (issue #106).

box-dind kept re-downloading multi-GB host images (~30 GB, ~1 hour) on first nested `docker run` even with `DIND_HOST_PASSTHROUGH_IMAGES` set, while the entrypoint still printed `image preload/passthrough complete` — so a misconfigured deployment (forgotten `-v /var/run/docker.sock:…:ro` mount, host missing that exact ref, or the `mode=public` filter dropping a locally-built/private image) looked healthy right up until the slow re-pull. This is the recurring symptom behind closed issues #94 and #102.

The entrypoint now verifies the copy after passthrough: for every **concrete** allowlist entry (explicit tag or `@sha256:` digest — bare repos and globs are skipped to avoid false alarms) it runs `docker image inspect` against the nested daemon. If an expected image is absent it emits a loud, actionable warning (whether the host socket is reachable but lacks the ref / was filtered by the mode, or no usable socket is mounted) and the completion line becomes `image preload/passthrough finished WITH WARNINGS` instead of the misleading `complete`. No silent no-op path can report success anymore. Re-pull still happens naturally — we do not auto-pull, which would mask the config error and incur the same multi-GB download.

Covered by new cases in `experiments/preload-unit-test.sh` and new `verify_ok`/`verify_miss` assertions in the CI-run `tests/dind/example-preload-images.sh`; deployment wiring and verification behavior documented in `docs/dind/USAGE.md` and `README.md`.
