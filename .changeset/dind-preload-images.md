---
bump: minor
---

dind-box: stop the nested daemon from re-downloading images the host already has
(issue #94). Two complementary paths, both seeding the inner daemon once it is
ready and skipping any image already present:

- **Explicit preload:** `DIND_PRELOAD_TARBALL` loads `docker save` tarballs (or
  directories of `*.tar`) into the inner daemon, and `DIND_PRELOAD_IMAGES` pulls
  registry/mirror references.
- **Host-image passthrough (on by default):** when the host Docker socket is
  mounted at `DIND_HOST_DOCKER_SOCK` (default `/var/run/host-docker.sock`, a
  non-default path so the inner daemon stays isolated), host images are copied
  into the nested daemon at startup. `DIND_HOST_PASSTHROUGH=public` (default)
  passes only images re-pullable from an allowlisted public registry — safe from
  local secrets and private credentials — while `all` passes everything and
  `off` disables it. A quiet no-op when no host socket is mounted.

Covered by `tests/dind/example-preload-images.sh` and
`experiments/preload-unit-test.sh`, documented in `docs/dind/USAGE.md`.
