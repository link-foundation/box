#!/usr/bin/env bash
# Runs inside the container as root; see repro-budget-privileged-child.sh for why.
#
# Rebuilds the shape of the step that overran in run 34366975927:
#
#   run-with-budget-warning.sh 2400 "disk space measurement" \
#     sudo env ... ./scripts/measure-disk-space.sh ... 2>&1 | tee measurement.log
#
#   wrapper (runner)  ->  sudo (real uid runner, effective root)
#                          ->  measure-disk-space.sh (root)
#                               ->  apt-get (root)      <- the survivor
#
# `sudo` keeps the invoking user's real uid, so the wrapper can signal it and
# sudo relays SIGTERM onward. The script it started dies. `apt-get`, a root
# grandchild with real uid 0, does not: it is not sudo's to relay to and not
# the wrapper's to signal. It keeps the step's stdout open, so `tee` never
# reaches EOF and the step runs until the job's timeout-minutes backstop.
set -uo pipefail

WRAPPER=/repo/scripts/ci/run-with-budget-warning.sh
BUDGET="${BUDGET:-3}"
CHILD_LIFETIME="${CHILD_LIFETIME:-120}"
STEP_TIMEOUT="${STEP_TIMEOUT:-25}"

if ! command -v sudo >/dev/null 2>&1; then
  apt-get -qq update >/dev/null 2>&1
  DEBIAN_FRONTEND=noninteractive apt-get -qq install -y sudo >/dev/null 2>&1 \
    || {
      echo "cannot install sudo; the reproduction needs it" >&2
      exit 2
    }
fi

id -u ci >/dev/null 2>&1 || useradd -m -u 1001 ci
echo 'ci ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/ci
chmod 0440 /etc/sudoers.d/ci

# Stands in for apt-get: root, quiet for long stretches, holds stdout.
cat >/downloader.sh <<CHILD
#!/usr/bin/env bash
echo "downloader: uid=\$(id -u) pid=\$\$"
sleep ${CHILD_LIFETIME}
echo "downloader: finished"
CHILD

# Stands in for measure-disk-space.sh: root, runs the downloader as a child.
cat >/measure.sh <<'MEASURE'
#!/usr/bin/env bash
echo "measure: uid=$(id -u) pid=$$"
/downloader.sh
echo "measure: finished"
MEASURE
chmod +x /downloader.sh /measure.sh

run_scenario() {
  local title="$1" sudo_kill="$2"
  echo
  echo "########## ${title}"
  echo "=== step: ${WRAPPER} ${BUDGET} 'repro measurement' sudo /measure.sh 2>&1 | tee /tmp/measurement.log"
  echo "=== BUDGET_SUDO_KILL=${sudo_kill}; the step gets ${STEP_TIMEOUT}s, standing in for timeout-minutes"
  echo

  pkill -f '[d]ownloader.sh' 2>/dev/null || true
  local start elapsed step_status survivors
  start=$(date +%s)
  timeout --foreground "${STEP_TIMEOUT}" \
    su ci -c "BUDGET_SUDO_KILL=${sudo_kill} bash ${WRAPPER} ${BUDGET} 'repro measurement' sudo /measure.sh 2>&1 | tee /tmp/measurement.log"
  step_status=$?
  elapsed=$(($(date +%s) - start))

  echo
  echo "=== step ended after ${elapsed}s with status ${step_status}"
  echo "=== survivors"
  ps -eo pid,ppid,user,args | grep -E '[d]ownloader.sh|[m]easure.sh|[t]ee /tmp' || echo "(none)"
  survivors=$(ps -eo args | grep -c '[d]ownloader.sh' || true)
  pkill -f '[d]ownloader.sh' 2>/dev/null || true

  echo
  SCENARIO_SURVIVORS="${survivors}"
  SCENARIO_HUNG=no
  [ "${step_status}" -eq 124 ] && SCENARIO_HUNG=yes
  SCENARIO_REPORTED_SURVIVORS=no
  grep -q 'left processes running' /tmp/measurement.log && SCENARIO_REPORTED_SURVIVORS=yes
  echo "hung=${SCENARIO_HUNG} survivors=${SCENARIO_SURVIVORS} reported_survivors=${SCENARIO_REPORTED_SURVIVORS}"
}

rc=0
check() {
  local what="$1" got="$2" want="$3"
  if [ "${got}" = "${want}" ]; then
    echo "  ok   ${what}: ${got}"
  else
    echo "  FAIL ${what}: got ${got}, want ${want}"
    rc=1
  fi
}

if [ "${EXPECT:-fixed}" = "defect" ]; then
  # The version of the wrapper this branch replaces.
  run_scenario "the wrapper as it shipped in 2.9.0" 1
  echo "=== expected: the defect"
  check "step hit the timeout-minutes backstop" "${SCENARIO_HUNG}" yes
  check "root grandchild outlived the wrapper" "$([ "${SCENARIO_SURVIVORS}" -gt 0 ] && echo yes || echo no)" yes
else
  run_scenario "with sudo available, as on a GitHub runner" 1
  echo "=== expected: the budget is enforced"
  check "step did not hit the backstop" "${SCENARIO_HUNG}" no
  check "no survivors" "${SCENARIO_SURVIVORS}" 0

  run_scenario "with no privilege to borrow (BUDGET_SUDO_KILL=0)" 0
  echo "=== expected: survivors it cannot kill, reported, and still no hang"
  check "step did not hit the backstop" "${SCENARIO_HUNG}" no
  check "survivors reported" "${SCENARIO_REPORTED_SURVIVORS}" yes
fi

echo
if [ "${rc}" -eq 0 ]; then
  echo "PASS"
else
  echo "FAIL"
fi
exit "${rc}"
