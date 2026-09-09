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
#   VERIFY_IMAGES=1   Ask the registries which references a reader can pull
#   EXPECTED_PLATFORMS  Architectures a multi-arch tag must serve
#                     (default: "linux/amd64 linux/arm64"; empty = say what a
#                     reference carries without calling anything incomplete)
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
EXPECTED_PLATFORMS="${EXPECTED_PLATFORMS-linux/amd64 linux/arm64}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./registry-probe.sh
source "${SCRIPT_DIR}/registry-probe.sh"

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

# --- what the probe measured, rendered into the tables (issue #119d) --------
#
# The tables used to print a static "Multi-arch" heading over a column of links
# that were emitted for every image, whether or not it existed. The v2.7.0
# notes listed `konard/box-dind:2.7.0` under "not published" and then linked
# its `2.7.0-arm64` tag three tables further down, and headed `konard/box:2.7.0`
# "Multi-arch" while that reference served linux/amd64 only. A column heading
# is not a measurement: it says the same thing in the release where the mirror
# worked and in the release where it did not, which is the property that makes
# it useless to the reader deciding whether to pull.
#
# So the tag column carries the probe's answer for that exact reference, and a
# per-architecture tag is linked only when the reference was measured to serve
# that platform. Nothing measured means nothing claimed: without VERIFY_IMAGES
# the cells render exactly as they did before, which is also how the offline
# tests read them.
declare -A REF_STATE=()
declare -A REF_PLATFORMS=()

# ref_pullable REF - false only when the probe said a reader cannot pull REF.
ref_pullable() {
  case "${REF_STATE[$1]:-}" in
    "" | published) return 0 ;;
    *) return 1 ;;
  esac
}

# ref_serves REF PLATFORM - true unless REF was measured not to serve PLATFORM.
#
# Both "no probe ran" and "the probe could not read the platform list" answer
# true. An empty list is issue #117's "I could not look", and dropping a link
# over it would state as fact the thing that was not measured - the same defect
# as the static column, pointed the other way.
ref_serves() {
  # Separate statements on purpose: `local` marks every name local before it
  # evaluates any right-hand side, so `local ref="$1" x="${A[$ref]}"` reads an
  # unset `ref` and dies under `set -u`.
  local ref="$1" platform="$2"
  local platforms="${REF_PLATFORMS[$ref]:-}"
  ref_pullable "$ref" || return 1
  [ -n "${REF_STATE[$ref]:-}" ] || return 0
  [ -n "$platforms" ] || return 0
  [ -z "$(registry_probe_missing_platforms "$platform" "$platforms")" ]
}

# ref_measurement REF - the probe's answer for REF, as trailing cell text.
ref_measurement() {
  local ref="$1" platforms missing
  local state="${REF_STATE[$ref]:-}"
  case "$state" in
    "") return 0 ;;
    published) ;;
    missing)
      printf ' - **not published**'
      return 0
      ;;
    private)
      printf ' - **private**, not readable anonymously'
      return 0
      ;;
    *)
      printf ' - state unknown (the registry did not answer)'
      return 0
      ;;
  esac

  platforms="${REF_PLATFORMS[$ref]:-}"
  if [ -z "$platforms" ]; then
    printf ' - published, architectures not measured'
    return 0
  fi
  missing="$(registry_probe_missing_platforms "$EXPECTED_PLATFORMS" "$platforms")"
  if [ -n "$missing" ]; then
    printf ' - **%s only**, missing %s' "${platforms// /, }" "${missing// /, }"
  else
    printf ' - %s' "${platforms// /, }"
  fi
}

# dockerhub_tag_cell IMAGE TAG - the tag as a search link, or a bare code span
# when the probe says a reader cannot pull it. A tag-search URL renders for a
# tag that was never pushed, so linking one advertises an image that is not
# there - RC-17's defect without the 404 that would give it away.
dockerhub_tag_cell() {
  local image="$1" tag="$2"
  local ref="${image}:${tag}"
  if ref_pullable "$ref"; then
    printf '[`%s:%s`](https://hub.docker.com/r/%s/tags?name=%s)' \
      "$image" "$tag" "$image" "$tag"
  else
    printf '`%s:%s`' "$image" "$tag"
  fi
}

# dockerhub_arch_cell IMAGE ARCH - one per-architecture tag cell.
dockerhub_arch_cell() {
  local image="$1" arch="$2" ref="${1}:${VERSION}"
  if ref_serves "$ref" "linux/${arch}"; then
    printf '[`%s-%s`](https://hub.docker.com/r/%s/tags?name=%s-%s)' \
      "$VERSION" "$arch" "$image" "$VERSION" "$arch"
  else
    printf '`%s-%s`' "$VERSION" "$arch"
  fi
}

# dockerhub_row LABEL SUFFIX - one table row of Docker Hub tags.
dockerhub_row() {
  local label="$1" image="${DOCKERHUB_IMAGE}${2}"
  printf '| %s | %s%s | %s | %s |\n' \
    "$label" \
    "$(dockerhub_tag_cell "$image" "$VERSION")" "$(ref_measurement "${image}:${VERSION}")" \
    "$(dockerhub_arch_cell "$image" amd64)" \
    "$(dockerhub_arch_cell "$image" arm64)"
}

