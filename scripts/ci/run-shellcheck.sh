#!/usr/bin/env bash
# run-shellcheck.sh
#
# Runs shellcheck over every tracked *.sh file in the repository.
#
# Why this exists (issue #115): actionlint's bundled shellcheck only sees the
# `run:` blocks inside .github/workflows/**. The 75 tracked *.sh files that
# build and measure the boxes had no linter at all, so `for x in $(ls ...)`,
# `trap "rm -rf $DIR"` and `local x=$(cmd)` were free to accumulate. Running
# the linter only on a developer's laptop is the same as not running it.
#
# Discovery, not a list: the file set comes from git, so a script added in a
# later pull request is linted from the moment it lands. Untracked-but-not-
# ignored scripts are included too, so a new script is linted before it is
# committed rather than first failing in CI. dev/log/ is excluded because it
# holds verbatim copies of other projects' files, collected as issue evidence;
# they are not ours to fix.
#
# Threshold: --severity=warning, matching the bar actionlint applies to
# workflow `run:` blocks so identical shell does not pass in one place and fail
# in the other. Findings at `info` and below are dominated by SC1091 (sourcing
# a path that only exists inside the built image) and SC2016 (single-quoted `$`
# in the heredocs that generate in-image scripts); both are deliberate.
#
# Usage:
#   bash scripts/ci/run-shellcheck.sh              # lint the whole repository
#   bash scripts/ci/run-shellcheck.sh --list       # print the files, lint none
#   bash scripts/ci/run-shellcheck.sh path/to.sh   # lint only these files
#
# Environment:
#   SHELLCHECK_SEVERITY  Severity floor (default: warning)
#   SHELLCHECK_IMAGE     Docker image used when shellcheck is not on PATH
#   BOX_VERBOSE=1        Trace every command this script runs
#
# Exit code 0 = no findings at or above the severity floor.

set -euo pipefail

if [ "${BOX_VERBOSE:-0}" = "1" ]; then
  set -x
fi

SEVERITY="${SHELLCHECK_SEVERITY:-warning}"
IMAGE="${SHELLCHECK_IMAGE:-koalaman/shellcheck:stable}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

cd "$REPO_ROOT"

# collect_files — every tracked or newly added *.sh outside the vendored
# evidence tree. --others --exclude-standard adds untracked files that .gitignore
# does not cover; --deduplicate keeps a staged-and-modified file from appearing
# twice.
collect_files() {
  git ls-files -z --cached --others --exclude-standard --deduplicate '*.sh' \
    | tr '\0' '\n' | grep -v '^dev/log/' | sort -u || true
}

FILES=()
LIST_ONLY=0

if [ "$#" -gt 0 ] && [ "$1" = "--list" ]; then
  LIST_ONLY=1
  shift
fi

if [ "$#" -gt 0 ]; then
  FILES=("$@")
else
  while IFS= read -r f; do
    [ -n "$f" ] && FILES+=("$f")
  done < <(collect_files)
fi

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "==> No shell scripts to check"
  exit 0
fi

if [ "$LIST_ONLY" = "1" ]; then
  printf '%s\n' "${FILES[@]}"
  exit 0
fi

echo "==> shellcheck --severity=${SEVERITY} over ${#FILES[@]} tracked shell script(s)"

# Prefer a locally installed shellcheck; fall back to the pinned image so the
# command is reproducible on a machine that has only Docker.
if command -v shellcheck >/dev/null 2>&1; then
  RUNNER=(shellcheck)
elif command -v docker >/dev/null 2>&1; then
  echo "==> shellcheck not on PATH; using ${IMAGE}"
  # The container only sees what is mounted into it. Mounting the repository
  # alone is enough for the discovered set, but an explicit argument may point
  # outside it (a fixture under /tmp, for instance) - and shellcheck then
  # reports "openBinaryFile: does not exist" rather than the file's findings,
  # which reads exactly like a clean run. Mount each out-of-tree parent too.
  MOUNTS=()
  for f in "${FILES[@]}"; do
    abs="$(cd "$(dirname "$f")" && pwd)"
    case "$abs/" in
      "$REPO_ROOT"/*) continue ;;
    esac
    printf '%s\n' "${MOUNTS[@]+"${MOUNTS[@]}"}" | grep -qx -- "-v $abs:$abs" && continue
    MOUNTS+=(-v "$abs:$abs")
  done
  RUNNER=(docker run --rm -v "$REPO_ROOT:/mnt" "${MOUNTS[@]+"${MOUNTS[@]}"}" -w /mnt "$IMAGE")
else
  echo "::error title=shellcheck unavailable::Neither shellcheck nor docker is available, so the shell scripts were not linted. Install shellcheck (apt-get install shellcheck) or Docker."
  exit 1
fi

# --format=gcc emits file:line:col, which GitHub renders as a clickable
# location and which the fixture suite can assert on.
if OUTPUT="$("${RUNNER[@]}" --severity="$SEVERITY" --format=gcc "${FILES[@]}" 2>&1)"; then
  echo "==> No shellcheck findings at or above severity '${SEVERITY}'"
  exit 0
fi

echo "$OUTPUT"

# Turn each finding into a GitHub annotation so it appears on the diff.
while IFS= read -r line; do
  case "$line" in
    *:*:*:\ *) ;;
    *) continue ;;
  esac
  file="${line%%:*}"
  rest="${line#*:}"
  lineno="${rest%%:*}"
  rest="${rest#*:}"
  col="${rest%%:*}"
  message="${rest#*:}"
  echo "::error file=${file},line=${lineno},col=${col}::${message# }"
done <<< "$OUTPUT"

COUNT="$(printf '%s\n' "$OUTPUT" | grep -c ':[0-9]*:[0-9]*: \(warning\|error\|note\|style\|info\):' || true)"
echo ""
if [ "$COUNT" -eq 0 ]; then
  # The linter exited non-zero without producing a single parseable finding:
  # it could not read a file, or the invocation itself is wrong. Reporting
  # (Do not begin this comment with the linter's name - a comment whose first
  # word is that name is parsed as a `shellcheck disable=` directive.)
  # "0 findings" and failing would be indistinguishable from a clean run, which
  # is the kind of false signal this gate exists to remove.
  echo "::error title=shellcheck could not run::shellcheck exited non-zero without reporting any finding. Its output is above; the most likely causes are an unreadable path or a bad invocation."
  exit 2
fi
echo "==> ${COUNT} shellcheck finding(s) at or above severity '${SEVERITY}'"
echo "==> Reproduce locally with: bash scripts/ci/run-shellcheck.sh"
exit 1
