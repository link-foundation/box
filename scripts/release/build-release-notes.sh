#!/usr/bin/env bash
# build-release-notes.sh - Render the GitHub Release notes for one version.
#
# Why this exists (issue #115). The notes were 106 lines of inline YAML in
# .github/workflows/release.yml, split across two steps only to stay under
# GitHub's 21000-character per-step expression limit (issue #80), and every
# image row was written out by hand: eleven languages x two registries, twice
# more for the dind variants. A hand-written row per image is a false negative
# waiting to happen - add a language to the build matrix and the release notes
# stay silent about it, with nothing to notice. The tables are generated from
# one list here, and experiments/test-issue115-release-notes.sh asserts that
# list matches the matrix in release.yml.
#
# Usage:
#   VERSION=2.5.0 REPO=link-foundation/box \
#   GHCR_IMAGE=ghcr.io/link-foundation/box DOCKERHUB_IMAGE=konard/box \
#     bash scripts/release/build-release-notes.sh > /tmp/release-notes.md
#
# Environment variables:
#   VERSION           Version being released, without a leading "v" (required)
#   REPO              owner/name of this repository (required)
#   GHCR_IMAGE        Full GHCR image, registry/owner/name (required)
#   DOCKERHUB_IMAGE   Docker Hub image, namespace/name (required)
#   RELEASE_DATE      Date printed at the end (default: today, UTC)
#   BOX_VERBOSE=1     Trace every command this script runs
#
# Writes the notes to stdout. Exit code 0 = notes rendered.

set -euo pipefail

if [ "${BOX_VERBOSE:-0}" = "1" ]; then
  set -x
fi

for var in VERSION REPO GHCR_IMAGE DOCKERHUB_IMAGE; do
  if [ -z "${!var:-}" ]; then
    echo "::error title=build-release-notes.sh::${var} is required" >&2
    exit 2
  fi
done

RELEASE_DATE="${RELEASE_DATE:-$(date -u +%Y-%m-%d)}"

# The GHCR package page is addressed by the last path segment of the image
# name ("box"), not by the full image reference.
GHCR_PACKAGE="${GHCR_IMAGE##*/}"

# label|suffix. The suffix is appended to both image names, so one list drives
# Docker Hub, GHCR and their dind variants.
COMBO_IMAGES=(
  "Full Box|"
  "Essentials|-essentials"
  "JS|-js"
)

# Must stay in sync with the `language:` matrix in .github/workflows/release.yml
# (asserted by experiments/test-issue115-release-notes.sh).
LANGUAGE_IMAGES=(
  "Python|-python"
  "Go|-go"
  "Rust|-rust"
  "Java|-java"
  "Kotlin|-kotlin"
  "Ruby|-ruby"
  "PHP|-php"
  "Perl|-perl"
  "Swift|-swift"
  "Lean|-lean"
  "Rocq|-rocq"
)

# dockerhub_row LABEL SUFFIX - one table row of Docker Hub tag links.
dockerhub_row() {
  local label="$1" image="${DOCKERHUB_IMAGE}${2}"
  printf '| %s | [`%s:%s`](https://hub.docker.com/r/%s/tags?name=%s) | [`%s-amd64`](https://hub.docker.com/r/%s/tags?name=%s-amd64) | [`%s-arm64`](https://hub.docker.com/r/%s/tags?name=%s-arm64) |\n' \
    "$label" "$image" "$VERSION" "$image" "$VERSION" \
    "$VERSION" "$image" "$VERSION" \
    "$VERSION" "$image" "$VERSION"
}

# ghcr_row LABEL SUFFIX - one table row of GHCR package links.
ghcr_row() {
  local label="$1" suffix="$2"
  local image="${GHCR_IMAGE}${suffix}" package="${GHCR_PACKAGE}${suffix}"
  printf '| %s | [`%s:%s`](https://github.com/%s/pkgs/container/%s?tag=%s) | [`%s-amd64`](https://github.com/%s/pkgs/container/%s?tag=%s-amd64) | [`%s-arm64`](https://github.com/%s/pkgs/container/%s?tag=%s-arm64) |\n' \
    "$label" "$image" "$VERSION" "$REPO" "$package" "$VERSION" \
    "$VERSION" "$REPO" "$package" "$VERSION" \
    "$VERSION" "$REPO" "$package" "$VERSION"
}

