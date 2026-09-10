#!/usr/bin/env bash
# Probe: what it actually takes for `git diff origin/<base>...HEAD` to work in a
# shallow, single-branch checkout -- which is what `actions/checkout` produces
# with any `fetch-depth` other than 0.
#
# This exists because the obvious repair for the checks that swallow a failed
# diff (report F) is "fetch the base branch first", and the obvious fetch is
# `git fetch origin "$GITHUB_BASE_REF" --depth=1` -- which is what the rust
# template's check-version-modification.rs:102 already does. Two separate
# reasons it does not work:
#
#   case A  a single-branch clone's remote.origin.fetch refspec covers only the
#           checked-out branch, so `git fetch origin main` writes FETCH_HEAD and
#           creates no refs/remotes/origin/main at all -> exit 128, "unknown
#           revision".
#   case B  with an explicit refspec the ref does appear, but a depth-1 fetch
#           into a depth-1 checkout leaves the two histories with no common
#           ancestor -> exit 128 again, "no merge base".
#   case C  dropping the depth limit from that fetch is still not enough: what is
#           shallow is the *local* branch, and fetching the base branch in full
#           does not deepen HEAD -> "no merge base" again.
#
# So only `--unshallow` (case D) or `fetch-depth: 0` (case E) answers the
# question, and every failure above is the same exit 128 that a caller must stop
# reading as "no files changed".
#
# Usage: bash experiments/issue-123/probe-shallow-base-ref.sh
set -uo pipefail

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# A remote with a `main` and a `feature` that diverged from it.
git init -q --bare "${work}/remote.git"
(
  cd "${work}" || exit 1
  git clone -q "${work}/remote.git" seed 2>/dev/null
  cd seed || exit 1
  git config user.email ci@example.invalid
  git config user.name CI
  echo a >f.txt && git add -A && git commit -qm c1
  echo b >>f.txt && git add -A && git commit -qm c2
  git branch -M main && git push -q origin main
  git checkout -qb feature && echo d >other.txt && git add -A && git commit -qm feat
  git push -q origin feature
)

report() {
  local label="$1" dir="$2"
  local out status
  out="$(git -C "${dir}" diff --name-only origin/main...HEAD 2>&1)"
  status=$?
  echo "  origin/main present? $(git -C "${dir}" rev-parse --verify -q refs/remotes/origin/main >/dev/null && echo yes || echo no)"
  echo "  git diff --name-only origin/main...HEAD -> exit=${status}"
  echo "${out}" | head -1 | sed 's/^/    /'
  echo "  ${label}"
}

echo "### case A: git fetch origin main --depth=1, the fetch the scripts already do"
git clone -q --depth=1 --branch feature "file://${work}/remote.git" "${work}/A"
echo "  remote.origin.fetch = $(git -C "${work}/A" config --get remote.origin.fetch)"
echo "  shallow? $([ -f "${work}/A/.git/shallow" ] && echo yes || echo no)"
git -C "${work}/A" fetch origin main --depth=1 2>&1 | sed 's/^/  fetch: /'
report "the single-branch refspec means no remote-tracking ref was created" "${work}/A"

echo
echo "### case B: an explicit refspec, still --depth=1"
git clone -q --depth=1 --branch feature "file://${work}/remote.git" "${work}/B"
git -C "${work}/B" fetch --depth=1 origin '+refs/heads/main:refs/remotes/origin/main' 2>&1 | sed 's/^/  fetch: /'
report "the ref exists and the histories still share no commit" "${work}/B"

echo
echo "### case C: an explicit refspec with no depth limit on the fetch"
git clone -q --depth=1 --branch feature "file://${work}/remote.git" "${work}/C"
git -C "${work}/C" fetch --no-tags origin '+refs/heads/main:refs/remotes/origin/main' 2>&1 | sed 's/^/  fetch: /'
report "still no merge base: the *local* branch is what is shallow, and fetching the base in full does not deepen it" "${work}/C"

echo
echo "### case D: --unshallow, which deepens the local history too"
git clone -q --depth=1 --branch feature "file://${work}/remote.git" "${work}/D"
git -C "${work}/D" fetch --no-tags --unshallow origin '+refs/heads/main:refs/remotes/origin/main' 2>&1 | sed 's/^/  fetch: /'
report "this is the one that answers the question" "${work}/D"

echo
echo "### case E: fetch-depth: 0, i.e. a complete clone"
git clone -q --branch feature "file://${work}/remote.git" "${work}/E"
report "the shipped workflows' configuration, which is why all this is latent" "${work}/E"
