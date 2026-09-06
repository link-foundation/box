#!/usr/bin/env bash
# Issue #82 - a failing Docker Hub login must never take a release down with it.
#
# This is a static analysis of the release pipeline. It does not spin up GitHub
# Actions; it enforces the structural invariants the fix relies on.
#
# Invariants checked, for every "Log in to Docker Hub" step in the pipeline:
#   1. It carries `id: dockerhub-login`.
#   2. It carries `continue-on-error: true`.
#   3. The job it lives in also has a "Check Docker Hub login (issue #82)" step
#      that gates on `steps.dockerhub-login.outcome != 'success'`.
#   4. There is exactly one login step and one check step per job.
#
# Two changes since the original (issue #117):
#
#   * It reads every workflow in the release graph, not release.yml alone. The
#     login steps moved into .github/workflows/release-<family>.yml when
#     release.yml was split (issue #115, RC-8), and this suite kept passing
#     against the file they had left: 0 logins, 0 checks, 0 != 0, green. An
#     assertion that finds nothing and is satisfied is the false negative
#     issue #115 is about, so the count is now asserted to be plausible before
#     any comparison is believed.
#
#   * It follows `uses: ./.github/actions/dockerhub-login` as a login. The 15
#     copies of the login block became one composite action; the invariants are
#     about the calling step, which still carries the id, the tolerance and the
#     paired check.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# The minimum number of login steps a real release pipeline has: one per image
# family (js, essentials, languages, full, dind) plus preflight. Deliberately a
# floor and not an equality - adding a family must not fail this suite, but
# losing every login step must.
MIN_LOGINS="${MIN_LOGINS:-6}"

mapfile -t WORKFLOWS < <(bash scripts/ci/list-release-workflows.sh)

if [ "${#WORKFLOWS[@]}" -eq 0 ]; then
  echo "FAIL: no release workflows found; this suite would be checking nothing" >&2
  exit 1
fi

echo "Workflows in the release graph: ${#WORKFLOWS[@]}"
printf '  %s\n' "${WORKFLOWS[@]}"
echo ""

python3 - "$MIN_LOGINS" "${WORKFLOWS[@]}" <<'PY'
import re
import sys

min_logins = int(sys.argv[1])
paths = sys.argv[2:]

STEP = re.compile(r'^      - ')
JOB = re.compile(r'^  ([A-Za-z0-9_.-]+):\s*$')
NAME = re.compile(r'^      - name:\s*"?(.*?)"?\s*$')
CHECK_NAME = re.compile(r'^Check Docker Hub login \(issue #82\)$')

failures = []
logins = 0
checks = 0


def jobs(lines):
    """Yield (job_id, [(first_line_no, [step lines])]) for one workflow file."""
    job = None
    steps = []
    current = None
    for i, line in enumerate(lines):
        m = JOB.match(line)
        if m:
            if job is not None:
                if current:
                    steps.append(current)
                yield job, steps
            job, steps, current = m.group(1), [], None
            continue
        if job is None:
            continue
        if STEP.match(line):
            if current:
                steps.append(current)
            current = (i + 1, [line])
        elif current is not None:
            if line.strip() and not line.startswith('        ') and not line.startswith('      #'):
                # dedented out of the steps: block
                steps.append(current)
                current = None
            else:
                current[1].append(line)
    if job is not None:
        if current:
            steps.append(current)
        yield job, steps


for path in paths:
    lines = open(path).read().splitlines()
    for job, steps in jobs(lines):
        job_logins, job_checks = [], []
        for lineno, block in steps:
            m = NAME.match(block[0])
            if not m:
                continue
            name = m.group(1)
            body = '\n'.join(block)
            if name.startswith('Log in to Docker Hub'):
                job_logins.append((lineno, name, body))
            elif CHECK_NAME.match(name):
                job_checks.append((lineno, name, body))

        logins += len(job_logins)
        checks += len(job_checks)
        where = f'{path}:{job}'

        for lineno, name, body in job_logins:
            if 'id: dockerhub-login' not in body:
                failures.append(f"{where} line {lineno}: '{name}' has no 'id: dockerhub-login'")
            if 'continue-on-error: true' not in body:
                failures.append(f"{where} line {lineno}: '{name}' is not 'continue-on-error: true'; "
                                f"a refused Docker Hub credential would fail the job")

        if job_logins and not job_checks:
            failures.append(f"{where}: has a Docker Hub login and no "
                            f"'Check Docker Hub login (issue #82)' step, so a failed login is silent")
        if job_checks and not job_logins:
            failures.append(f"{where}: has a login check and no login step to check")
        if len(job_logins) > 1 or len(job_checks) > 1:
            failures.append(f"{where}: expected one login and one check, found "
                            f"{len(job_logins)} and {len(job_checks)}")

        for lineno, name, body in job_checks:
            if "steps.dockerhub-login.outcome != 'success'" not in body:
                failures.append(f"{where} line {lineno}: the check step does not gate on "
                                f"steps.dockerhub-login.outcome != 'success'")

print(f"{'Login steps:':<60} {logins}")
print(f"{'Check Docker Hub login steps:':<60} {checks}")
print("")

if logins < min_logins:
    failures.insert(0, f"only {logins} 'Log in to Docker Hub' steps found across "
                       f"{len(paths)} workflows, expected at least {min_logins}; "
                       f"this suite is checking almost nothing (issue #117)")

for f in failures:
    print(f"FAIL: {f}", file=sys.stderr)

sys.exit(1 if failures else 0)
PY

echo "PASS: every 'Log in to Docker Hub' step is non-blocking, identified, and paired with a check step."
