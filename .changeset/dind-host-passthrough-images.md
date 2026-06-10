---
bump: minor
---

dind-box: add `DIND_HOST_PASSTHROUGH_IMAGES`, a per-repository (image-name) allowlist for host-image passthrough (issue #97). When non-empty, only host images whose reference matches at least one space-separated pattern (glob) are passed through, composed with the existing mode gate (so `public` still requires a public RepoDigest). Empty/unset preserves the current mode + registry behavior. Patterns match against several normalized forms of each reference, so `konard/hive-mind` matches `konard/hive-mind:latest` and `docker.io/konard/hive-mind:latest` alike. This is one level finer than `DIND_HOST_PASSTHROUGH_REGISTRIES` — it scopes passthrough to specific repositories / image names so a deployment can seed the inner daemon with only the images it owns rather than every public image on the host. Covered by new cases in `experiments/preload-unit-test.sh` and `tests/dind/example-preload-images.sh`, documented in `docs/dind/USAGE.md` and `README.md`.