# rows FIRST_COLUMN ROW_FN ENTRY... - a table header plus one row per entry.
rows() {
  local first_column="$1" row_fn="$2"
  shift 2
  local entry
  printf '| %s | Multi-arch | AMD64 | ARM64 |\n' "$first_column"
  printf '|-------|------------|-------|-------|\n'
  for entry in "$@"; do
    "$row_fn" "${entry%%|*}" "${entry#*|}"
  done
}

# table HEADING FIRST_COLUMN ROW_FN ENTRY... - a heading plus its table.
table() {
  local heading="$1"
  shift
  printf '\n### %s\n\n' "$heading"
  rows "$@"
}

# The dind variants layer an inner Docker daemon on every published image
# (issue #80), so their list is the combo and language lists with -dind added.
dind_entries() {
  local entry
  for entry in "${COMBO_IMAGES[@]}" "${LANGUAGE_IMAGES[@]}"; do
    printf '%s + dind|%s-dind\n' "${entry%%|*}" "${entry#*|}"
  done
}

mapfile -t DIND_IMAGES < <(dind_entries)

printf '## Docker Images\n'

table "Docker Hub - Combo Boxes" "Image" dockerhub_row "${COMBO_IMAGES[@]}"
table "Docker Hub - Language Boxes" "Language" dockerhub_row "${LANGUAGE_IMAGES[@]}"
table "GitHub Container Registry - Combo Boxes" "Image" ghcr_row "${COMBO_IMAGES[@]}"
table "GitHub Container Registry - Language Boxes" "Language" ghcr_row "${LANGUAGE_IMAGES[@]}"

printf '\n### Docker Hub - dind-box (Docker-in-Docker variants, issue #80)\n\n'
printf 'Each variant runs an inner Docker daemon. Run with `docker run --privileged` (default) or `docker run --runtime=sysbox-runc` (recommended for shared hosts). `docker ps -a` inside the container only lists containers created by that container - see [docs/case-studies/issue-80](https://github.com/%s/blob/v%s/docs/case-studies/issue-80/CASE-STUDY.md).\n\n' \
  "$REPO" "$VERSION"
rows "Image" dockerhub_row "${DIND_IMAGES[@]}"
table "GitHub Container Registry - dind-box (Docker-in-Docker variants, issue #80)" "Image" ghcr_row "${DIND_IMAGES[@]}"

cat <<NOTES

## Architecture

\`\`\`
JS box (${DOCKERHUB_IMAGE}-js)
  → Essentials box (${DOCKERHUB_IMAGE}-essentials)
    ├─ box-python  ├─ box-go    ├─ box-rust
    ├─ box-java    ├─ box-kotlin ├─ box-ruby
    ├─ box-php     ├─ box-perl   ├─ box-swift
    ├─ box-lean    └─ box-rocq
    → Full box (${DOCKERHUB_IMAGE}) [merges all language images]
\`\`\`

## Quick Start

Pull multi-arch (auto-selects your platform):
\`\`\`sh
docker pull ${DOCKERHUB_IMAGE}:${VERSION}
\`\`\`

Pull specific architecture:
\`\`\`sh
# AMD64
docker pull ${DOCKERHUB_IMAGE}:${VERSION}-amd64

# ARM64 (Apple Silicon, Raspberry Pi, etc.)
docker pull ${DOCKERHUB_IMAGE}:${VERSION}-arm64
\`\`\`

Pull from GHCR:
\`\`\`sh
docker pull ${GHCR_IMAGE}:${VERSION}
\`\`\`

## Links
- [Docker Hub](https://hub.docker.com/r/${DOCKERHUB_IMAGE})
- [GHCR Package](https://github.com/${REPO}/pkgs/container/${GHCR_PACKAGE})

Released on ${RELEASE_DATE}
NOTES
