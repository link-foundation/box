---
bump: patch
---

dind-box: close a false-positive coverage gap in the host-image passthrough test (issue #96). `tests/dind/example-preload-images.sh` previously only asserted that `public` mode skips a locally-built fixture (no RepoDigest); it never asserted the positive path — that a genuinely public image (carrying a RepoDigest from an allowlisted registry) IS copied into the inner daemon. The throwaway host daemon is now also seeded with a real pulled `alpine:3.20`, and the `public`-mode block asserts that image lands in the nested daemon and is logged as loaded. A "public copies nothing" regression — the exact symptom downstream (`link-assistant/hive-mind#1879`) relies on not happening — now fails CI instead of shipping green.
