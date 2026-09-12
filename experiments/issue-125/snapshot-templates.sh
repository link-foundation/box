#!/usr/bin/env bash
# Snapshot every CI/CD file and the complete tracked file tree of the four
# reference templates named by issue #125.
#
# Usage:
#   bash experiments/issue-125/snapshot-templates.sh [CHECKOUT_ROOT] [DEST]
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
checkout_root="${1:-/tmp/issue125-templates}"
dest="${2:-${repo_root}/dev/log/issues/125/pulls/126/templates}"
names=(js python rust php)

# Root files consumed by CI. Application source and lockfiles remain visible in
# *.file-tree.txt, but are not duplicated into the evidence bundle.
config_globs=(
  '.changeset/*' '.lycheeignore' '.hadolint.yaml' '.markdownlint*'
  '.editorconfig' '.secretlintrc*' '.zizmor.yml' '.actionlint*'
  '.pre-commit-config.yaml' 'lychee.toml' 'CONTRIBUTING.md' 'RELEASING.md'
  'docs/*.md'
)

mkdir -p "${dest}"
{
  echo '# Current reference-template revisions compared for issue #125.'
  echo '# Complete tracked trees are in <name>.file-tree.txt; copied content is'
  echo '# every .github/** and scripts/** path plus CI-consumed root config/docs.'
  echo "# Collected by experiments/issue-125/snapshot-templates.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)."
  echo '# name  sha  committed  tracked-files  stored-files'
} >"${dest}/SNAPSHOT.txt"

for name in "${names[@]}"; do
  src="${checkout_root}/${name}"
  if [ ! -d "${src}/.git" ]; then
    echo "snapshot-templates: ${src} is not a git checkout" >&2
    exit 1
  fi

  git -C "${src}" ls-files >"${dest}/${name}.file-tree.txt"
  tracked="$(wc -l <"${dest}/${name}.file-tree.txt")"

  # The destination is a generated, name-scoped snapshot. Clearing it makes a
  # refresh exact when an upstream file was removed between runs.
  rm -rf "${dest:?}/${name}"
  stored=0
  while IFS= read -r path; do
    case "${path}" in
      .github/* | scripts/*) ;;
      *)
        keep=0
        for glob in "${config_globs[@]}"; do
          [ "${glob//[!\/]/}" = "${path//[!\/]/}" ] || continue
          # The value is deliberately a pattern.
          # shellcheck disable=SC2254
          case "${path}" in $glob) keep=1 ;; esac
        done
        [ "${keep}" = 1 ] || continue
        ;;
    esac
    mkdir -p "${dest}/${name}/$(dirname "${path}")"
    cp "${src}/${path}" "${dest}/${name}/${path}"
    stored=$((stored + 1))
  done <"${dest}/${name}.file-tree.txt"

  printf '%s  %s  %s  %s  %s\n' \
    "${name}" \
    "$(git -C "${src}" rev-parse HEAD)" \
    "$(git -C "${src}" log -1 --format=%cI)" \
    "${tracked}" \
    "${stored}" >>"${dest}/SNAPSHOT.txt"
done

git -C "${repo_root}" ls-files '.github/*' 'scripts/*' \
  >"${dest}/box.file-tree.txt"

cat "${dest}/SNAPSHOT.txt"
