#!/usr/bin/env bash
# Issue #82 - sanity check for the release.yml change that tolerates a failing
# Docker Hub login.
#
# This script is a static analysis of .github/workflows/release.yml. It does not
# spin up GitHub Actions; it just enforces the structural invariants that the
# fix relies on.
#
# Invariants checked:
#   1. Every "Log in to Docker Hub" step has `id: dockerhub-login`.
#   2. Every "Log in to Docker Hub" step has `continue-on-error: true`.
#   3. Every "Log in to Docker Hub" step is followed by a
#      "Check Docker Hub login (issue #82)" step that gates on
#      `steps.dockerhub-login.outcome != 'success'`.
#   4. The number of "Log in to Docker Hub" steps equals the number of
#      "Check Docker Hub login" steps (one of each per build job).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF="${ROOT}/.github/workflows/release.yml"

if [ ! -f "$WF" ]; then
  echo "ERR: $WF not found" >&2
  exit 1
fi

read -r LOGIN_COUNT ID_COUNT CHECK_COUNT COND_COUNT < <(
  python3 - "$WF" <<'PY'
import re
import sys

wf = open(sys.argv[1]).read().splitlines()
login_count = sum("name: Log in to Docker Hub" in line for line in wf)
id_count = sum("id: dockerhub-login" in line for line in wf)
check_indices = [
    i for i, line in enumerate(wf)
    if re.search(r'name:\s*"?Check Docker Hub login \(issue #82\)"?', line)
]
cond_count = sum(
    any("steps.dockerhub-login.outcome != 'success'" in line for line in wf[i:i + 4])
    for i in check_indices
)

print(login_count, id_count, len(check_indices), cond_count)
PY
)

printf '%-60s %s\n' "Login steps:" "$LOGIN_COUNT"
printf '%-60s %s\n' "id: dockerhub-login:" "$ID_COUNT"
printf '%-60s %s\n' "Check-login steps:" "$CHECK_COUNT"
printf '%-60s %s\n' "outcome != success guards:" "$COND_COUNT"

fail=0

if [ "$LOGIN_COUNT" -ne "$ID_COUNT" ]; then
  echo "FAIL: every 'Log in to Docker Hub' must have 'id: dockerhub-login'" >&2
  fail=1
fi

if [ "$LOGIN_COUNT" -ne "$CHECK_COUNT" ]; then
  echo "FAIL: every 'Log in to Docker Hub' must have a paired 'Check Docker Hub login' step" >&2
  fail=1
fi

if [ "$LOGIN_COUNT" -ne "$COND_COUNT" ]; then
  echo "FAIL: every check step must guard on steps.dockerhub-login.outcome != 'success'" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

# Spot-check that every login block has continue-on-error within 5 lines.
python3 - "$WF" <<'PY'
import sys
wf = open(sys.argv[1]).read().splitlines()
fail = False
for i, line in enumerate(wf):
    if "name: Log in to Docker Hub" in line:
        window = wf[i:i+6]
        if not any("continue-on-error: true" in w for w in window):
            print(f"FAIL: 'Log in to Docker Hub' at line {i+1} is missing continue-on-error: true within the next 5 lines",
                  file=sys.stderr)
            fail = True
sys.exit(1 if fail else 0)
PY

echo ""
echo "PASS: all 'Log in to Docker Hub' steps are non-blocking and paired with a check step."
