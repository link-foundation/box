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
    --list)       LIST_ONLY=1; shift ;;
    -v|--verbose) BOX_VERBOSE=1; shift ;;
    -h|--help)    sed -n '2,22p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *)            echo "run-experiments.sh: unknown option $1" >&2; exit 2 ;;
  esac
done

# Suites excluded from the default run, each with the reason. Keep this list
# short and justified; "it is slow" is not a reason to stop running a check.
declare -A SKIP_SUITES=(
  [node-lts-integration-test.sh]="needs network: resolves the live Node LTS feed (covered by the version-policy CI tier)"
  [rust-refresh-layer-test.sh]="needs docker: builds layers to measure image size"
)

mapfile -t SUITES < <(find experiments -maxdepth 1 -name '*.sh' -type f | sort)

if [ "${#SUITES[@]}" -eq 0 ]; then
  echo "::error::No suites found under experiments/ — the discovery glob is wrong."
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

passed=(); failed=(); skipped=()

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
  if timeout "$SUITE_TIMEOUT" bash "$suite" > "$log" 2>&1; then
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
