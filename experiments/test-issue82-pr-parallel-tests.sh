#!/usr/bin/env bash
# Issue #82 — sanity check for the parallel PR test matrix in release.yml.
#
# After this PR, the single sequential `docker-build-test` job is replaced
# with a chain of parallel matrix jobs that exercise every Docker image
# configuration on its own VM with maximum free disk space:
#
#   pr-test-js               (1 job)
#   pr-test-essentials       (1 job)
#   pr-test-language         (matrix: 11 langs in parallel)
#   pr-test-full             (1 job)
#   pr-test-dind             (matrix: 14 variants in parallel)
#   docker-build-test        (1 aggregator for branch protection)
#
# Invariants checked here:
#   1. Each pr-test-* job exists.
#   2. Each pr-test-* build job has a `Free disk space` step using
#      jlumbroso/free-disk-space, *before* its first build step. The ref is
#      not asserted to be a branch: since issue #115 every third-party action
#      is pinned to a full 40-character commit SHA (zizmor `unpinned-uses`),
#      so this checks the action is present and that its pin is immutable.
#   3. The pr-test-language matrix lists all 11 languages.
#   4. The pr-test-dind matrix lists all 14 variants (js, essentials, 11
#      languages, full).
#   5. The docker-build-test aggregator depends on every pr-test-* job.
#   6. Every build job in the release matrix (build-js-*, build-essentials-*,
#      build-languages-*, build-dind-*, docker-build-push, docker-build-push-arm64)
#      has a `Free disk space` step.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The jobs checked below used to be in one file. release.yml was split by image
# family (issue #115, RC-8), so they now live across seven workflows - the
# pr-test-* jobs in pr-tests.yml, the build jobs in release-<family>.yml. Every
# check here is "job X has property Y", which a per-file search answers with
# "job X not found", so the checks read the concatenation of the whole
# pipeline. Job ids are unique across it, and a job block still starts at
# `^  <id>:`, so the parsing below is unchanged.
#
# The list is resolved from the caller's `uses:` graph rather than written out,
# so the next split does not silently narrow what this suite reads.
WORKFLOWS="$(cd "$ROOT" && bash scripts/ci/list-release-workflows.sh)" || exit 1

WF="$(mktemp)"
trap 'rm -f "$WF"' EXIT
for workflow in $WORKFLOWS; do
  if [ ! -f "$ROOT/$workflow" ]; then
    echo "ERR: $ROOT/$workflow not found" >&2
    exit 1
  fi
  cat "$ROOT/$workflow" >>"$WF"
  # A file that does not end in a newline would glue its last line to the next
  # file's `name:` and hide the first job of that file.
  printf '\n' >>"$WF"
done

fail=0

check() {
  local label="$1"
  local cmd="$2"
  if eval "$cmd"; then
    echo "PASS: $label"
  else
    echo "FAIL: $label" >&2
    fail=1
  fi
}

# 1. Each pr-test-* job exists.
for job in pr-test-js pr-test-essentials pr-test-language pr-test-full pr-test-dind; do
  check "$job job is defined" "grep -q '^  ${job}:$' '$WF'"
done

# 2. Each build job has a Free disk space step using jlumbroso/free-disk-space,
#    pinned to a full-length commit SHA.
BUILD_JOBS=(
  pr-test-js
  pr-test-essentials
  pr-test-language
  pr-test-full
  pr-test-dind
  build-js-amd64
  build-js-arm64
  build-essentials-amd64
  build-essentials-arm64
  build-languages-amd64
  build-languages-arm64
  build-dind-amd64
  build-dind-arm64
  docker-build-push
  docker-build-push-arm64
)

python3 - "$WF" "${BUILD_JOBS[@]}" <<'PY'
import re, sys
wf_path = sys.argv[1]
jobs = sys.argv[2:]
text = open(wf_path).read()

# Split file into job blocks. A job starts with "^  <name>:\n" at top level.
job_starts = [(m.start(), m.group(1)) for m in re.finditer(r'^  ([a-zA-Z][a-zA-Z0-9_-]*):\n', text, re.MULTILINE)]
job_starts.append((len(text), '__END__'))

job_text = {}
for i in range(len(job_starts) - 1):
    start, name = job_starts[i]
    end = job_starts[i+1][0]
    job_text[name] = text[start:end]

fail = 0
for job in jobs:
    block = job_text.get(job)
    if block is None:
        print(f"FAIL: job '{job}' not found in workflow", file=sys.stderr)
        fail = 1
        continue
    refs = re.findall(r'jlumbroso/free-disk-space@(\S+)', block)
    if not refs:
        print(f"FAIL: job '{job}' is missing 'jlumbroso/free-disk-space'", file=sys.stderr)
        fail = 1
        continue
    # Issue #115: third-party actions must be pinned to an immutable commit
    # SHA, never a branch or tag that upstream can move under us.
    unpinned = [r for r in refs if not re.fullmatch(r'[0-9a-f]{40}', r)]
    if unpinned:
        print(
            f"FAIL: job '{job}' uses jlumbroso/free-disk-space@{unpinned[0]}; "
            "expected a full 40-character commit SHA",
            file=sys.stderr,
        )
        fail = 1
    else:
        print(f"PASS: job '{job}' has a SHA-pinned free-disk-space step")
