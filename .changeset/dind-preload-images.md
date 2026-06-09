---
bump: minor
---

dind-box: add a documented startup preload hook so the nested daemon no longer
re-downloads images the host already has (issue #94). `DIND_PRELOAD_TARBALL`
loads `docker save` tarballs (or directories of `*.tar`) into the inner daemon
once it is ready, and `DIND_PRELOAD_IMAGES` pulls registry/mirror references,
skipping any image that is already present. Covered by
`tests/dind/example-preload-images.sh` and documented in `docs/dind/USAGE.md`.
