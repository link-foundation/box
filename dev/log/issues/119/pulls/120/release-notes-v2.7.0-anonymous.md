<!-- scripts/release/build-release-notes.sh run on this branch against the released v2.7.0,
     anonymously and with no docker login. Recorded 2026-09-08T17:28:02Z. Reproduce with:
       VERIFY_IMAGES=1 VERSION=2.7.0 REPO=link-foundation/box \
         GHCR_IMAGE=ghcr.io/link-foundation/box DOCKERHUB_IMAGE=konard/box \
         bash scripts/release/build-release-notes.sh -->


## Image publication

Checked **anonymously**, the way a reader of these notes pulls them: 29 of 56 image references can be pulled without credentials.

| Registry | Pullable | Checked |
|----------|----------|--------|
| GitHub Container Registry (registry of record) | 28 | 28 |
| Docker Hub (mirror) | 1 | 28 |

These references are **not published**; the tables below list them for completeness, not as something you can pull today:

- `konard/box-essentials:2.7.0`
- `konard/box-js:2.7.0`
- `konard/box-python:2.7.0`
- `konard/box-go:2.7.0`
- `konard/box-rust:2.7.0`
- `konard/box-java:2.7.0`
- `konard/box-kotlin:2.7.0`
- `konard/box-ruby:2.7.0`
- `konard/box-php:2.7.0`
- `konard/box-perl:2.7.0`
- `konard/box-swift:2.7.0`
- `konard/box-lean:2.7.0`
- `konard/box-rocq:2.7.0`
- `konard/box-dind:2.7.0`
- `konard/box-essentials-dind:2.7.0`
- `konard/box-js-dind:2.7.0`
- `konard/box-python-dind:2.7.0`
- `konard/box-go-dind:2.7.0`
- `konard/box-rust-dind:2.7.0`
- `konard/box-java-dind:2.7.0`
- `konard/box-kotlin-dind:2.7.0`
- `konard/box-ruby-dind:2.7.0`
- `konard/box-php-dind:2.7.0`
- `konard/box-perl-dind:2.7.0`
- `konard/box-swift-dind:2.7.0`
- `konard/box-lean-dind:2.7.0`
- `konard/box-rocq-dind:2.7.0`

