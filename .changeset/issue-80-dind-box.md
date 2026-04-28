---
bump: minor
---

Add `dind-box` family: Docker-in-Docker variant for every existing box image (issue #80).

Each base image now has a sibling `<image>-dind` that ships the Docker Engine, CLI, containerd, Buildx, and Compose v2 plus an entrypoint that starts the inner `dockerd` and drops to the `box` user:

- `konard/box` → `konard/box-dind`
- `konard/box-essentials` → `konard/box-essentials-dind`
- `konard/box-js` → `konard/box-js-dind`
- `konard/box-<language>-dind` for every language box (python, go, rust, java, kotlin, ruby, php, perl, swift, lean, rocq)

All variants are multi-arch (linux/amd64 + linux/arm64) on Docker Hub and ghcr.io.

Recommended invocation: `docker run --runtime=sysbox-runc konard/box-dind` (Sysbox, no `--privileged` needed). Default fallback: `docker run --privileged konard/box-dind`. Each running dind-box has its own inner Docker daemon, so `docker ps -a` from inside the container only lists containers created by that container — the host-safety stretch goal in issue #80.

See `docs/case-studies/issue-80/CASE-STUDY.md` for the full design and threat model.
