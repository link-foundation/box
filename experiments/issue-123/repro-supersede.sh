#!/usr/bin/env bash
# Reproduce: check-pipeline-status.sh excuses a timeout cancellation as a
# "superseded run" for a job whose concurrency group declares
# cancel-in-progress: false, i.e. for a job that cannot be superseded.
#
# Usage: bash repro-supersede.sh /path/to/template/scripts/check-pipeline-status.sh
set -euo pipefail
gate="${1:?path to check-pipeline-status.sh}"

# A job that timed out. In the template's release.yml every job on main has
# cancel-in-progress false (literal false, or `github.ref != 'refs/heads/main'`
# which evaluates to false on main), so a supersede cannot cancel it.
export NEEDS_JSON='{"build":{"result":"success"},"measure":{"result":"cancelled"}}'
export IS_MAIN=true
export MAIN_BRANCH=main
export BRANCH_REF=main
export RUN_SHA=1111111111111111111111111111111111111111

echo "### Case A: this run is still the head of main"
export BRANCH_HEAD_SHA=1111111111111111111111111111111111111111
set +e
bash "$gate"
echo "exit=$?"
set -e

echo
echo "### Case B: a later commit landed on main while the job was timing out"
export BRANCH_HEAD_SHA=2222222222222222222222222222222222222222
set +e
bash "$gate"
echo "exit=$?"
set -e