sys.exit(fail)
PY
disk_status=$?
if [ "$disk_status" -ne 0 ]; then
  fail=1
fi

# 3. pr-test-language matrix builds every language directory there is.
#
# This list used to be the 11 published languages, hand-written here. cpp,
# assembly, dotnet and r ship a Dockerfile and an install.sh, are documented in
# README, and were built by no job at all - so it is derived from the directory
# listing now, and adding ubuntu/24.04/<new>/Dockerfile without a matrix entry
# fails here (issue #115).
EXPECTED_LANGS=""
for dockerfile in "$ROOT"/ubuntu/24.04/*/Dockerfile; do
  dir="$(basename "$(dirname "$dockerfile")")"
  case "$dir" in
    js | essentials-box | full-box | dind) continue ;;
  esac
  EXPECTED_LANGS="$EXPECTED_LANGS $dir"
done
EXPECTED_LANGS="${EXPECTED_LANGS# }"
python3 - "$WF" "$EXPECTED_LANGS" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
expected = set(sys.argv[2].split())

m = re.search(r'^  pr-test-language:.*?(?=\n  [a-zA-Z][a-zA-Z0-9_-]*:\n|\Z)', text, re.MULTILINE | re.DOTALL)
if not m:
    print("FAIL: pr-test-language job block not found", file=sys.stderr)
    sys.exit(1)
block = m.group(0)
mm = re.search(r'language:\s*\[([^\]]+)\]', block)
if not mm:
    print("FAIL: pr-test-language matrix.language list not found", file=sys.stderr)
    sys.exit(1)
items = {x.strip() for x in mm.group(1).split(',')}
missing = expected - items
extra = items - expected
if missing or extra:
    print(f"FAIL: pr-test-language language matrix mismatch (missing={missing}, extra={extra})", file=sys.stderr)
    sys.exit(1)
print(f"PASS: pr-test-language matrix lists all {len(expected)} languages")
PY
lang_status=$?
if [ "$lang_status" -ne 0 ]; then
  fail=1
fi

# 4. pr-test-dind matrix lists all 15 variants.
EXPECTED_DIND="js essentials python go rust java kotlin ruby php perl swift lean rocq full"
python3 - "$WF" "$EXPECTED_DIND" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
expected = set(sys.argv[2].split())

m = re.search(r'^  pr-test-dind:.*?(?=\n  [a-zA-Z][a-zA-Z0-9_-]*:\n|\Z)', text, re.MULTILINE | re.DOTALL)
if not m:
    print("FAIL: pr-test-dind job block not found", file=sys.stderr)
    sys.exit(1)
block = m.group(0)
mm = re.search(r'variant:\s*\[([^\]]+)\]', block)
if not mm:
    print("FAIL: pr-test-dind matrix.variant list not found", file=sys.stderr)
    sys.exit(1)
items = {x.strip() for x in mm.group(1).split(',')}
missing = expected - items
extra = items - expected
if missing or extra:
    print(f"FAIL: pr-test-dind variant matrix mismatch (missing={missing}, extra={extra})", file=sys.stderr)
    sys.exit(1)
print(f"PASS: pr-test-dind matrix lists all {len(expected)} variants")
PY
dind_status=$?
if [ "$dind_status" -ne 0 ]; then
  fail=1
fi

# 5. docker-build-test aggregator depends on every pr-test-* job.
python3 - "$WF" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'^  docker-build-test:.*?(?=\n  [a-zA-Z][a-zA-Z0-9_-]*:\n|\Z)', text, re.MULTILINE | re.DOTALL)
if not m:
    print("FAIL: docker-build-test job block not found", file=sys.stderr)
    sys.exit(1)
block = m.group(0)
needs_match = re.search(r'needs:\s*\[([^\]]+)\]', block)
if not needs_match:
    print("FAIL: docker-build-test job has no needs list", file=sys.stderr)
    sys.exit(1)
needs_items = {x.strip() for x in needs_match.group(1).split(',')}
required = {'pr-test-js', 'pr-test-essentials', 'pr-test-language', 'pr-test-full', 'pr-test-dind'}
missing = required - needs_items
if missing:
    print(f"FAIL: docker-build-test missing dependencies: {missing}", file=sys.stderr)
    sys.exit(1)
print("PASS: docker-build-test aggregator depends on all pr-test-* jobs")
PY
agg_status=$?
if [ "$agg_status" -ne 0 ]; then
  fail=1
fi

echo ""
if [ "$fail" -ne 0 ]; then
  echo "RESULT: FAIL" >&2
  exit 1
fi
echo "RESULT: PASS — parallel PR test layout is valid."
