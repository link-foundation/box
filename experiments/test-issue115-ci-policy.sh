#!/usr/bin/env bash
# test-issue115-ci-policy.sh
#
# Issue #115 asks for every false positive, false negative, warning and error
# in CI/CD to be fixed, and for the best practices from the reference
# templates to be reused so the same defects cannot come back.
#
# The per-defect suites (test-issue115-heredoc-unbound-vars.sh,
# -push-retry-classifier.sh, -base-image-preflight.sh) each pin one bug. This
# suite pins the *repo-wide invariants*, so a new workflow or a new job cannot
# quietly reintroduce a class of defect that has already been fixed once.
#
# Invariants, each with the evidence that motivated it:
#   1. Every workflow declares top-level `permissions`.
#      (release.yml had none: version-check, changeset-check, detect-changes
#      and docker-build-test ran with the repository default token scope.)
#   2. Every job sets `timeout-minutes`.
#      (15 release jobs had none — including build-js-amd64, whose arm64 twin
#      had 120 — so a hung job burned the 6-hour default.)
#   3. Third-party actions are pinned to a full 40-character commit SHA.
#      (jlumbroso/free-disk-space@main ran whatever upstream last pushed,
#      inside jobs holding the registry credentials. zizmor `unpinned-uses`.)
#   4. No `always()` in a job gate — use `!cancelled()`.
#      (`always()` keeps a *cancelled* run building, which is exactly what
#      issue #112's supersede work was fighting.)
#   5. `$GITHUB_OUTPUT` is always quoted. (49 unquoted uses, SC2086.)
#   6. Workflow files are lintable by actionlint, and shell in `run:` blocks
#      is shellcheck-clean at warning severity.
#
# References:
#   https://github.com/link-foundation/js-ai-driven-development-pipeline-template
#   https://github.com/link-assistant/hive-mind/blob/main/docs/CI-CD-BEST-PRACTICES.md

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

pass=0
fail=0
ok() {
  echo "  PASS: $1"
  pass=$((pass + 1))
}
bad() {
  echo "  FAIL: $1"
  fail=$((fail + 1))
}

WORKFLOW_DIR=".github/workflows"

echo "== Invariant 1+2: permissions and timeouts =="
report="$(ruby -ryaml -e '
Dir.glob(".github/workflows/*.yml").sort.each do |f|
  d = YAML.load_file(f)
  puts "NOPERM\t#{f}" unless d["permissions"]
  (d["jobs"] || {}).each do |name, job|
    next if job.key?("uses")   # reusable-workflow calls cannot set a timeout
    puts "NOTIMEOUT\t#{f}\t#{name}" unless job.key?("timeout-minutes")
  end
end')"
if [ -z "$(printf '%s' "$report" | grep '^NOPERM' || true)" ]; then
  ok "every workflow declares top-level permissions"
else
  printf '%s\n' "$report" | grep '^NOPERM' | while IFS=$'\t' read -r _ f; do
    echo "    $f has no top-level permissions"
  done
  bad "every workflow declares top-level permissions"
fi
if [ -z "$(printf '%s' "$report" | grep '^NOTIMEOUT' || true)" ]; then
  ok "every job sets timeout-minutes"
else
  printf '%s\n' "$report" | grep '^NOTIMEOUT' | while IFS=$'\t' read -r _ f j; do
    echo "    $f: job '$j' has no timeout-minutes"
  done
  bad "every job sets timeout-minutes"
fi

echo "== Invariant 3: third-party actions are pinned to a commit SHA =="
# First-party actions (actions/*, docker/*, github/*) and local ./ actions are
# allowed a ref pin, matching the policy in .github/zizmor.yml.
unpinned="$(grep -rhoE 'uses: [A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[A-Za-z0-9_.-]+' "$WORKFLOW_DIR" \
  | sed 's/^uses: //' | sort -u \
  | grep -vE '^(actions|docker|github|astral-sh|lycheeverse|zizmorcore|changesets)/' \
  | grep -vE '@[0-9a-f]{40}$' || true)"
if [ -z "$unpinned" ]; then
  ok "no third-party action uses a mutable ref"
