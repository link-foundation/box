#!/usr/bin/env bash
# build-chain.sh
#
# Builds one box variant and everything it is layered on, locally, from the
# working tree.
#
# Why this exists (issue #121). The five pre-merge jobs in
# .github/workflows/pr-tests.yml that build images - js, essentials, one
# language, full, and the base layer of each dind variant - each carried their
# own copy of the same chain as an inline `run:` block. Three consequences,
# all of them the point of this file:
#
#   1. A step that is a single command can own an execution budget
#      (scripts/ci/run-with-budget-warning.sh, docs/CI-TIMEOUT-BUDGETS.md); a
#      seventy-line inline block cannot, so those steps had no deadline but the
#      job's `timeout-minutes` backstop - which reports a *cancelled* job.
#   2. Only actionlint's bundled shellcheck ever saw that shell, and only for
#      the workflow files. Here it is linted by scripts/ci/run-shellcheck.sh
#      and formatted by scripts/ci/run-shfmt.sh like every other script.
#   3. The four copies had already drifted: the full-box job tagged its result
#      `box-test` while the dind job tagged the same image `box-full`, and the
#      list of languages the full box is assembled from was written out twice.
#
# The language list is derived, not repeated: the full box's stages come from
# `ARG <LANGUAGE>_IMAGE` in ubuntu/24.04/full-box/Dockerfile, so a language
# added to that image is built here without editing this file.
#
# Usage:
#   bash scripts/ci/build-chain.sh VARIANT
#
#     js           box-js
#     essentials   box-js -> box-essentials
#     <language>   box-js -> box-essentials -> box-<language>
#     full         box-js -> box-essentials -> every language -> box-full
#
# The final image is always tagged `box-<variant>`, so a caller knows the name
# without parsing anything.
#
# Environment:
#   BUILD_CHAIN_DOCKER   docker command to use (default: docker). The seam the
#                        offline test in experiments/ substitutes a recorder
#                        for; nothing in CI sets it.
#   BOX_VERBOSE=1        Trace every command this script runs
#
# Exit codes: 0 on success, 1 on a build failure, 2 on a usage error.

set -euo pipefail

if [ "${BOX_VERBOSE:-0}" = "1" ]; then
  set -x
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCKER="${BUILD_CHAIN_DOCKER:-docker}"
FULL_BOX_DOCKERFILE="ubuntu/24.04/full-box/Dockerfile"

cd "$REPO_ROOT"

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 VARIANT   (js | essentials | full | <language>)" >&2
  exit 2
fi

VARIANT="$1"

# full_box_languages - the languages the full box copies stages from, read out
# of its Dockerfile. ESSENTIALS_IMAGE is the base, not a language stage.
full_box_languages() {
  sed -n 's/^ARG \([A-Z0-9_]*\)_IMAGE=.*/\1/p' "$FULL_BOX_DOCKERFILE" \
    | grep -v '^ESSENTIALS$' \
    | tr '[:upper:]' '[:lower:]'
}

build() {
  local dockerfile="$1" tag="$2"
  shift 2
  echo ""
  echo "=== Building ${tag} ==="
  "$DOCKER" build -f "$dockerfile" "$@" -t "$tag" .
}

build_js() {
  build ubuntu/24.04/js/Dockerfile box-js
}

build_essentials() {
  build ubuntu/24.04/essentials-box/Dockerfile box-essentials \
    --build-arg JS_IMAGE=box-js
}

build_language() {
  local language="$1"
  if [ ! -f "ubuntu/24.04/${language}/Dockerfile" ]; then
    echo "No Dockerfile for variant '${language}' (looked for ubuntu/24.04/${language}/Dockerfile)." >&2
    exit 2
  fi
  build "ubuntu/24.04/${language}/Dockerfile" "box-${language}" \
    --build-arg ESSENTIALS_IMAGE=box-essentials
}

build_full() {
  local language
  local -a build_args=(--build-arg ESSENTIALS_IMAGE=box-essentials)

  for language in $(full_box_languages); do
    build_language "$language"
    build_args+=(--build-arg "$(echo "$language" | tr '[:lower:]' '[:upper:]')_IMAGE=box-${language}")
  done

  build "$FULL_BOX_DOCKERFILE" box-full "${build_args[@]}"
}

case "$VARIANT" in
  js)
    build_js
    ;;
  essentials)
    build_js
    build_essentials
    ;;
  full)
    build_js
    build_essentials
    build_full
    ;;
  *)
    build_js
    build_essentials
    build_language "$VARIANT"
    ;;
esac

echo ""
echo "=== Chain for '${VARIANT}' built; final image is box-${VARIANT} ==="
