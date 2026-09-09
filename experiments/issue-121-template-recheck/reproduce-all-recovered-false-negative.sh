#!/usr/bin/env bash
#
# Reproduce: the reference template's scripts/recheck-broken-links.mjs reports
# `all_recovered=true` for a lychee report that also contains a link a host
# answered 404 for, and links.yml skips its "Fail if broken links were found"
# step on exactly that output - so a real broken link leaves the run green.
#
# Run:  bash experiments/issue-121-template-recheck/reproduce-all-recovered-false-negative.sh
#
# Exit 0 means the defect reproduced and the upstream report still stands;
# exit 1 means it did not, and the report can be closed against the checkout in
# dev/log/. It is a demonstration of somebody else's code, not an assertion
# about this repository, which is why it sits in a subdirectory: scripts/ci/
# run-experiments.sh discovers experiments/*.sh at depth 1 only. This
# repository's own behaviour - which is deliberately not the template's - is
# asserted by experiments/test-issue121-links-recheck.sh.
#
# Needs: node, python3, and the template checkout under
# dev/log/issues/121/pulls/122/templates/js-ai-driven-development-pipeline-template

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATE="$REPO_ROOT/dev/log/issues/121/pulls/122/templates/js-ai-driven-development-pipeline-template"
SCRIPT="$TEMPLATE/scripts/recheck-broken-links.mjs"

[ -f "$SCRIPT" ] || {
  echo "missing $SCRIPT" >&2
  exit 2
}

WORK="$(mktemp -d)"
trap 'kill "${SERVER_PID:-}" 2>/dev/null || true; rm -rf "$WORK"' EXIT

# A host that answers 200 - this stands in for the healthy URL that only
# refused the connection while lychee was asking.
mkdir -p "$WORK/www"
echo ok >"$WORK/www/index.html"
(cd "$WORK/www" && exec python3 -m http.server 8731 --bind 127.0.0.1) >/dev/null 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do
  curl -fsS -o /dev/null "http://127.0.0.1:8731/" 2>/dev/null && break
  sleep 0.1
done

# The workflow file the script reads to learn lychee's --accept list.
mkdir -p "$WORK/repo/.github/workflows" "$WORK/repo/lychee"
cat >"$WORK/repo/.github/workflows/links.yml" <<'YAML'
name: Broken Link Checker
jobs:
  link-checker:
    steps:
      - uses: lycheeverse/lychee-action@v2
        with:
          args: --no-progress --max-retries 3 './**/*.md'
YAML

# One failure of each kind: a host answered 404 (final), and a URL no host
# answered (eligible for a re-check, and healthy now).
cat >"$WORK/repo/lychee/out.md" <<'MD'
# Link Checker Report

## Errors per input

### Errors in README.md

- [404] <https://example.com/definitely-gone/> (at 48:130) | Rejected status code: 404 Not Found
- [ERROR] <http://127.0.0.1:8731/> (at 12:3) | error sending request for url (http://127.0.0.1:8731/): connection reset by peer
MD

cd "$WORK/repo"
: >"$WORK/github_output"

echo "== running the template's recheck-broken-links.mjs =="
LYCHEE_OUTPUT=lychee/out.md \
  RECOVERED_OUTPUT=lychee/recovered.txt \
  GITHUB_OUTPUT="$WORK/github_output" \
  RECHECK_BUDGET_SECONDS=20 \
  RECHECK_WAIT_MS=200 \
  node "$SCRIPT"
rc=$?

echo
echo "== exit code: $rc =="
echo "== \$GITHUB_OUTPUT =="
cat "$WORK/github_output"

echo
if grep -qx 'all_recovered=true' "$WORK/github_output"; then
  cat <<'MSG'
REPRODUCED: all_recovered=true was written even though the report still holds
  [404] https://example.com/definitely-gone/  (a host answered; final)

links.yml gates both the Web Archive step and the "Fail if broken links were
found" step on

  steps.lychee.outputs.exit_code != 0 && steps.recheck.outputs.all_recovered != 'true'

so both are skipped and the job ends green with a 404 in the report.
MSG
  exit 0
fi

echo "NOT REPRODUCED: all_recovered was not set to true; the upstream report" \
  "no longer applies to this checkout of the template."
exit 1
