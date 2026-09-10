#!/usr/bin/env bash
# run-secretlint.sh
#
# Scans the repository for committed credentials with secretlint.
#
# Why this exists (issue #115): best practice #11, and this repository handles
# registry credentials in every release job. The `DOCKERHUB_TOKEN` that expired
# and failed run 33972074755 is exactly the kind of value that gets pasted into
# a script "just to test something" and then committed.
#
# Why the canary (this is the point of the script): secretlint reports nothing
# both when a repository is clean and when its rules failed to load. Those are
# indistinguishable from the exit code, and a scanner that silently scans with
# no rules is worse than no scanner - it is a green check that means nothing.
# So every run first plants a synthetic key in a temporary directory and fails
# if secretlint does NOT find it.
#
# The canary also has to be a key the rules do not allow-list. AWS's own
# documentation example - AKIAIOSFODNN7EXAMPLE with the matching secret - is
# allow-listed by @secretlint/secretlint-rule-aws and produces no finding, which
# is how this check was first written and why it passed against a planted secret
# (measured, 2026-09-06).
#
# Usage:
#   bash scripts/ci/run-secretlint.sh              # canary self-check, then the
#                                                  # whole working tree
#   bash scripts/ci/run-secretlint.sh path ...     # ... then only these paths
#
# The argument form exists for the pre-commit hook (issue #121): it scans the
# paths a commit is about to record, which is where a new credential can still
# be introduced, and skips the rest of the tree, which was scanned when it was
# committed. CI keeps scanning everything - a rule added to a later version of
# the preset has to be applied to the files that were already here. The canary
# runs either way, so silence still means the rules loaded.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

# Pinned: an unpinned scanner changes what it finds between two runs of the same
# commit, and a rule set that silently drops a rule is the failure this whole
# script is defending against.
SECRETLINT_VERSION="13.0.5"
PRESET="@secretlint/secretlint-rule-preset-recommend@${SECRETLINT_VERSION}"

secretlint_run() {
  npx --yes -p "secretlint@${SECRETLINT_VERSION}" -p "$PRESET" secretlint "$@"
}

# --- 1. prove the rules are loaded --------------------------------------------

CANARY_DIR="$(mktemp -d)"
trap 'rm -rf "$CANARY_DIR"' EXIT
cp .secretlintrc.json "$CANARY_DIR/"

# The canary is generated, never written down. A literal 40-character key in
# this file would be found by the very scan it is here to validate - the first
# version of this script failed on itself. Random also means the canary cannot
# quietly become an allow-listed constant.
# Bound the *reader*, not the writer. `tr </dev/urandom | head -c N` leaves tr
# writing into a pipe whose reader has already left, and that is an error, not
# a silent death, wherever SIGPIPE is ignored - which a GitHub runner is: the
# two calls below printed `tr: write error: Broken pipe` twice into run
# 34366975942's secretlint log (issue #123). Reading a bounded block instead
# lets tr reach EOF, which is also what scripts/release/create-changeset.sh:42
# already does.
#
# It is not only log noise. Under this script's `set -o pipefail` the writer's
# status is the pipeline's, and the old form survived only because its result
# was an argument to printf, where a failed command substitution does not
# propagate; as a bare `x=$(rand_alnum 16)` the same call exits 141 under the
# default disposition and 1 under an ignored SIGPIPE, and `set -e` aborts.
rand_alnum() {
  local want="$1" out=''
  while [ "${#out}" -lt "$want" ]; do
    # About a quarter of random bytes are alphanumeric, so 8x is ample; the
    # loop is what makes it certain rather than likely.
    out+="$(head -c "$((want * 8))" /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
  done
  printf '%s' "${out:0:want}"
}
{
  printf 'aws_access_key_id = AKIA%s\n' "$(rand_alnum 16)"
  printf 'aws_secret_access_key = %s\n' "$(rand_alnum 40)"
} >"$CANARY_DIR/canary.txt"

echo "==> Canary: secretlint must find a planted key before its silence means anything"
set +e
(cd "$CANARY_DIR" && secretlint_run canary.txt) >"$CANARY_DIR/output.txt" 2>&1
CANARY_STATUS=$?
set -e

if [ "$CANARY_STATUS" -eq 0 ]; then
  echo "::error title=run-secretlint.sh::secretlint did not flag the planted key; its rules are not loading, so a clean scan proves nothing"
  cat "$CANARY_DIR/output.txt"
  exit 1
fi
echo "==> Canary detected (secretlint exit $CANARY_STATUS); the rules are live"

# --- 2. scan the repository ---------------------------------------------------

TARGETS=("$@")
if [ "${#TARGETS[@]}" -eq 0 ]; then
  TARGETS=("**/*")
  echo "==> secretlint ${SECRETLINT_VERSION} over the working tree"
else
  echo "==> secretlint ${SECRETLINT_VERSION} over ${#TARGETS[@]} named path(s)"
fi

set +e
secretlint_run "${TARGETS[@]}"
STATUS=$?
set -e

if [ "$STATUS" -eq 0 ]; then
  echo "==> No secrets found"
else
  echo "::error title=run-secretlint.sh::secretlint found a credential in the working tree"
  echo "==> Reproduce locally with: bash scripts/ci/run-secretlint.sh"
fi
exit "$STATUS"
