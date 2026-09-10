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
#   bash scripts/ci/run-hadolint.sh --list-inputs  # the same set, paths only
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

# The annotation level is derived from the threshold, not hardcoded beside it.
# Before issue #121 this script mapped error/warning to ::error and everything
# else to ::notice, while .hadolint.yaml failed at `warning` - so the two agreed
# only by coincidence, and lowering the threshold would have produced a run that
# fails while every annotation on it says "notice". Read the threshold once and
# let it decide both.
THRESHOLD="$(sed -n 's/^failure-threshold:[[:space:]]*\([a-z]*\).*/\1/p' .hadolint.yaml | head -n1)"
THRESHOLD="${THRESHOLD:-info}"

# hadolint's severities, most severe first. A finding at or above the threshold
# is what hadolint exits non-zero on, so it is annotated as an error; anything
# below it is genuinely advisory.
SEVERITIES=(error warning info style)

severity_rank() {
  local want="$1" i
  for i in "${!SEVERITIES[@]}"; do
    if [ "${SEVERITIES[$i]}" = "$want" ]; then
      echo "$i"
      return 0
    fi
  done
  echo 99
}

THRESHOLD_RANK="$(severity_rank "$THRESHOLD")"
if [ "$THRESHOLD_RANK" = "99" ]; then
  echo "::error title=hadolint::.hadolint.yaml sets failure-threshold: $THRESHOLD, which is not one of ${SEVERITIES[*]}."
  exit 1
fi

# collect_files — every tracked or newly added Dockerfile outside the vendored
# evidence tree. The glob covers `Dockerfile`, `Dockerfile.stage` and
# `*.Dockerfile`, which are all three shapes present here.
#
# The `|| true` this function used to end with is gone (issue #123, RC-17).
# `git ls-files … || true` turns a git that could not read the index into an
# empty list, and an empty list here was reported as "the discovery glob is
# wrong" on the check path and as a clean answer on the --list-inputs path.
# git's own stderr is left alone so the reason arrives with the refusal.
collect_files() {
  local listing
  # `exit "${PIPESTATUS[0]}"` rather than pipefail: `tr` must convert the NULs
  # before bash captures the output, because command substitution silently
  # drops NUL bytes - and grep's exit 1 ("selected nothing") is a legitimately
  # empty tree, not an error, while anything above 1 is.
  listing="$(
    git ls-files -z --cached --others --exclude-standard --deduplicate \
      'Dockerfile' '*/Dockerfile' 'Dockerfile.*' '*/Dockerfile.*' '*.Dockerfile' \
      | tr '\0' '\n'
    exit "${PIPESTATUS[0]}"
  )" || return 1
  printf '%s\n' "$listing" | { grep -v '^dev/log/' || [ "$?" = 1 ]; } | sort -u
}

# discover_or_exit - collect_files with its two empty answers told apart, and
# neither of them reported as a clean run. Called unsubshelled it ends the
# script; called inside `$(...)` the status propagates, which is why every
# caller pairs it with `|| exit $?`.
discover_or_exit() {
  local listing
  if ! listing="$(collect_files)"; then
    echo "::error title=hadolint::could not list this repository's Dockerfiles - git ls-files failed and printed the reason above. Nothing was linted; this is not a clean run." >&2
    exit 2
  fi
  if [ -z "$listing" ]; then
    echo "::error title=hadolint::discovery matched no Dockerfile at all. Either the globs are wrong or this is not the repository they were written for; a gate that read nothing must not report a clean tree." >&2
    exit 2
  fi
  printf '%s\n' "$listing"
}

# --list-inputs prints the discovered set and nothing else, one
# repository-relative path per line, exit 0. That is the contract
# scripts/ci/check-workflow-path-coverage.mjs reads to check that a workflow's
# `paths:` filter can actually be matched by the files this gate reads —
# without it, a gate runs under a filter its own inputs never match and the
# job silently never starts (issue #121).
if [ "$#" -gt 0 ] && [ "$1" = "--list-inputs" ]; then
  discover_or_exit
  exit 0
fi

FILES=()
LIST_ONLY=0

if [ "$#" -gt 0 ] && [ "$1" = "--list" ]; then
  LIST_ONLY=1
  shift
fi

if [ "$#" -gt 0 ]; then
  FILES=("$@")
else
  # `$(...)` and not `< <(...)`: discover_or_exit ends the script when it
  # cannot answer, and a process substitution's exit would end only the
  # subshell, leaving this one to carry on with an empty list.
  LISTING="$(discover_or_exit)" || exit $?
  while IFS= read -r f; do
    [ -n "$f" ] && FILES+=("$f")
  done <<<"$LISTING"
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

echo "==> Checking ${#FILES[@]} Dockerfile(s) (failing at severity '$THRESHOLD' and above)"

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
    if [ "$(severity_rank "$level")" -le "$THRESHOLD_RANK" ]; then
      gh_level="error"
    else
      gh_level="notice"
    fi
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
