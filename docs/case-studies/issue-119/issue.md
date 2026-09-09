# Issue #119: Docker Hub mirror of 2.7.0 is broken: `konard/box:2.7.0`/`:latest` are amd64-only (a `latest` regression), `konard/box-dind:2.7.0` is missing — `docker manifest create` cannot consume the indexes `imagetools create` wrote

> Source: https://github.com/link-foundation/box/issues/119
> Opened: 2026-09-07T20:47:38Z

---

## Summary

2.7.0 **delivers the #112 fix and it is pullable** — on GHCR. Both `ghcr.io/link-foundation/box:2.7.0` and `ghcr.io/link-foundation/box-dind:2.7.0` are public, multi-arch, and contain exactly one runtime per language. Thank you; that unblocks link-assistant/hive-mind#2187, which is now moving its base pins to those GHCR references.

What is still wrong is the **Docker Hub mirror**, and it is wrong in a way the release cannot currently detect:

1. `konard/box:2.7.0` and `konard/box:latest` exist but carry **linux/amd64 only** — the multi-arch manifest step failed and the amd64 mirror had already written the unsuffixed tags.
2. `konard/box:latest` is therefore a **regression**: it was multi-arch at 2.4.0 and is single-arch now.
3. `konard/box-dind:2.7.0` **does not exist at all**; `konard/box-dind:latest` still serves the 2026-06-21 pre-#112 image.
4. The release notes' "Docker Hub — Combo Boxes" table advertises `konard/box:2.7.0` under a **Multi-arch** column, which is not true of that tag.

An arm64 consumer that follows the README or the release notes to Docker Hub gets `no matching manifest for linux/arm64`, or a June image.

## Evidence

Anonymous registry API, 2026-09-07:

| Reference | Registry API result |
|---|---|
| `ghcr.io/link-foundation/box:2.7.0` | OCI index → **linux/amd64, linux/arm64** |
| `ghcr.io/link-foundation/box-dind:2.7.0` | OCI index → **linux/amd64, linux/arm64** |
| `ghcr.io/link-foundation/box:latest` | OCI index → linux/amd64, linux/arm64 |
| `docker.io/konard/box:2.7.0` | OCI index → **linux/amd64 only** |
| `docker.io/konard/box:latest` | OCI index → **linux/amd64 only** |
| `docker.io/konard/box:2.4.0` | Docker manifest list → linux/amd64, linux/arm64 (the older tag is still the correct one) |
| `docker.io/konard/box-dind:2.7.0` | **`MANIFEST_UNKNOWN`** |
| `docker.io/konard/box-dind:latest` | manifest list, amd64+arm64, config `created: 2026-06-21T18:10:52Z` (pre-#112) |

Docker Hub tag listing (`hub.docker.com/v2/repositories/.../tags`):

```
konard/box            latest, 2.7.0, 20260907, fd4742b   2026-09-07T09:01:5x   <- written by the AMD64 job
                      latest-amd64 … fd4742b-amd64       2026-09-07T09:01:5x
                      latest-arm64 … fd4742b-arm64       2026-09-07T09:30:3x
konard/box-dind       2.7.0-amd64, latest-amd64          2026-09-07T09:56:1x
                      2.7.0-arm64, latest-arm64          2026-09-07T09:43:3x
                      2.7.0                              (absent)
                      latest, 2.4.0                      2026-06-21T18:17
```

## Root cause

Two independent defects compose.

### (a) `docker manifest create` cannot consume what `docker buildx imagetools create` wrote

`scripts/release/mirror-to-dockerhub.sh` mirrors with `docker buildx imagetools create`, which **always wraps the result in an OCI index**, even for one platform. `scripts/release/create-multiarch-manifest.sh` then calls `docker manifest create`, which refuses index sources. From release run [`34056619231`](https://github.com/link-foundation/box/actions/runs/34056619231):

```
2026-09-07T09:31:40.5957464Z docker.io/***/box:2.7.0-amd64 is a manifest list
2026-09-07T09:31:40.5979053Z ==> ***/box:2.7.0: attempt 1 failed; retrying in 10s
… attempt 2 … attempt 3 …
2026-09-07T09:32:11.3832229Z ##[warning]Could not publish multi-arch manifest(s): ***/box:latest ***/box:2.7.0.
  The per-architecture tags were pushed and remain pullable by their -amd64/-arm64 suffix; only the
  combined manifest list is missing.
```

Identical failure for `box-dind` at `09:57:40`. Retrying is futile — the input is deterministically the wrong media type — so three attempts just cost 40 s before the same warning.

The asymmetry is visible directly in the registries, and confirms the rewrap is the mirror's doing rather than the builder's:

```
ghcr.io/link-foundation/box-dind:2.7.0-amd64   application/vnd.oci.image.manifest.v1+json   (plain manifest)
docker.io/konard/box-dind:2.7.0-amd64          application/vnd.oci.image.index.v1+json      (index)
```

Suggested fix: skip the assemble-from-suffixed-tags step for Docker Hub entirely and mirror the **already-correct GHCR index**, i.e. `docker buildx imagetools create --tag docker.io/<ns>/box:2.7.0 ghcr.io/link-foundation/box:2.7.0` once the GHCR manifest list exists. `imagetools create` copies an index as an index; it is the same tool already in the pipeline, and it removes the per-arch reassembly on Docker Hub altogether. Failing that, `docker manifest create --amend` / `buildx imagetools create` on the suffixed tags instead of `docker manifest create`.

### (b) The amd64 job writes the unsuffixed Docker Hub tags

`box`'s amd64 mirror pushes **8** tags — the 4 suffixed *and* the 4 unsuffixed:

```
2026-09-07T09:01:52Z pushing … to docker.io/***/box:latest
2026-09-07T09:01:53Z pushing … to docker.io/***/box:2.7.0
2026-09-07T09:01:54Z pushing … to docker.io/***/box:20260907
2026-09-07T09:01:56Z pushing … to docker.io/***/box:fd4742b
2026-09-07T09:01:57Z pushing … to docker.io/***/box:latest-amd64
…
2026-09-07T09:02:02Z ==> Mirrored ghcr.io/link-foundation/box:2.7.0-amd64 to 8 Docker Hub tag(s)
```

So even when (a) is fixed, there is a window in which `konard/box:latest` is amd64-only; and when (a) fails, that is the *end state*. `box-dind`'s mirror pushes only the suffixed tags (hence `konard/box-dind:2.7.0` simply missing rather than half-right) — the two families disagree about which tags an arch-specific job may claim. Only the manifest step should ever write an unsuffixed tag.

### (c) Nothing fails the release over it

`create-multiarch-manifest` runs with `MANIFEST_REQUIRED: 0` for Docker Hub (log line `09:31:09.0456267Z   MANIFEST_REQUIRED: 0`), so the exhausted retries produce a `::warning` and the run stays green. `check-publication.sh` (added in #117) then reports "Docker Hub (mirror): 1 pullable of 28" in the notes — and the release still ships. That is honest, and much better than 2.6.0, but it means the *only* signal that the mirror is broken is a line in the notes that says a number is low.

Two things would have caught this at the level it deserves:
- assert **platform coverage**, not just resolvability — a tag that resolves to `linux/amd64` alone where the release built two architectures is a failed publication, not a successful one;
- treat "a tag that was multi-arch in the previous release is single-arch now" (`konard/box:latest`) as a regression that fails the run.

## Also: the notes' Docker Hub table overstates what exists

The v2.7.0 notes correctly list the 27 unpublished Docker Hub references — including `konard/box-dind:2.7.0` — under "these references are **not published**". But the "Docker Hub — Combo Boxes" table below still renders `konard/box:2.7.0` in a column headed **Multi-arch**, and links `2.7.0-arm64` for every image, including the ones just declared unpublished. The Multi-arch column should reflect the probe's actual answer (published-multi-arch / published-single-arch / missing) rather than being a static heading.

## Impact on the downstream

link-assistant/hive-mind#2187 builds `linux/amd64` on `ubuntu-latest` and `linux/arm64` natively on `ubuntu-24.04-arm`, so an amd64-only base is unusable for half the matrix. It is pinning to `ghcr.io/link-foundation/box:2.7.0` / `ghcr.io/link-foundation/box-dind:2.7.0` — the registry of record, which is correct today. This issue is only about Docker Hub still being wrong for anyone who follows the README or the notes there.

Verified contents of the GHCR 2.7.0 images, for the record (pulled and run anonymously):

```
box 2.7.0        node v24.20.0 (1 version)   bun 1.4.2   rustup: stable-x86_64-unknown-linux-gnu only (rustc 1.98.1)
                 pyenv 3.14.7 (1)            java 25-tem (1)   kotlin 2.4.10 (1)
box-dind 2.7.0   same, plus Docker 29.8.0 and /usr/bin/fuse-overlayfs
```