# ghcr_row LABEL SUFFIX - one table row of GHCR tags.
#
# The tags are code spans, not links to the package page. Every
# github.com/OWNER/REPO/pkgs/container/... URL these notes used to emit is a
# 404 until that package exists, and 85 of them were 404ing in this
# repository's documentation when issue #115 measured it (RC-17). A release
# note that links a page that does not exist is the same defect as a check that
# cannot fail: it looks like evidence and carries none. `docker pull` on the
# reference below is the real test, and the publication section above says
# which of them passed it.
ghcr_row() {
  local label="$1" suffix="$2"
  local image="${GHCR_IMAGE}${suffix}"
  printf '| %s | `%s:%s`%s | `%s:%s-amd64` | `%s:%s-arm64` |\n' \
    "$label" "$image" "$VERSION" "$(ref_measurement "${image}:${VERSION}")" \
    "$image" "$VERSION" \
    "$image" "$VERSION"
}

# rows FIRST_COLUMN ROW_FN ENTRY... - a table header plus one row per entry.
rows() {
  local first_column="$1" row_fn="$2"
  shift 2
  local entry
  printf '| %s | Tag | AMD64 | ARM64 |\n' "$first_column"
  printf '|-------|-----|-------|-------|\n'
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

# --- publication check (issue #115 principle #13, corrected by issue #117) ----
#
# "Never gate the release on an image push, and assert the manifests that were
# published." The GitHub Release is created from the source state and is not
# blocked by a failed push, so the notes have to say which images actually
# exist rather than assume all of them do.
#
# What issue #117 found wrong with the first version of this check: it ran
# `docker manifest inspect` inside `create-release`, immediately after
# `docker/login-action` had authenticated that job to ghcr.io. It therefore
# measured *the publisher's* view. The notes for v2.6.0 say "28 of 56 image
# references resolve"; for anybody reading them the number was 0 of 56, because
# both GHCR packages are private and Docker Hub had received nothing at all.
#
# The check is now anonymous - the same request a reader of these notes makes -
# and it reports per registry, because "28 of 56" also hid *which* half was
# missing. `private` is a state of its own: an image that exists and cannot be
# pulled is not a published image, and saying "missing" about it would be the
# same kind of false claim in the other direction.
#
# Off by default so the generator stays offline-testable; the workflow sets
# VERIFY_IMAGES=1.

# all_refs - every multi-arch reference this release claims to publish, one per
# line. The per-architecture tags are not checked separately: a multi-arch
# manifest that resolves proves both of them.
all_refs() {
  local entry suffix
  for entry in "${COMBO_IMAGES[@]}" "${LANGUAGE_IMAGES[@]}" "${DIND_IMAGES[@]}"; do
    suffix="${entry#*|}"
    printf '%s%s:%s\n' "$GHCR_IMAGE" "$suffix" "$VERSION"
    printf '%s%s:%s\n' "$DOCKERHUB_IMAGE" "$suffix" "$VERSION"
  done
}

GHCR_PULLABLE=0
GHCR_TOTAL=0
DOCKERHUB_PULLABLE=0
DOCKERHUB_TOTAL=0

# probe_all - fill REF_STATE, REF_PLATFORMS and the per-registry counters.
#
# registry_probe_platforms, not registry_probe_pull: "does this resolve" is the
# question that was green while `konard/box:2.7.0` served one architecture
# (issue #119). An index answers it out of the manifest that was fetched
# anyway; the extra request is spent only on a reference that turned out to be
# a plain single-platform manifest, which is exactly the case worth the cost.
probe_all() {
  local ref
  while IFS= read -r ref; do
    registry_probe_platforms "$ref"
    REF_STATE["$ref"]="$REGISTRY_PROBE_STATE"
    REF_PLATFORMS["$ref"]="$REGISTRY_PROBE_PLATFORMS"
    case "$ref" in
      "$GHCR_IMAGE"*)
        GHCR_TOTAL=$((GHCR_TOTAL + 1))
        if [ "$REGISTRY_PROBE_STATE" = "published" ]; then
          GHCR_PULLABLE=$((GHCR_PULLABLE + 1))
        fi
        ;;
      *)
        DOCKERHUB_TOTAL=$((DOCKERHUB_TOTAL + 1))
        if [ "$REGISTRY_PROBE_STATE" = "published" ]; then
          DOCKERHUB_PULLABLE=$((DOCKERHUB_PULLABLE + 1))
        fi
        ;;
    esac
  done < <(all_refs)
}

# refs_in_state STATE - the references currently in STATE, one per line.
refs_in_state() {
  local wanted="$1" ref
  while IFS= read -r ref; do
    if [ "${REF_STATE[$ref]:-}" = "$wanted" ]; then
      printf '%s\n' "$ref"
    fi
  done < <(all_refs)
}

