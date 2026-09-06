#!/usr/bin/env bash
# check-file-line-limits.sh - Fail the build on a file that has outgrown review.
#
# Ported from the reference template's scripts/check-file-line-limits.sh
# (issue #115, R3/R5), widened from "JavaScript, Markdown and release.yml" to
# every text file this repository actually maintains.
#
# Why. .github/workflows/release.yml reached 3135 lines with ten near-identical
# build jobs in it, and that size was itself a root cause (issue #115, RC-8):
# a defect fixed in one copy survived in the other nine, which is how the
# missing `--amend` (RC-4) and the unguarded Docker Hub push (RC-7) came back
# after being fixed. Nobody diffs ten copies by hand, and no reviewer reads
# 3135 lines of YAML. The limit is a proxy for "a reviewer can still hold this
# file in their head"; crossing it is the signal to extract, not to raise the
# limit.
#
# The warning threshold exists so the failure does not arrive as a surprise on
# the pull request that happens to cross the line: at 1350 lines the file is
# already asking to be split, and a warning is a cheaper place to hear it than
# a red X on an unrelated change.
#
# Usage:
#   bash scripts/ci/check-file-line-limits.sh          # check
#   bash scripts/ci/check-file-line-limits.sh --list   # print what is checked
#
# Environment variables:
#   LIMIT            Hard limit, in lines (default: 1500)
#   WARN_THRESHOLD   Warn at or above this (default: 1350)
#   BOX_VERBOSE=1    Trace every command this script runs
#
# Exit codes:
#   0  every checked file is within the limit
#   1  at least one file exceeds it
#   2  misuse: not a git repository, bad option, or nothing to check

set -uo pipefail

if [ "${BOX_VERBOSE:-0}" = "1" ]; then
  set -x
fi

LIMIT="${LIMIT:-1500}"
WARN_THRESHOLD="${WARN_THRESHOLD:-1350}"

LIST_ONLY=0
case "${1:-}" in
  --list) LIST_ONLY=1 ;;
  -h | --help)
    sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  "") ;;
  *)
    echo "::error title=check-file-line-limits::unknown option '$1' (try --list)" >&2
    exit 2
    ;;
esac

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "::error title=check-file-line-limits::not inside a git repository" >&2
  exit 2
fi

# Tracked files only. `find` would also walk build output, a stray venv and
# anything a previous job left in the working tree, and a limit that fires on
# a file nobody wrote is a false positive - the class of defect issue #115 is
# about.
#
# Extensions: everything in this repository that is written and reviewed by
# hand. Dockerfiles have no extension and are covered by hadolint instead.
EXTENSIONS='sh|md|yml|yaml|mjs|js|cjs|py|rb'

# Paths that are exempt, each with the reason it is exempt. All of them hold
# verbatim copies of files from other projects, collected as evidence: they are
# quotations, and a quotation that is reflowed to fit a limit is no longer
# evidence.
#
#   dev/log/                      issue evidence: other projects' logs and docs
#   docs/case-studies/*/data/     upstream release workflows, quoted verbatim
#   docs/case-studies/*/templates/ ditto
#   *template-release.yml         ditto, where the copy sits beside the study
is_exempt() {
  case "$1" in
    dev/log/*) return 0 ;;
    docs/case-studies/*/data/*) return 0 ;;
    docs/case-studies/*/templates/*) return 0 ;;
    docs/case-studies/*template-release.yml) return 0 ;;
    *) return 1 ;;
  esac
}

FAILURES=()
WARNINGS=()
CHECKED=0

check_file() {
  local file="$1"
  local hint="${2:-Split it: extract shared steps into scripts/ or a reusable workflow.}"
  local line_count
  line_count="$(wc -l <"$file" | tr -d '[:space:]')"
  CHECKED=$((CHECKED + 1))

  if [ "$line_count" -gt "$LIMIT" ]; then
    echo "$file: $line_count lines (over the ${LIMIT}-line limit)"
    echo "::error file=$file::File has $line_count lines (limit: ${LIMIT}). ${hint}"
    FAILURES+=("$file ($line_count lines)")
  elif [ "$line_count" -ge "$WARN_THRESHOLD" ]; then
    echo "$file: $line_count lines (approaching the ${LIMIT}-line limit)"
    echo "::warning file=$file::File has $line_count lines (approaching the limit of ${LIMIT}). ${hint}"
    WARNINGS+=("$file ($line_count lines)")
  fi
}

while IFS= read -r -d '' file; do
  is_exempt "$file" && continue
  [ -f "$file" ] || continue
  if [ "$LIST_ONLY" = "1" ]; then
    echo "$file"
    CHECKED=$((CHECKED + 1))
    continue
  fi
  # A workflow's remedy is different from a script's, so the annotation says
  # which one applies instead of offering generic advice.
  case "$file" in
    .github/workflows/*)
      check_file "$file" "Move jobs into a reusable workflow (uses: ./.github/workflows/...) or inline scripts into scripts/."
      ;;
    *)
      check_file "$file"
      ;;
  esac
done < <(git ls-files -z | grep -zE "\.(${EXTENSIONS})\$")

# A gate that examined nothing exits 0 and reads exactly like a clean tree
# (RC-16). If the listing came back empty, something is wrong with this script
# or with the checkout, and that has to be louder than silence.
if [ "$CHECKED" -eq 0 ]; then
  echo "::error title=check-file-line-limits::no files matched (.${EXTENSIONS//|/, .}); this check verified nothing" >&2
  exit 2
fi

[ "$LIST_ONLY" = "1" ] && exit 0

echo ""
echo "Checked $CHECKED tracked files against a ${LIMIT}-line limit (warning at ${WARN_THRESHOLD})."

if [ "${#WARNINGS[@]}" -gt 0 ]; then
  echo ""
  echo "Approaching the limit:"
  printf '  %s\n' "${WARNINGS[@]}"
fi

if [ "${#FAILURES[@]}" -gt 0 ]; then
  echo ""
  echo "Over the limit:"
  printf '  %s\n' "${FAILURES[@]}"
  echo ""
  echo "A file this size stops being reviewed as a whole, and a fix applied to"
  echo "one part of it stops reaching the others - that is how release.yml grew"
  echo "ten copies of the same job with different bugs in them (issue #115)."
  echo ""
  echo "Reproduce locally:"
  echo "  bash scripts/ci/check-file-line-limits.sh"
  exit 1
fi

echo "All checked files are within the limit."
