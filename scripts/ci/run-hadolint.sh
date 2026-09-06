#!/usr/bin/env bash
# run-hadolint.sh
#
# Runs hadolint over every tracked Dockerfile in the repository.
#
# Why this exists (issue #115): this repository *is* a set of Dockerfiles - 23
# of them - and no linter had ever read one. Workflows are read by actionlint
# and every *.sh by shellcheck; the Dockerfiles were the one body of source with
# no check at all. `apt install` instead of `apt-get install` was sitting in
# ubuntu/24.04/js/Dockerfile and in nine install scripts, printing
#
#   WARNING: apt does not have a stable CLI interface. Use with caution in scripts.
#
# into every box build - a warning nobody was looking for because nothing
# collected it.
#
# Discovery, not a list: the file set comes from git, so a Dockerfile added in a
# later pull request is linted from the moment it lands. dev/log/ is excluded
# because it holds verbatim copies of other projects' files, collected as issue
# evidence; they are not ours to fix.
#
# Threshold and the one ignored rule are in .hadolint.yaml, next to the reason.
#
# Usage:
#   bash scripts/ci/run-hadolint.sh              # lint the whole repository
#   bash scripts/ci/run-hadolint.sh --list       # print the files, lint none
#   bash scripts/ci/run-hadolint.sh path/to/Dockerfile
#
# Environment:
#   HADOLINT_IMAGE   Docker image used when hadolint is not on PATH
#   BOX_VERBOSE=1    Trace every command this script runs
#
# Exit code 0 = no findings at or above the configured failure threshold.

set -euo pipefail

if [ "${BOX_VERBOSE:-0}" = "1" ]; then
  set -x
fi

IMAGE="${HADOLINT_IMAGE:-hadolint/hadolint:v2.14.0}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

cd "$REPO_ROOT"

# collect_files — every tracked or newly added Dockerfile outside the vendored
# evidence tree. The glob covers `Dockerfile`, `Dockerfile.stage` and
# `*.Dockerfile`, which are all three shapes present here.
collect_files() {
  git ls-files -z --cached --others --exclude-standard --deduplicate \
    'Dockerfile' '*/Dockerfile' 'Dockerfile.*' '*/Dockerfile.*' '*.Dockerfile' \
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
  echo "::error title=hadolint::No Dockerfiles found - the discovery glob is wrong."
  exit 1
fi

if [ "$LIST_ONLY" = "1" ]; then
  printf '%s\n' "${FILES[@]}"
  exit 0
fi

# hadolint reads one file per invocation and reports it as `-` when fed on
# stdin, so the loop supplies the real path in the annotation itself.
run_hadolint() {
  if command -v hadolint >/dev/null 2>&1; then
    hadolint --no-color --config .hadolint.yaml -
  else
    docker run --rm -i -v "$REPO_ROOT/.hadolint.yaml:/.hadolint.yaml:ro" \
      "$IMAGE" hadolint --no-color --config /.hadolint.yaml -
  fi
}

if command -v hadolint >/dev/null 2>&1; then
  echo "==> hadolint $(hadolint --version 2>/dev/null | head -n1)"
else
  echo "==> hadolint not on PATH; using $IMAGE"
fi

echo "==> Checking ${#FILES[@]} Dockerfile(s)"

FINDINGS=0
FAILURES=0
for file in "${FILES[@]}"; do
  set +e
  out="$(run_hadolint <"$file")"
  status=$?
  set -e
  [ "$status" -eq 0 ] || FAILURES=$((FAILURES + 1))
  [ -n "$out" ] || continue
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # `-:12 DL3027 warning: ...` -> `::warning file=path,line=12::DL3027 ...`
    lineno="${line#-:}"
    lineno="${lineno%% *}"
    rest="${line#*: }"
    code="${line#* }"
    code="${code%% *}"
    level="${line#*"$code" }"
    level="${level%%:*}"
    # Only what hadolint itself would fail on becomes an error annotation; the
    # rest is advisory, so a style suggestion cannot be mistaken for a defect.
    case "$level" in
      error | warning) gh_level="error" ;;
      *) gh_level="notice" ;;
    esac
    echo "::${gh_level} file=${file},line=${lineno}::${code} ${level}: ${rest}"
    FINDINGS=$((FINDINGS + 1))
  done <<<"$out"
done

if [ "$FAILURES" -gt 0 ]; then
  echo
  echo "==> hadolint failed on $FAILURES file(s) ($FINDINGS finding(s) reported in total)"
  echo "==> Reproduce locally with: bash scripts/ci/run-hadolint.sh"
  exit 1
fi

if [ "$FINDINGS" -gt 0 ]; then
  echo
  echo "==> $FINDINGS advisory finding(s) below the failure threshold; nothing to fail on"
  exit 0
fi

echo "==> No hadolint findings at or above the configured threshold"
