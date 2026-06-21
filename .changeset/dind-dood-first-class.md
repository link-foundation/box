---
bump: minor
---

dind-box: fully support and document both Docker-in-Docker (DinD) and Docker-outside-of-Docker (DooD) workflows from the **same image**, chosen entirely by run flags (issue #110).

- **DooD is now a first-class, documented mode.** Run with `-e DIND_SKIP_DAEMON=1 -v /var/run/docker.sock:/var/run/docker.sock --group-add "$(stat -c '%g' /var/run/docker.sock)"` and the in-container CLI talks to the host daemon directly — zero image copy, zero extra disk (the only zero-copy reuse path; DinD passthrough is a deliberate `save|load` copy). The entrypoint announces the active mode in its logs.
- **Host-socket group access is handled automatically (finding #1).** When the box user is not a member of the mounted socket's owning GID, the entrypoint no longer logs a vague WARN and continues — it prints the **exact** `--group-add <gid>` to re-run with. Crucially, it **never `chgrp`s the shared host socket** even on a writable mount: doing so mutated `/var/run/docker.sock`'s group and locked other host users out of Docker (caught and fixed during end-to-end verification). The private DinD inner socket is still adopted into the image `docker` group as before.
- **Passthrough/preload readiness is observable (finding #2).** Seeding already runs synchronously before workload handoff; the entrypoint now also writes `DIND_READY_FILE` (default `/tmp/box-dind-ready`) with `complete` or `warnings` so a host can block on real cache readiness instead of racing `docker info`. An inaccessible passthrough socket yields an honest `WITH WARNINGS` marker instead of a false `complete`.
- **Docs (finding #3/#4).** `docs/dind/USAGE.md` gains a DinD-vs-DooD comparison table, a Docker-outside-of-Docker section (recipe, `--group-add` requirement, isolation trade-off), and a readiness-signal section; the README security model reframes the socket guidance to distinguish isolated DinD (don't mount the runtime socket) from the supported DooD opt-in.

Covered by `experiments/preload-unit-test.sh` (85 assertions, incl. the host-socket safety regression guard) and the new CI-run `tests/dind/example-dood-host-socket.sh`. Full rationale in `docs/case-studies/issue-110/`.
