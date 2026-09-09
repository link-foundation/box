#!/usr/bin/env bash
#
# reproduce-issue121-workflow-trigger-gap.sh — the gates whose own files
# cannot start them.
#
# Issue #121. A check that cannot fail is the defect class this branch is
# about, and there is a quieter way to build one than writing a broken
# assertion: give the workflow a `paths:` filter that does not match the files
# the workflow reads. Everything then looks right — the job exists, the gate
# works, its fixtures pass — and a pull request that breaks exactly what the
# gate was written for never starts it.
#
# Two halves of the same question, both measured here:
#
#   1. the files a gate DISCOVERS. `scripts.yml` runs check-mjs-syntax.sh,
#      whose discovery is `git ls-files '*.mjs' '*.js'`, under a filter of
#      '**.sh', '.github/workflows/**', 'ubuntu/**' and 'tests/**'. No .mjs
#      path matches any of those four.
#
#   2. the gate SCRIPT itself. Editing scripts/ci/check-timeout-budgets.mjs
#      cannot start `workflows.yml`, the only workflow that runs it, for the
#      same reason.
#
# Parts 1 and 2 replay the patterns as they stood before the fix, so the
# measurement stays reproducible after it. Part 3 asks the same question of the
# tree as it is now, through scripts/ci/check-workflow-path-coverage.mjs, and
# exits non-zero if the answer has regressed — this file is both the record of
# the gap and a check that it stays closed.
#
# Usage: bash experiments/reproduce-issue121-workflow-trigger-gap.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# Parts 1 and 2 in one python3 program: the filter semantics are the same for
# both, and a per-path subprocess over 200 files is slower than the whole rest
# of this suite put together.
python3 - <<'PYTHON'
import re
import subprocess


# GitHub's filter syntax, as the workflow parser implements it: `*` does not
# cross a slash, `**` does, `?` is one non-slash character, and the pattern is
# matched against the whole path from the repository root.
def to_regex(pattern):
    out = ""
    i = 0
    while i < len(pattern):
        if pattern[i] == "*":
            if pattern[i:i + 2] == "**":
                out += ".*"
                i += 2
                continue
            out += "[^/]*"
            i += 1
            continue
        if pattern[i] == "?":
            out += "[^/]"
            i += 1
            continue
        out += re.escape(pattern[i])
        i += 1
    return re.compile("^" + out + "$")


def tracked(*globs):
    out = subprocess.run(
        ["git", "ls-files", "--"] + list(globs),
        capture_output=True, text=True, check=True,
    ).stdout.splitlines()
    return [p for p in out if p and not p.startswith("dev/log/")]


# The four patterns scripts.yml carried when the JavaScript gate was added.
BEFORE = ["**.sh", ".github/workflows/**", "ubuntu/**", "tests/**"]
before = [to_regex(p) for p in BEFORE]

print("=== Part 1: scripts.yml as it stood, against the files its gates read ===")
print("")
print("  filter: " + " ".join(BEFORE))
print("")

DISCOVERY = [
    ("check-mjs-syntax.sh", ["*.mjs", "*.js"]),
    ("check-awk-portability.sh",
     ["*.sh", "*.bash", "*.mjs", "*.js", "*.py", "*.yml", "*.yaml"]),
    ("check-heredoc-vars.sh", ["*.sh"]),
    ("run-shellcheck.sh", ["*.sh", ".githooks/*"]),
    ("run-shfmt.sh", ["*.sh", ".githooks/*"]),
]

for name, globs in DISCOVERY:
    files = tracked(*globs)
    missed = [f for f in files if not any(r.match(f) for r in before)]
    example = "  (e.g. %s)" % missed[0] if missed else ""
    print("  %-26s %3d discovered, %3d unreachable%s"
          % (name, len(files), len(missed), example))

print("")
print("  A pull request that edits only scripts/language-tops/aggregate.mjs")
print("  changes a file two of those gates read and none of those patterns")
print("  match, so Scripts does not run at all and neither reports anything.")
print("")
print("=== Part 2: the gate scripts, against the workflow that runs them ===")
print("")

# Each workflow's own pull_request filter, as it stood before the fix, against
# a script that workflow is the only place to run. links.yml is not in this
# list because it already named both of its .mjs gates: the convention existed,
# it was just not applied anywhere a check enforced it.
PAIRS = [
    ("workflows.yml",
     [".github/workflows/**", ".github/actions/**", ".github/zizmor.yml"],
     "scripts/ci/check-timeout-budgets.mjs"),
    ("docs.yml",
     ["**.md", "**.sh", ".github/workflows/**", ".github/actions/**"],
     "scripts/ci/check-status-gate-covers-all-jobs.mjs"),
    ("measure-disk-space.yml",
     ["scripts/ubuntu-24-server-install.sh", "scripts/measure-disk-space.sh",
      "scripts/update-readme-sizes.sh", "ubuntu/24.04/common.sh",
      "data/disk-space-measurements.json",
      ".github/workflows/measure-disk-space.yml"],
     "scripts/ci/validate-measurements.py"),
]

for workflow, patterns, script in PAIRS:
    rx = [to_regex(p) for p in patterns]
    verdict = "reruns" if any(r.match(script) for r in rx) else "does NOT rerun"
    print("  %-24s %-14s when %s changes" % (workflow, verdict, script))
PYTHON

echo ""
echo "=== Part 3: what the tree says now ==="
echo ""

GATE="scripts/ci/check-workflow-path-coverage.mjs"
if [ ! -f "$GATE" ]; then
  echo "  $GATE does not exist yet; nothing derives this requirement from the"
  echo "  workflow text, so the gap above can reopen silently."
  exit 1
fi

RC=0
node "$GATE" --verbose || RC=$?
echo ""
if [ "$RC" -eq 0 ]; then
  echo "Closed: every gate's inputs can start the workflow that runs it."
  exit 0
fi

echo "Reproduced again: $GATE exits $RC on this tree — a gate is running under a"
echo "filter its own inputs cannot match. The names are in its annotations above."
exit 1
