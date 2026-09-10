#!/usr/bin/env bash
# Snapshot the seven reference templates' CI/CD trees into this pull request's
# evidence directory.
#
# Issue #123 asks for the comparison to be made "comparing the full file tree of
# every GitHub workflow and CI/CD script" of
# link-foundation/{js,python,rust,php,csharp,go,java}-ai-driven-development-pipeline-template.
# A comparison is only checkable if the thing compared against is recorded, so
# this stores:
#
#   <name>.file-tree.txt   every tracked path in the template, so the comparison
#                          of file trees is complete even where content is not
#                          stored;
#   <name>/.github/**      the workflows and composite actions;
#   <name>/scripts/**      the scripts those workflows run;
#   <name>/<config>        root-level tool configuration a workflow reads.
#
# Excluded: the application source each template ships as an example, lockfiles,
# and each template's own docs/case-studies evidence - none of which is CI/CD,
# and which is what makes the js template 393 files.
#
# Usage:
#   bash experiments/issue-123/snapshot-templates.sh [TEMPLATE_ROOT] [DEST]
set -uo pipefail

ROOT="${1:-/tmp/templates}"
DEST="${2:-dev/log/issues/123/pulls/124/templates}"

TEMPLATES=(js python rust php csharp go java)

# Root-level files a workflow or CI script reads. Globbed against the template's
# own tracked list, so an absent one is simply not stored.
CONFIG_GLOBS=(
  '.changeset/*' '.lycheeignore' '.hadolint.yaml' '.markdownlint*' '.editorconfig'
  '.secretlintrc*' '.zizmor.yml' '.actionlint*' '.pre-commit-config.yaml'
  'lychee.toml' 'CONTRIBUTING.md' 'RELEASING.md' 'docs/*.md'
)

mkdir -p "$DEST"

{
  echo "# The template revisions this pull request was compared against (issue #123)."
  echo "#"
  echo "# Collected by experiments/issue-123/snapshot-templates.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)."
  echo "# Every upstream report filed from this branch quotes the same revision."
  echo "#"
  echo "# name  sha  committed  tracked-files  stored-files"
} >"$DEST/SNAPSHOT.txt"

for name in "${TEMPLATES[@]}"; do
  src="$ROOT/$name"
  if [ ! -d "$src/.git" ]; then
    echo "snapshot-templates: $src is not a git checkout, skipped" >&2
    continue
  fi

  git -C "$src" ls-files >"$DEST/$name.file-tree.txt"
  tracked="$(wc -l <"$DEST/$name.file-tree.txt")"

  rm -rf "${DEST:?}/$name"
  stored=0
  while IFS= read -r path; do
    case "$path" in
      .github/* | scripts/*) ;;
      *)
        keep=0
        for glob in "${CONFIG_GLOBS[@]}"; do
          # `case` patterns do not stop at a path separator, so `docs/*.md`
          # matches `docs/case-studies/issue-1/data/templates/js-analysis.md`
          # too - which pulled each template's own case-study evidence into a
          # directory whose header says it is excluded. Require the same number
          # of components as the pattern has.
          [ "${glob//[!\/]/}" = "${path//[!\/]/}" ] || continue
          # shellcheck disable=SC2254  # the glob is meant to be a pattern here
          case "$path" in
            $glob) keep=1 ;;
          esac
        done
        [ "$keep" = 1 ] || continue
        ;;
    esac
    mkdir -p "$DEST/$name/$(dirname "$path")"
    cp "$src/$path" "$DEST/$name/$path"
    stored=$((stored + 1))
  done <"$DEST/$name.file-tree.txt"

  printf '%s  %s  %s  %s  %s\n' \
    "$name" \
    "$(git -C "$src" rev-parse HEAD)" \
    "$(git -C "$src" log -1 --format=%cI)" \
    "$tracked" \
    "$stored" >>"$DEST/SNAPSHOT.txt"
done

# Our own tree, so the two sides of the comparison are both recorded.
git ls-files '.github/*' 'scripts/*' >"$DEST/box.file-tree.txt"

cat "$DEST/SNAPSHOT.txt"