else
  printf '    %s\n' $unpinned
  bad "no third-party action uses a mutable ref"
fi

echo "== Invariant 4: no always() in job gates =="
# Comment lines are excluded deliberately. This check used to grep the raw
# text, so a comment *explaining* why a job uses !cancelled() instead of
# always() failed the policy it was documenting - a checker reporting on its
# own prose rather than on the workflow (issue #121). The rule is about the
# expressions GitHub evaluates, so only those are read.
always_hits="$(grep -rn 'always()' "$WORKFLOW_DIR" | grep -vE '^[^:]+:[0-9]+: *#' || true)"
if [ -z "$always_hits" ]; then
  ok "no always() remains in an evaluated expression (use !cancelled())"
else
  printf '%s\n' "$always_hits" | sed 's/^/    /'
  bad "no always() remains in an evaluated expression (use !cancelled())"
fi
cancelled_count="$(grep -rn '!cancelled()' "$WORKFLOW_DIR" | grep -vcE '^[^:]+:[0-9]+: *#' || true)"
if [ "$cancelled_count" -gt 0 ]; then
  ok "!cancelled() is used instead ($cancelled_count gates)"
else
  bad "!cancelled() is used instead"
fi

echo "== Invariant 5: \$GITHUB_OUTPUT is quoted =="
unquoted="$(grep -rn '>> \$GITHUB_OUTPUT' "$WORKFLOW_DIR" || true)"
if [ -z "$unquoted" ]; then
  ok "every \$GITHUB_OUTPUT redirect is quoted"
else
  printf '%s\n' "$unquoted" | sed 's/^/    /'
  bad "every \$GITHUB_OUTPUT redirect is quoted"
fi

echo "== Invariant 6: the workflows lint clean =="
if ! command -v docker >/dev/null 2>&1; then
  echo "  SKIP: docker unavailable, cannot run actionlint/zizmor"
else
  # Read the image out of the workflow instead of naming a version here. Two
  # places naming a linter independently is how a local run and a CI run end up
  # disagreeing about what passed - and this suite restated `1.7.7` as a
  # mutable tag while the workflow had moved to a digest pin (issue #121).
  ACTIONLINT_IMAGE="$(sed -n 's|^[[:space:]]*- uses: docker://\(rhysd/actionlint@sha256:[0-9a-f]\{64\}\).*|\1|p' \
    "$WORKFLOW_DIR/workflows.yml" | head -1)"
  if [ -z "$ACTIONLINT_IMAGE" ]; then
    bad "workflows.yml pins actionlint by digest (could not read the image to run)"
  elif docker run --rm -v "$PWD:/repo" -w /repo "$ACTIONLINT_IMAGE" >/tmp/actionlint-policy.log 2>&1; then
    ok "actionlint (with its bundled shellcheck) reports no problems"
  else
    sed 's/^/    /' /tmp/actionlint-policy.log
    bad "actionlint (with its bundled shellcheck) reports no problems"
  fi
  # Same reasoning for zizmor, and one step further: this used to restate the
  # image and both floors here, and it also ran the analyser with no token -
  # the offline default that made the CI job a false negative (issue #123).
  # scripts/ci/run-zizmor.sh is the single invocation now. Without a token
  # locally the online audits cannot run, so the suite says so rather than
  # reporting a clean result it did not measure.
  ZIZMOR_ENV=()
  if [ -z "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]; then
    echo "  NOTE: no GH_TOKEN in this shell, so zizmor's online audits (known-vulnerable-actions) are skipped here; CI supplies one."
    ZIZMOR_ENV=(ZIZMOR_ALLOW_OFFLINE=1)
  fi
  if env "${ZIZMOR_ENV[@]+"${ZIZMOR_ENV[@]}"}" bash scripts/ci/run-zizmor.sh regular \
    >/tmp/zizmor-policy.log 2>&1; then
    ok "zizmor reports no medium+ findings"
  else
    sed 's/^/    /' /tmp/zizmor-policy.log
    bad "zizmor reports no medium+ findings"
  fi
fi

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] || {
  echo "RESULT: FAIL"
  exit 1
}
echo "RESULT: PASS - repo-wide CI/CD invariants hold"
