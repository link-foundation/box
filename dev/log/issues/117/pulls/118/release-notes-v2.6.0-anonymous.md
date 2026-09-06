
## Image publication

Checked **anonymously**, the way a reader of these notes pulls them: 0 of 56 image references can be pulled without credentials.

| Registry | Pullable | Checked |
|----------|----------|--------|
| GitHub Container Registry (registry of record) | 0 | 28 |
| Docker Hub (mirror) | 0 | 28 |

> **Nothing in this release can be pulled from the registry of record.** The tables below list what the build was supposed to publish, not what you can run today. See the run that produced this release.

These references are **not published**; the tables below list them for completeness, not as something you can pull today:

- `konard/box:2.6.0`
- `konard/box-essentials:2.6.0`
- `konard/box-js:2.6.0`
- `konard/box-python:2.6.0`
- `konard/box-go:2.6.0`
- `konard/box-rust:2.6.0`
- `konard/box-java:2.6.0`
- `konard/box-kotlin:2.6.0`
- `konard/box-ruby:2.6.0`
- `konard/box-php:2.6.0`
- `konard/box-perl:2.6.0`
- `konard/box-swift:2.6.0`
- `konard/box-lean:2.6.0`
- `konard/box-rocq:2.6.0`
- `konard/box-dind:2.6.0`
- `konard/box-essentials-dind:2.6.0`
- `konard/box-js-dind:2.6.0`
- `konard/box-python-dind:2.6.0`
- `konard/box-go-dind:2.6.0`
- `konard/box-rust-dind:2.6.0`
- `konard/box-java-dind:2.6.0`
- `konard/box-kotlin-dind:2.6.0`
- `konard/box-ruby-dind:2.6.0`
- `konard/box-php-dind:2.6.0`
- `konard/box-perl-dind:2.6.0`
- `konard/box-swift-dind:2.6.0`
- `konard/box-lean-dind:2.6.0`
- `konard/box-rocq-dind:2.6.0`

These exist but are **not readable anonymously** - the package is private, so publishing to it reaches nobody:

- `ghcr.io/link-foundation/box:2.6.0`
- `ghcr.io/link-foundation/box-essentials:2.6.0`
- `ghcr.io/link-foundation/box-js:2.6.0`
- `ghcr.io/link-foundation/box-python:2.6.0`
- `ghcr.io/link-foundation/box-go:2.6.0`
- `ghcr.io/link-foundation/box-rust:2.6.0`
- `ghcr.io/link-foundation/box-java:2.6.0`
- `ghcr.io/link-foundation/box-kotlin:2.6.0`
- `ghcr.io/link-foundation/box-ruby:2.6.0`
- `ghcr.io/link-foundation/box-php:2.6.0`
- `ghcr.io/link-foundation/box-perl:2.6.0`
- `ghcr.io/link-foundation/box-swift:2.6.0`
- `ghcr.io/link-foundation/box-lean:2.6.0`
- `ghcr.io/link-foundation/box-rocq:2.6.0`
- `ghcr.io/link-foundation/box-dind:2.6.0`
- `ghcr.io/link-foundation/box-essentials-dind:2.6.0`
- `ghcr.io/link-foundation/box-js-dind:2.6.0`
- `ghcr.io/link-foundation/box-python-dind:2.6.0`
- `ghcr.io/link-foundation/box-go-dind:2.6.0`
- `ghcr.io/link-foundation/box-rust-dind:2.6.0`
- `ghcr.io/link-foundation/box-java-dind:2.6.0`
- `ghcr.io/link-foundation/box-kotlin-dind:2.6.0`
- `ghcr.io/link-foundation/box-ruby-dind:2.6.0`
- `ghcr.io/link-foundation/box-php-dind:2.6.0`
- `ghcr.io/link-foundation/box-perl-dind:2.6.0`
- `ghcr.io/link-foundation/box-swift-dind:2.6.0`
- `ghcr.io/link-foundation/box-lean-dind:2.6.0`
- `ghcr.io/link-foundation/box-rocq-dind:2.6.0`

