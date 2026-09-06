#!/usr/bin/env bash
# run-experiments.sh - Run the repository's experiment/regression suites.
#
# Usage:
#   bash scripts/ci/run-experiments.sh [--list] [--verbose]
#
# Why this exists (issue #115, RC-9). The repository had 27 suites under
# experiments/ and the workflows referenced 5 of them. The other 22 ran only
# when a developer remembered to run them by hand — which is to say, they were
# not checks. Two of them (test-issue90, test-issue92) had been *crashing* on
# any machine without a UTF-8 locale, and nothing noticed, because nothing ran
# them.
#
# So this discovers suites rather than listing them: a new experiments/*.sh is
# picked up automatically, and the only way to not run one is to name it in
# SKIP_SUITES below, with a reason.
#
# Environment:
#   SUITE_TIMEOUT   per-suite timeout in seconds, default 300
#   BOX_VERBOSE     set to 1 to echo each suite's full output, default off
#                   (failing suites always have their output printed)

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

SUITE_TIMEOUT="${SUITE_TIMEOUT:-300}"
BOX_VERBOSE="${BOX_VERBOSE:-0}"
LIST_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --list)
      LIST_ONLY=1
      shift
      ;;
    -v | --verbose)
      BOX_VERBOSE=1
      shift
      ;;
    -h | --help)
      sed -n '2,22p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "run-experiments.sh: unknown option $1" >&2
      exit 2
      ;;
  esac
done

# Suites excluded from the default run, each with the reason. Keep this list
# short and justified; "it is slow" is not a reason to stop running a check.
#
# The keys are quoted, and that is not a style choice. An unquoted subscript is
# an arithmetic expression to any tool that parses one, and shfmt formats it as
# such: `[node-lts-integration-test.sh]` came back from the formatter as
# `[node - lts - integration - test.sh]`. Bash does not evaluate subscripts of
# an associative array, so the key silently became a different string, all
# three entries stopped matching, and a run that should have skipped three
# suites ran them and reported two failures instead. Nothing complained. The
# assertion below is what turns that back into an error.
declare -A SKIP_SUITES=(
  ['node-lts-integration-test.sh']="needs network: resolves the live Node LTS feed (covered by the version-policy CI tier)"
  ['rust-refresh-layer-test.sh']="needs docker: builds layers to measure image size"
  ['verify-full-box-tooling.sh']="needs docker and a pulled full-box image (tens of GB); manual probe behind scripts/ci/test-box.sh"
)

# Where the skip names come from, which is the repository's suite directory
# even when EXPERIMENTS_DIR points somewhere else for this runner's own tests.
SKIP_ROOT="experiments"

# A skip entry that names nothing is indistinguishable from no entry at all:
# the suite runs, and whoever wrote the exclusion never learns it stopped
# applying. Renaming a suite and forgetting the list has the same shape as the
# formatter defect above, so both are caught here.
for skipped_name in "${!SKIP_SUITES[@]}"; do
  if [ ! -f "$SKIP_ROOT/$skipped_name" ]; then
    echo "::error title=run-experiments::SKIP_SUITES names '$skipped_name', which does not exist under $SKIP_ROOT/. Either the suite was renamed or the subscript was rewritten; an entry that matches nothing silently stops skipping." >&2
    exit 2
  fi
done

# Overridable so this runner's own regression suite can drive it against
# fixtures. The thing that runs every other check had no check of its own.
EXPERIMENTS_DIR="${EXPERIMENTS_DIR:-experiments}"

mapfile -t SUITES < <(find "$EXPERIMENTS_DIR" -maxdepth 1 -name '*.sh' -type f | sort)

if [ "${#SUITES[@]}" -eq 0 ]; then
  echo "::error::No suites found under $EXPERIMENTS_DIR/ - the discovery glob is wrong."
  exit 1
fi

if [ "$LIST_ONLY" = "1" ]; then
  for suite in "${SUITES[@]}"; do
    base="$(basename "$suite")"
    if [ -n "${SKIP_SUITES[$base]:-}" ]; then
      printf 'SKIP  %-46s %s\n' "$base" "${SKIP_SUITES[$base]}"
    else
      printf 'RUN   %s\n' "$base"
    fi
  done
  exit 0
fi

LOG_DIR="${LOG_DIR:-/tmp/experiment-logs}"
mkdir -p "$LOG_DIR"

passed=()
failed=()
skipped=()

for suite in "${SUITES[@]}"; do
  base="$(basename "$suite")"
  reason="${SKIP_SUITES[$base]:-}"
  if [ -n "$reason" ]; then
    echo "==> SKIP $base ($reason)"
    skipped+=("$base")
    continue
  fi

  log="$LOG_DIR/${base%.sh}.log"
  echo "==> RUN  $base"
  if timeout "$SUITE_TIMEOUT" bash "$suite" >"$log" 2>&1; then
    passed+=("$base")
    [ "$BOX_VERBOSE" = "1" ] && sed 's/^/    /' "$log"
  else
    status=$?
    failed+=("$base")
    echo "::group::$base failed (exit $status)"
    sed 's/^/    /' "$log"
    echo "::endgroup::"
    if [ "$status" -eq 124 ]; then
      echo "::error file=$suite::Suite timed out after ${SUITE_TIMEOUT}s"
    else
      echo "::error file=$suite::Suite failed with exit status $status"
    fi
  fi
done

echo ""
echo "================ experiment suites ================"
echo "passed:  ${#passed[@]}"
echo "failed:  ${#failed[@]}"
echo "skipped: ${#skipped[@]}"
if [ "${#failed[@]}" -gt 0 ]; then
  echo ""
  echo "Failing suites (full output above, logs in $LOG_DIR):"
  printf '  %s\n' "${failed[@]}"
  exit 1
fi
echo ""
echo "All ${#passed[@]} suites passed."