# single_arch_refs - published references that do not serve EXPECTED_PLATFORMS.
single_arch_refs() {
  local ref missing
  [ -n "$EXPECTED_PLATFORMS" ] || return 0
  while IFS= read -r ref; do
    [ "${REF_STATE[$ref]:-}" = "published" ] || continue
    [ -n "${REF_PLATFORMS[$ref]:-}" ] || continue
    missing="$(registry_probe_missing_platforms "$EXPECTED_PLATFORMS" "${REF_PLATFORMS[$ref]}")"
    [ -n "$missing" ] || continue
    printf '`%s` carries %s, missing %s\n' "$ref" "${REF_PLATFORMS[$ref]// /, }" "${missing// /, }"
  done < <(all_refs)
}

# state_list HEADING STATE - a bullet list, or nothing when the state is empty.
state_list() {
  local heading="$1" state="$2"
  local refs
  mapfile -t refs < <(refs_in_state "$state")
  [ "${#refs[@]}" -gt 0 ] || return 0
  printf '\n%s\n\n' "$heading"
  printf -- '- `%s`\n' "${refs[@]}"
}

publication_section() {
  local total=$((GHCR_TOTAL + DOCKERHUB_TOTAL))
  local pullable=$((GHCR_PULLABLE + DOCKERHUB_PULLABLE))
  local single

  printf '\n## Image publication\n\n'
  printf 'Checked **anonymously**, the way a reader of these notes pulls them: %s of %s image references can be pulled without credentials.\n\n' \
    "$pullable" "$total"
  printf '| Registry | Pullable | Checked |\n'
  printf '|----------|----------|--------|\n'
  printf '| GitHub Container Registry (registry of record) | %s | %s |\n' "$GHCR_PULLABLE" "$GHCR_TOTAL"
  printf '| Docker Hub (mirror) | %s | %s |\n' "$DOCKERHUB_PULLABLE" "$DOCKERHUB_TOTAL"

  if [ "$GHCR_PULLABLE" -eq 0 ] && [ "$GHCR_TOTAL" -gt 0 ]; then
    printf '\n> **Nothing in this release can be pulled from the registry of record.** The tables below list what the build was supposed to publish, not what you can run today. See the run that produced this release.\n'
  fi

  state_list 'These references are **not published**; the tables below list them for completeness, not as something you can pull today:' missing
  state_list 'These exist but are **not readable anonymously** - the package is private, so publishing to it reaches nobody:' private
  state_list 'The registry did not answer for these, so their state is unknown (this is not a claim that they are missing):' unknown

  mapfile -t single < <(single_arch_refs)
  if [ "${#single[@]}" -gt 0 ]; then
    printf '\nThese **resolve, and serve fewer architectures than this release built**. Pulling one on a platform it does not carry fails with `no matching manifest`, which is why a reference that resolves is not by itself evidence that it was published correctly (issue #119):\n\n'
    printf -- '- %s\n' "${single[@]}"
  fi

  if [ "$((GHCR_TOTAL - GHCR_PULLABLE))" -gt 0 ] || [ "$((DOCKERHUB_TOTAL - DOCKERHUB_PULLABLE))" -gt 0 ]; then
    printf '\nRe-run the release workflow to publish the missing references. The GitHub Release is deliberately not blocked on an image push (issue #115), and a run that ends with nothing published fails on its own publication check rather than by withholding these notes (issue #117).\n'
  fi
}

if [ "${VERIFY_IMAGES:-0}" = "1" ]; then
  probe_all
  publication_section
fi

printf '\n## Docker Images\n\n'
if [ "${VERIFY_IMAGES:-0}" = "1" ]; then
  printf 'The **Tag** column is the reference that selects a platform for you, followed by the architectures it was measured to serve when these notes were generated. A per-architecture tag is linked only where the reference it belongs to could be read.\n'
else
  printf 'The **Tag** column is the reference that selects a platform for you. These notes were generated without a registry check, so no cell below is a claim that the reference exists.\n'
fi

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

GitHub Container Registry is the registry of record: it is written with the
run's own GITHUB_TOKEN, which cannot expire (issue #115, RC-3). Docker Hub is a
mirror of it, and the publication section above says which of the two actually
carries this version.

Pull multi-arch (auto-selects your platform):
\`\`\`sh
docker pull ${GHCR_IMAGE}:${VERSION}
\`\`\`

Pull specific architecture:
\`\`\`sh
# AMD64
docker pull ${GHCR_IMAGE}:${VERSION}-amd64

# ARM64 (Apple Silicon, Raspberry Pi, etc.)
docker pull ${GHCR_IMAGE}:${VERSION}-arm64
\`\`\`

Pull from the Docker Hub mirror:
\`\`\`sh
docker pull ${DOCKERHUB_IMAGE}:${VERSION}
\`\`\`

## Links
- [Docker Hub](https://hub.docker.com/r/${DOCKERHUB_IMAGE})
- [GHCR packages](https://github.com/orgs/${REPO%%/*}/packages?repo_name=${REPO#*/})

Released on ${RELEASE_DATE}
NOTES
