---
bump: patch
---

dind-box: warn when host-image passthrough is opted into but no host socket is
mounted (issue #102).

Running `box-dind` with passthrough enabled (the default `public` mode) **and**
an explicit allowlist (`DIND_HOST_PASSTHROUGH_IMAGES=...`) but **without** the
host Docker socket bind-mounted used to be a silent no-op: the entrypoint copied
nothing, printed nothing, and the first nested `docker run` re-pulled the full
image from the registry with no hint why. Downstream this re-pulled a 30+ GB
image because of a forgotten `-v` flag (`link-assistant/hive-mind#1914`).

A non-empty `DIND_HOST_PASSTHROUGH_IMAGES` is an unambiguous opt-in signal, so
`passthrough_host_images` now emits a single actionable warning in exactly that
case — enabled passthrough + allowlist set + no socket mounted — naming the
missing `-v /var/run/docker.sock:${DIND_HOST_DOCKER_SOCK}:ro` mount. The
present-but-unreachable socket already warned and still does; plain `box-dind`
containers that never set an allowlist stay silent so the default mode is not
spammed. Covered by new cases in `experiments/preload-unit-test.sh` and
documented in `docs/dind/USAGE.md`.