These **resolve, and serve fewer architectures than this release built**. Pulling one on a platform it does not carry fails with `no matching manifest`, which is why a reference that resolves is not by itself evidence that it was published correctly (issue #119):

- `konard/box:2.7.0` carries linux/amd64, missing linux/arm64

Re-run the release workflow to publish the missing references. The GitHub Release is deliberately not blocked on an image push (issue #115), and a run that ends with nothing published fails on its own publication check rather than by withholding these notes (issue #117).

## Docker Images

The **Tag** column is the reference that selects a platform for you, followed by the architectures it was measured to serve when these notes were generated. A per-architecture tag is linked only where the reference it belongs to could be read.

### Docker Hub - Combo Boxes

| Image | Tag | AMD64 | ARM64 |
|-------|-----|-------|-------|
| Full Box | [`konard/box:2.7.0`](https://hub.docker.com/r/konard/box/tags?name=2.7.0) - **linux/amd64 only**, missing linux/arm64 | [`2.7.0-amd64`](https://hub.docker.com/r/konard/box/tags?name=2.7.0-amd64) | `2.7.0-arm64` |
| Essentials | `konard/box-essentials:2.7.0` - **not published** | `2.7.0-amd64` | `2.7.0-arm64` |
| JS | `konard/box-js:2.7.0` - **not published** | `2.7.0-amd64` | `2.7.0-arm64` |

### Docker Hub - Language Boxes

| Language | Tag | AMD64 | ARM64 |
|-------|-----|-------|-------|
| Python | `konard/box-python:2.7.0` - **not published** | `2.7.0-amd64` | `2.7.0-arm64` |
| Go | `konard/box-go:2.7.0` - **not published** | `2.7.0-amd64` | `2.7.0-arm64` |
| Rust | `konard/box-rust:2.7.0` - **not published** | `2.7.0-amd64` | `2.7.0-arm64` |
| Java | `konard/box-java:2.7.0` - **not published** | `2.7.0-amd64` | `2.7.0-arm64` |
| Kotlin | `konard/box-kotlin:2.7.0` - **not published** | `2.7.0-amd64` | `2.7.0-arm64` |
| Ruby | `konard/box-ruby:2.7.0` - **not published** | `2.7.0-amd64` | `2.7.0-arm64` |
| PHP | `konard/box-php:2.7.0` - **not published** | `2.7.0-amd64` | `2.7.0-arm64` |
| Perl | `konard/box-perl:2.7.0` - **not published** | `2.7.0-amd64` | `2.7.0-arm64` |
| Swift | `konard/box-swift:2.7.0` - **not published** | `2.7.0-amd64` | `2.7.0-arm64` |
| Lean | `konard/box-lean:2.7.0` - **not published** | `2.7.0-amd64` | `2.7.0-arm64` |
| Rocq | `konard/box-rocq:2.7.0` - **not published** | `2.7.0-amd64` | `2.7.0-arm64` |

### GitHub Container Registry - Combo Boxes

| Image | Tag | AMD64 | ARM64 |
|-------|-----|-------|-------|
| Full Box | `ghcr.io/link-foundation/box:2.7.0` - linux/amd64, linux/arm64 | `ghcr.io/link-foundation/box:2.7.0-amd64` | `ghcr.io/link-foundation/box:2.7.0-arm64` |
| Essentials | `ghcr.io/link-foundation/box-essentials:2.7.0` - linux/amd64, linux/arm64 | `ghcr.io/link-foundation/box-essentials:2.7.0-amd64` | `ghcr.io/link-foundation/box-essentials:2.7.0-arm64` |
| JS | `ghcr.io/link-foundation/box-js:2.7.0` - linux/amd64, linux/arm64 | `ghcr.io/link-foundation/box-js:2.7.0-amd64` | `ghcr.io/link-foundation/box-js:2.7.0-arm64` |

### GitHub Container Registry - Language Boxes

| Language | Tag | AMD64 | ARM64 |
|-------|-----|-------|-------|
| Python | `ghcr.io/link-foundation/box-python:2.7.0` - linux/amd64, linux/arm64 | `ghcr.io/link-foundation/box-python:2.7.0-amd64` | `ghcr.io/link-foundation/box-python:2.7.0-arm64` |
| Go | `ghcr.io/link-foundation/box-go:2.7.0` - linux/amd64, linux/arm64 | `ghcr.io/link-foundation/box-go:2.7.0-amd64` | `ghcr.io/link-foundation/box-go:2.7.0-arm64` |
| Rust | `ghcr.io/link-foundation/box-rust:2.7.0` - linux/amd64, linux/arm64 | `ghcr.io/link-foundation/box-rust:2.7.0-amd64` | `ghcr.io/link-foundation/box-rust:2.7.0-arm64` |
| Java | `ghcr.io/link-foundation/box-java:2.7.0` - linux/amd64, linux/arm64 | `ghcr.io/link-foundation/box-java:2.7.0-amd64` | `ghcr.io/link-foundation/box-java:2.7.0-arm64` |
| Kotlin | `ghcr.io/link-foundation/box-kotlin:2.7.0` - linux/amd64, linux/arm64 | `ghcr.io/link-foundation/box-kotlin:2.7.0-amd64` | `ghcr.io/link-foundation/box-kotlin:2.7.0-arm64` |
| Ruby | `ghcr.io/link-foundation/box-ruby:2.7.0` - linux/amd64, linux/arm64 | `ghcr.io/link-foundation/box-ruby:2.7.0-amd64` | `ghcr.io/link-foundation/box-ruby:2.7.0-arm64` |
| PHP | `ghcr.io/link-foundation/box-php:2.7.0` - linux/amd64, linux/arm64 | `ghcr.io/link-foundation/box-php:2.7.0-amd64` | `ghcr.io/link-foundation/box-php:2.7.0-arm64` |
| Perl | `ghcr.io/link-foundation/box-perl:2.7.0` - linux/amd64, linux/arm64 | `ghcr.io/link-foundation/box-perl:2.7.0-amd64` | `ghcr.io/link-foundation/box-perl:2.7.0-arm64` |
| Swift | `ghcr.io/link-foundation/box-swift:2.7.0` - linux/amd64, linux/arm64 | `ghcr.io/link-foundation/box-swift:2.7.0-amd64` | `ghcr.io/link-foundation/box-swift:2.7.0-arm64` |
| Lean | `ghcr.io/link-foundation/box-lean:2.7.0` - linux/amd64, linux/arm64 | `ghcr.io/link-foundation/box-lean:2.7.0-amd64` | `ghcr.io/link-foundation/box-lean:2.7.0-arm64` |
| Rocq | `ghcr.io/link-foundation/box-rocq:2.7.0` - linux/amd64, linux/arm64 | `ghcr.io/link-foundation/box-rocq:2.7.0-amd64` | `ghcr.io/link-foundation/box-rocq:2.7.0-arm64` |

### Docker Hub - dind-box (Docker-in-Docker variants, issue #80)

Each variant runs an inner Docker daemon. Run with `docker run --privileged` (default) or `docker run --runtime=sysbox-runc` (recommended for shared hosts). `docker ps -a` inside the container only lists containers created by that container - see [docs/case-studies/issue-80](https://github.com/link-foundation/box/blob/v2.7.0/docs/case-studies/issue-80/CASE-STUDY.md).

| Image | Tag | AMD64 | ARM64 |
|-------|-----|-------|-------|
| Full Box + dind | `konard/box-dind:2.7.0` - **not published** | `2.7.0-amd64` | `2.7.0-arm64` |
| Essentials + dind | `konard/box-essentials-dind:2.7.0` - **not published** | `2.7.0-amd64` | `2.7.0-arm64` |
| JS + dind | `konard/box-js-dind:2.7.0` - **not published** | `2.7.0-amd64` | `2.7.0-arm64` |
| Python + dind | `konard/box-python-dind:2.7.0` - **not published** | `2.7.0-amd64` | `2.7.0-arm64` |
| Go + dind | `konard/box-go-dind:2.7.0` - **not published** | `2.7.0-amd64` | `2.7.0-arm64` |
| Rust + dind | `konard/box-rust-dind:2.7.0` - **not published** | `2.7.0-amd64` | `2.7.0-arm64` |
| Java + dind | `konard/box-java-dind:2.7.0` - **not published** | `2.7.0-amd64` | `2.7.0-arm64` |
| Kotlin + dind | `konard/box-kotlin-dind:2.7.0` - **not published** | `2.7.0-amd64` | `2.7.0-arm64` |
| Ruby + dind | `konard/box-ruby-dind:2.7.0` - **not published** | `2.7.0-amd64` | `2.7.0-arm64` |
| PHP + dind | `konard/box-php-dind:2.7.0` - **not published** | `2.7.0-amd64` | `2.7.0-arm64` |
| Perl + dind | `konard/box-perl-dind:2.7.0` - **not published** | `2.7.0-amd64` | `2.7.0-arm64` |
| Swift + dind | `konard/box-swift-dind:2.7.0` - **not published** | `2.7.0-amd64` | `2.7.0-arm64` |
| Lean + dind | `konard/box-lean-dind:2.7.0` - **not published** | `2.7.0-amd64` | `2.7.0-arm64` |
| Rocq + dind | `konard/box-rocq-dind:2.7.0` - **not published** | `2.7.0-amd64` | `2.7.0-arm64` |

### GitHub Container Registry - dind-box (Docker-in-Docker variants, issue #80)

| Image | Tag | AMD64 | ARM64 |
|-------|-----|-------|-------|
| Full Box + dind | `ghcr.io/link-foundation/box-dind:2.7.0` - linux/amd64, linux/arm64 | `ghcr.io/link-foundation/box-dind:2.7.0-amd64` | `ghcr.io/link-foundation/box-dind:2.7.0-arm64` |
| Essentials + dind | `ghcr.io/link-foundation/box-essentials-dind:2.7.0` - linux/amd64, linux/arm64 | `ghcr.io/link-foundation/box-essentials-dind:2.7.0-amd64` | `ghcr.io/link-foundation/box-essentials-dind:2.7.0-arm64` |
| JS + dind | `ghcr.io/link-foundation/box-js-dind:2.7.0` - linux/amd64, linux/arm64 | `ghcr.io/link-foundation/box-js-dind:2.7.0-amd64` | `ghcr.io/link-foundation/box-js-dind:2.7.0-arm64` |
| Python + dind | `ghcr.io/link-foundation/box-python-dind:2.7.0` - linux/amd64, linux/arm64 | `ghcr.io/link-foundation/box-python-dind:2.7.0-amd64` | `ghcr.io/link-foundation/box-python-dind:2.7.0-arm64` |
| Go + dind | `ghcr.io/link-foundation/box-go-dind:2.7.0` - linux/amd64, linux/arm64 | `ghcr.io/link-foundation/box-go-dind:2.7.0-amd64` | `ghcr.io/link-foundation/box-go-dind:2.7.0-arm64` |
| Rust + dind | `ghcr.io/link-foundation/box-rust-dind:2.7.0` - linux/amd64, linux/arm64 | `ghcr.io/link-foundation/box-rust-dind:2.7.0-amd64` | `ghcr.io/link-foundation/box-rust-dind:2.7.0-arm64` |
| Java + dind | `ghcr.io/link-foundation/box-java-dind:2.7.0` - linux/amd64, linux/arm64 | `ghcr.io/link-foundation/box-java-dind:2.7.0-amd64` | `ghcr.io/link-foundation/box-java-dind:2.7.0-arm64` |
| Kotlin + dind | `ghcr.io/link-foundation/box-kotlin-dind:2.7.0` - linux/amd64, linux/arm64 | `ghcr.io/link-foundation/box-kotlin-dind:2.7.0-amd64` | `ghcr.io/link-foundation/box-kotlin-dind:2.7.0-arm64` |
| Ruby + dind | `ghcr.io/link-foundation/box-ruby-dind:2.7.0` - linux/amd64, linux/arm64 | `ghcr.io/link-foundation/box-ruby-dind:2.7.0-amd64` | `ghcr.io/link-foundation/box-ruby-dind:2.7.0-arm64` |
| PHP + dind | `ghcr.io/link-foundation/box-php-dind:2.7.0` - linux/amd64, linux/arm64 | `ghcr.io/link-foundation/box-php-dind:2.7.0-amd64` | `ghcr.io/link-foundation/box-php-dind:2.7.0-arm64` |
| Perl + dind | `ghcr.io/link-foundation/box-perl-dind:2.7.0` - linux/amd64, linux/arm64 | `ghcr.io/link-foundation/box-perl-dind:2.7.0-amd64` | `ghcr.io/link-foundation/box-perl-dind:2.7.0-arm64` |
| Swift + dind | `ghcr.io/link-foundation/box-swift-dind:2.7.0` - linux/amd64, linux/arm64 | `ghcr.io/link-foundation/box-swift-dind:2.7.0-amd64` | `ghcr.io/link-foundation/box-swift-dind:2.7.0-arm64` |
| Lean + dind | `ghcr.io/link-foundation/box-lean-dind:2.7.0` - linux/amd64, linux/arm64 | `ghcr.io/link-foundation/box-lean-dind:2.7.0-amd64` | `ghcr.io/link-foundation/box-lean-dind:2.7.0-arm64` |
| Rocq + dind | `ghcr.io/link-foundation/box-rocq-dind:2.7.0` - linux/amd64, linux/arm64 | `ghcr.io/link-foundation/box-rocq-dind:2.7.0-amd64` | `ghcr.io/link-foundation/box-rocq-dind:2.7.0-arm64` |

## Architecture

```
JS box (konard/box-js)
  → Essentials box (konard/box-essentials)
    ├─ box-python  ├─ box-go    ├─ box-rust
    ├─ box-java    ├─ box-kotlin ├─ box-ruby
    ├─ box-php     ├─ box-perl   ├─ box-swift
    ├─ box-lean    └─ box-rocq
    → Full box (konard/box) [merges all language images]
```

## Quick Start

GitHub Container Registry is the registry of record: it is written with the
run's own GITHUB_TOKEN, which cannot expire (issue #115, RC-3). Docker Hub is a
mirror of it, and the publication section above says which of the two actually
carries this version.

Pull multi-arch (auto-selects your platform):
```sh
docker pull ghcr.io/link-foundation/box:2.7.0
```

Pull specific architecture:
```sh
# AMD64
docker pull ghcr.io/link-foundation/box:2.7.0-amd64

# ARM64 (Apple Silicon, Raspberry Pi, etc.)
docker pull ghcr.io/link-foundation/box:2.7.0-arm64
```

Pull from the Docker Hub mirror:
```sh
docker pull konard/box:2.7.0
```

## Links
- [Docker Hub](https://hub.docker.com/r/konard/box)
- [GHCR packages](https://github.com/orgs/link-foundation/packages?repo_name=box)

Released on 2026-09-08