Re-run the release workflow to publish the missing references. The GitHub Release is deliberately not blocked on an image push (issue #115), and a run that ends with nothing published fails on its own publication check rather than by withholding these notes (issue #117).

## Docker Images

### Docker Hub - Combo Boxes

| Image | Multi-arch | AMD64 | ARM64 |
|-------|------------|-------|-------|
| Full Box | [`konard/box:2.6.0`](https://hub.docker.com/r/konard/box/tags?name=2.6.0) | [`2.6.0-amd64`](https://hub.docker.com/r/konard/box/tags?name=2.6.0-amd64) | [`2.6.0-arm64`](https://hub.docker.com/r/konard/box/tags?name=2.6.0-arm64) |
| Essentials | [`konard/box-essentials:2.6.0`](https://hub.docker.com/r/konard/box-essentials/tags?name=2.6.0) | [`2.6.0-amd64`](https://hub.docker.com/r/konard/box-essentials/tags?name=2.6.0-amd64) | [`2.6.0-arm64`](https://hub.docker.com/r/konard/box-essentials/tags?name=2.6.0-arm64) |
| JS | [`konard/box-js:2.6.0`](https://hub.docker.com/r/konard/box-js/tags?name=2.6.0) | [`2.6.0-amd64`](https://hub.docker.com/r/konard/box-js/tags?name=2.6.0-amd64) | [`2.6.0-arm64`](https://hub.docker.com/r/konard/box-js/tags?name=2.6.0-arm64) |

### Docker Hub - Language Boxes

| Language | Multi-arch | AMD64 | ARM64 |
|-------|------------|-------|-------|
| Python | [`konard/box-python:2.6.0`](https://hub.docker.com/r/konard/box-python/tags?name=2.6.0) | [`2.6.0-amd64`](https://hub.docker.com/r/konard/box-python/tags?name=2.6.0-amd64) | [`2.6.0-arm64`](https://hub.docker.com/r/konard/box-python/tags?name=2.6.0-arm64) |
| Go | [`konard/box-go:2.6.0`](https://hub.docker.com/r/konard/box-go/tags?name=2.6.0) | [`2.6.0-amd64`](https://hub.docker.com/r/konard/box-go/tags?name=2.6.0-amd64) | [`2.6.0-arm64`](https://hub.docker.com/r/konard/box-go/tags?name=2.6.0-arm64) |
| Rust | [`konard/box-rust:2.6.0`](https://hub.docker.com/r/konard/box-rust/tags?name=2.6.0) | [`2.6.0-amd64`](https://hub.docker.com/r/konard/box-rust/tags?name=2.6.0-amd64) | [`2.6.0-arm64`](https://hub.docker.com/r/konard/box-rust/tags?name=2.6.0-arm64) |
| Java | [`konard/box-java:2.6.0`](https://hub.docker.com/r/konard/box-java/tags?name=2.6.0) | [`2.6.0-amd64`](https://hub.docker.com/r/konard/box-java/tags?name=2.6.0-amd64) | [`2.6.0-arm64`](https://hub.docker.com/r/konard/box-java/tags?name=2.6.0-arm64) |
| Kotlin | [`konard/box-kotlin:2.6.0`](https://hub.docker.com/r/konard/box-kotlin/tags?name=2.6.0) | [`2.6.0-amd64`](https://hub.docker.com/r/konard/box-kotlin/tags?name=2.6.0-amd64) | [`2.6.0-arm64`](https://hub.docker.com/r/konard/box-kotlin/tags?name=2.6.0-arm64) |
| Ruby | [`konard/box-ruby:2.6.0`](https://hub.docker.com/r/konard/box-ruby/tags?name=2.6.0) | [`2.6.0-amd64`](https://hub.docker.com/r/konard/box-ruby/tags?name=2.6.0-amd64) | [`2.6.0-arm64`](https://hub.docker.com/r/konard/box-ruby/tags?name=2.6.0-arm64) |
| PHP | [`konard/box-php:2.6.0`](https://hub.docker.com/r/konard/box-php/tags?name=2.6.0) | [`2.6.0-amd64`](https://hub.docker.com/r/konard/box-php/tags?name=2.6.0-amd64) | [`2.6.0-arm64`](https://hub.docker.com/r/konard/box-php/tags?name=2.6.0-arm64) |
| Perl | [`konard/box-perl:2.6.0`](https://hub.docker.com/r/konard/box-perl/tags?name=2.6.0) | [`2.6.0-amd64`](https://hub.docker.com/r/konard/box-perl/tags?name=2.6.0-amd64) | [`2.6.0-arm64`](https://hub.docker.com/r/konard/box-perl/tags?name=2.6.0-arm64) |
| Swift | [`konard/box-swift:2.6.0`](https://hub.docker.com/r/konard/box-swift/tags?name=2.6.0) | [`2.6.0-amd64`](https://hub.docker.com/r/konard/box-swift/tags?name=2.6.0-amd64) | [`2.6.0-arm64`](https://hub.docker.com/r/konard/box-swift/tags?name=2.6.0-arm64) |
| Lean | [`konard/box-lean:2.6.0`](https://hub.docker.com/r/konard/box-lean/tags?name=2.6.0) | [`2.6.0-amd64`](https://hub.docker.com/r/konard/box-lean/tags?name=2.6.0-amd64) | [`2.6.0-arm64`](https://hub.docker.com/r/konard/box-lean/tags?name=2.6.0-arm64) |
| Rocq | [`konard/box-rocq:2.6.0`](https://hub.docker.com/r/konard/box-rocq/tags?name=2.6.0) | [`2.6.0-amd64`](https://hub.docker.com/r/konard/box-rocq/tags?name=2.6.0-amd64) | [`2.6.0-arm64`](https://hub.docker.com/r/konard/box-rocq/tags?name=2.6.0-arm64) |

### GitHub Container Registry - Combo Boxes

| Image | Multi-arch | AMD64 | ARM64 |
|-------|------------|-------|-------|
| Full Box | `ghcr.io/link-foundation/box:2.6.0` | `ghcr.io/link-foundation/box:2.6.0-amd64` | `ghcr.io/link-foundation/box:2.6.0-arm64` |
| Essentials | `ghcr.io/link-foundation/box-essentials:2.6.0` | `ghcr.io/link-foundation/box-essentials:2.6.0-amd64` | `ghcr.io/link-foundation/box-essentials:2.6.0-arm64` |
| JS | `ghcr.io/link-foundation/box-js:2.6.0` | `ghcr.io/link-foundation/box-js:2.6.0-amd64` | `ghcr.io/link-foundation/box-js:2.6.0-arm64` |

### GitHub Container Registry - Language Boxes

| Language | Multi-arch | AMD64 | ARM64 |
|-------|------------|-------|-------|
| Python | `ghcr.io/link-foundation/box-python:2.6.0` | `ghcr.io/link-foundation/box-python:2.6.0-amd64` | `ghcr.io/link-foundation/box-python:2.6.0-arm64` |
| Go | `ghcr.io/link-foundation/box-go:2.6.0` | `ghcr.io/link-foundation/box-go:2.6.0-amd64` | `ghcr.io/link-foundation/box-go:2.6.0-arm64` |
| Rust | `ghcr.io/link-foundation/box-rust:2.6.0` | `ghcr.io/link-foundation/box-rust:2.6.0-amd64` | `ghcr.io/link-foundation/box-rust:2.6.0-arm64` |
| Java | `ghcr.io/link-foundation/box-java:2.6.0` | `ghcr.io/link-foundation/box-java:2.6.0-amd64` | `ghcr.io/link-foundation/box-java:2.6.0-arm64` |
| Kotlin | `ghcr.io/link-foundation/box-kotlin:2.6.0` | `ghcr.io/link-foundation/box-kotlin:2.6.0-amd64` | `ghcr.io/link-foundation/box-kotlin:2.6.0-arm64` |
| Ruby | `ghcr.io/link-foundation/box-ruby:2.6.0` | `ghcr.io/link-foundation/box-ruby:2.6.0-amd64` | `ghcr.io/link-foundation/box-ruby:2.6.0-arm64` |
| PHP | `ghcr.io/link-foundation/box-php:2.6.0` | `ghcr.io/link-foundation/box-php:2.6.0-amd64` | `ghcr.io/link-foundation/box-php:2.6.0-arm64` |
| Perl | `ghcr.io/link-foundation/box-perl:2.6.0` | `ghcr.io/link-foundation/box-perl:2.6.0-amd64` | `ghcr.io/link-foundation/box-perl:2.6.0-arm64` |
| Swift | `ghcr.io/link-foundation/box-swift:2.6.0` | `ghcr.io/link-foundation/box-swift:2.6.0-amd64` | `ghcr.io/link-foundation/box-swift:2.6.0-arm64` |
| Lean | `ghcr.io/link-foundation/box-lean:2.6.0` | `ghcr.io/link-foundation/box-lean:2.6.0-amd64` | `ghcr.io/link-foundation/box-lean:2.6.0-arm64` |
| Rocq | `ghcr.io/link-foundation/box-rocq:2.6.0` | `ghcr.io/link-foundation/box-rocq:2.6.0-amd64` | `ghcr.io/link-foundation/box-rocq:2.6.0-arm64` |

### Docker Hub - dind-box (Docker-in-Docker variants, issue #80)

Each variant runs an inner Docker daemon. Run with `docker run --privileged` (default) or `docker run --runtime=sysbox-runc` (recommended for shared hosts). `docker ps -a` inside the container only lists containers created by that container - see [docs/case-studies/issue-80](https://github.com/link-foundation/box/blob/v2.6.0/docs/case-studies/issue-80/CASE-STUDY.md).

| Image | Multi-arch | AMD64 | ARM64 |
|-------|------------|-------|-------|
| Full Box + dind | [`konard/box-dind:2.6.0`](https://hub.docker.com/r/konard/box-dind/tags?name=2.6.0) | [`2.6.0-amd64`](https://hub.docker.com/r/konard/box-dind/tags?name=2.6.0-amd64) | [`2.6.0-arm64`](https://hub.docker.com/r/konard/box-dind/tags?name=2.6.0-arm64) |
| Essentials + dind | [`konard/box-essentials-dind:2.6.0`](https://hub.docker.com/r/konard/box-essentials-dind/tags?name=2.6.0) | [`2.6.0-amd64`](https://hub.docker.com/r/konard/box-essentials-dind/tags?name=2.6.0-amd64) | [`2.6.0-arm64`](https://hub.docker.com/r/konard/box-essentials-dind/tags?name=2.6.0-arm64) |
| JS + dind | [`konard/box-js-dind:2.6.0`](https://hub.docker.com/r/konard/box-js-dind/tags?name=2.6.0) | [`2.6.0-amd64`](https://hub.docker.com/r/konard/box-js-dind/tags?name=2.6.0-amd64) | [`2.6.0-arm64`](https://hub.docker.com/r/konard/box-js-dind/tags?name=2.6.0-arm64) |
| Python + dind | [`konard/box-python-dind:2.6.0`](https://hub.docker.com/r/konard/box-python-dind/tags?name=2.6.0) | [`2.6.0-amd64`](https://hub.docker.com/r/konard/box-python-dind/tags?name=2.6.0-amd64) | [`2.6.0-arm64`](https://hub.docker.com/r/konard/box-python-dind/tags?name=2.6.0-arm64) |
| Go + dind | [`konard/box-go-dind:2.6.0`](https://hub.docker.com/r/konard/box-go-dind/tags?name=2.6.0) | [`2.6.0-amd64`](https://hub.docker.com/r/konard/box-go-dind/tags?name=2.6.0-amd64) | [`2.6.0-arm64`](https://hub.docker.com/r/konard/box-go-dind/tags?name=2.6.0-arm64) |
| Rust + dind | [`konard/box-rust-dind:2.6.0`](https://hub.docker.com/r/konard/box-rust-dind/tags?name=2.6.0) | [`2.6.0-amd64`](https://hub.docker.com/r/konard/box-rust-dind/tags?name=2.6.0-amd64) | [`2.6.0-arm64`](https://hub.docker.com/r/konard/box-rust-dind/tags?name=2.6.0-arm64) |
| Java + dind | [`konard/box-java-dind:2.6.0`](https://hub.docker.com/r/konard/box-java-dind/tags?name=2.6.0) | [`2.6.0-amd64`](https://hub.docker.com/r/konard/box-java-dind/tags?name=2.6.0-amd64) | [`2.6.0-arm64`](https://hub.docker.com/r/konard/box-java-dind/tags?name=2.6.0-arm64) |
| Kotlin + dind | [`konard/box-kotlin-dind:2.6.0`](https://hub.docker.com/r/konard/box-kotlin-dind/tags?name=2.6.0) | [`2.6.0-amd64`](https://hub.docker.com/r/konard/box-kotlin-dind/tags?name=2.6.0-amd64) | [`2.6.0-arm64`](https://hub.docker.com/r/konard/box-kotlin-dind/tags?name=2.6.0-arm64) |
| Ruby + dind | [`konard/box-ruby-dind:2.6.0`](https://hub.docker.com/r/konard/box-ruby-dind/tags?name=2.6.0) | [`2.6.0-amd64`](https://hub.docker.com/r/konard/box-ruby-dind/tags?name=2.6.0-amd64) | [`2.6.0-arm64`](https://hub.docker.com/r/konard/box-ruby-dind/tags?name=2.6.0-arm64) |
| PHP + dind | [`konard/box-php-dind:2.6.0`](https://hub.docker.com/r/konard/box-php-dind/tags?name=2.6.0) | [`2.6.0-amd64`](https://hub.docker.com/r/konard/box-php-dind/tags?name=2.6.0-amd64) | [`2.6.0-arm64`](https://hub.docker.com/r/konard/box-php-dind/tags?name=2.6.0-arm64) |
| Perl + dind | [`konard/box-perl-dind:2.6.0`](https://hub.docker.com/r/konard/box-perl-dind/tags?name=2.6.0) | [`2.6.0-amd64`](https://hub.docker.com/r/konard/box-perl-dind/tags?name=2.6.0-amd64) | [`2.6.0-arm64`](https://hub.docker.com/r/konard/box-perl-dind/tags?name=2.6.0-arm64) |
| Swift + dind | [`konard/box-swift-dind:2.6.0`](https://hub.docker.com/r/konard/box-swift-dind/tags?name=2.6.0) | [`2.6.0-amd64`](https://hub.docker.com/r/konard/box-swift-dind/tags?name=2.6.0-amd64) | [`2.6.0-arm64`](https://hub.docker.com/r/konard/box-swift-dind/tags?name=2.6.0-arm64) |
| Lean + dind | [`konard/box-lean-dind:2.6.0`](https://hub.docker.com/r/konard/box-lean-dind/tags?name=2.6.0) | [`2.6.0-amd64`](https://hub.docker.com/r/konard/box-lean-dind/tags?name=2.6.0-amd64) | [`2.6.0-arm64`](https://hub.docker.com/r/konard/box-lean-dind/tags?name=2.6.0-arm64) |
| Rocq + dind | [`konard/box-rocq-dind:2.6.0`](https://hub.docker.com/r/konard/box-rocq-dind/tags?name=2.6.0) | [`2.6.0-amd64`](https://hub.docker.com/r/konard/box-rocq-dind/tags?name=2.6.0-amd64) | [`2.6.0-arm64`](https://hub.docker.com/r/konard/box-rocq-dind/tags?name=2.6.0-arm64) |

### GitHub Container Registry - dind-box (Docker-in-Docker variants, issue #80)

| Image | Multi-arch | AMD64 | ARM64 |
|-------|------------|-------|-------|
| Full Box + dind | `ghcr.io/link-foundation/box-dind:2.6.0` | `ghcr.io/link-foundation/box-dind:2.6.0-amd64` | `ghcr.io/link-foundation/box-dind:2.6.0-arm64` |
| Essentials + dind | `ghcr.io/link-foundation/box-essentials-dind:2.6.0` | `ghcr.io/link-foundation/box-essentials-dind:2.6.0-amd64` | `ghcr.io/link-foundation/box-essentials-dind:2.6.0-arm64` |
| JS + dind | `ghcr.io/link-foundation/box-js-dind:2.6.0` | `ghcr.io/link-foundation/box-js-dind:2.6.0-amd64` | `ghcr.io/link-foundation/box-js-dind:2.6.0-arm64` |
| Python + dind | `ghcr.io/link-foundation/box-python-dind:2.6.0` | `ghcr.io/link-foundation/box-python-dind:2.6.0-amd64` | `ghcr.io/link-foundation/box-python-dind:2.6.0-arm64` |
| Go + dind | `ghcr.io/link-foundation/box-go-dind:2.6.0` | `ghcr.io/link-foundation/box-go-dind:2.6.0-amd64` | `ghcr.io/link-foundation/box-go-dind:2.6.0-arm64` |
| Rust + dind | `ghcr.io/link-foundation/box-rust-dind:2.6.0` | `ghcr.io/link-foundation/box-rust-dind:2.6.0-amd64` | `ghcr.io/link-foundation/box-rust-dind:2.6.0-arm64` |
| Java + dind | `ghcr.io/link-foundation/box-java-dind:2.6.0` | `ghcr.io/link-foundation/box-java-dind:2.6.0-amd64` | `ghcr.io/link-foundation/box-java-dind:2.6.0-arm64` |
| Kotlin + dind | `ghcr.io/link-foundation/box-kotlin-dind:2.6.0` | `ghcr.io/link-foundation/box-kotlin-dind:2.6.0-amd64` | `ghcr.io/link-foundation/box-kotlin-dind:2.6.0-arm64` |
| Ruby + dind | `ghcr.io/link-foundation/box-ruby-dind:2.6.0` | `ghcr.io/link-foundation/box-ruby-dind:2.6.0-amd64` | `ghcr.io/link-foundation/box-ruby-dind:2.6.0-arm64` |
| PHP + dind | `ghcr.io/link-foundation/box-php-dind:2.6.0` | `ghcr.io/link-foundation/box-php-dind:2.6.0-amd64` | `ghcr.io/link-foundation/box-php-dind:2.6.0-arm64` |
| Perl + dind | `ghcr.io/link-foundation/box-perl-dind:2.6.0` | `ghcr.io/link-foundation/box-perl-dind:2.6.0-amd64` | `ghcr.io/link-foundation/box-perl-dind:2.6.0-arm64` |
| Swift + dind | `ghcr.io/link-foundation/box-swift-dind:2.6.0` | `ghcr.io/link-foundation/box-swift-dind:2.6.0-amd64` | `ghcr.io/link-foundation/box-swift-dind:2.6.0-arm64` |
| Lean + dind | `ghcr.io/link-foundation/box-lean-dind:2.6.0` | `ghcr.io/link-foundation/box-lean-dind:2.6.0-amd64` | `ghcr.io/link-foundation/box-lean-dind:2.6.0-arm64` |
| Rocq + dind | `ghcr.io/link-foundation/box-rocq-dind:2.6.0` | `ghcr.io/link-foundation/box-rocq-dind:2.6.0-amd64` | `ghcr.io/link-foundation/box-rocq-dind:2.6.0-arm64` |

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
docker pull ghcr.io/link-foundation/box:2.6.0
```

Pull specific architecture:
```sh
# AMD64
docker pull ghcr.io/link-foundation/box:2.6.0-amd64

# ARM64 (Apple Silicon, Raspberry Pi, etc.)
docker pull ghcr.io/link-foundation/box:2.6.0-arm64
```

Pull from the Docker Hub mirror:
```sh
docker pull konard/box:2.6.0
```

## Links
- [Docker Hub](https://hub.docker.com/r/konard/box)
- [GHCR packages](https://github.com/orgs/link-foundation/packages?repo_name=box)

Released on 2026-09-06
