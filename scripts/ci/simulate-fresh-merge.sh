#!/usr/bin/env bash
# simulate-fresh-merge.sh - Check out what the merge will actually produce.
#
# Ported from the reference template's scripts/simulate-fresh-merge.sh
# (issue #115, best practice #7), with the parts a shallow-by-default checkout
# needs.
#
# Why. For a `pull_request` event GitHub checks out `refs/pull/N/merge` - a
# merge commit GitHub computed when the pull request was last synchronised. It
# is not recomputed when the base branch moves. So every check in this
# repository has been reporting on a merge result that may be days old: a pull
# request opened before a base commit that breaks it stays green, and the
# breakage appears on `main` after the merge button is pressed. The checks were
# not wrong, they were answering a question nobody asked.
#
# This merges the current tip of the base branch into the checked-out preview
# before the checks run, so a green check means "green after merging", and a
# conflict is reported as a conflict instead of surfacing as a mystery later.
#
# Usage:
#   BASE_REF=main bash scripts/ci/simulate-fresh-merge.sh
#
# Environment variables:
#   BASE_REF       Base branch to merge in (required; ${{ github.base_ref }})
#   MERGE_DEEPEN   Commits to deepen a shallow clone by, when --unshallow is
#                  refused (default: 200)
#   FETCH_RETRIES  Attempts at fetching the base branch (default: 3)
#   FETCH_DELAY    Seconds between those attempts (default: 5)
#   BOX_VERBOSE=1  Trace every command this script runs
#
# Exit codes:
#   0  the working tree now contains the merge result (or already did)
#   1  merge conflict: the pull request cannot be merged as it stands
#   2  misuse (BASE_REF missing, not a git repository)

set -uo pipefail

if [ "${BOX_VERBOSE:-0}" = "1" ]; then
  set -x
fi

MERGE_DEEPEN="${MERGE_DEEPEN:-200}"
FETCH_RETRIES="${FETCH_RETRIES:-3}"
FETCH_DELAY="${FETCH_DELAY:-5}"

if [ -z "${BASE_REF:-}" ]; then
  echo "::error title=simulate-fresh-merge::BASE_REF is required (e.g. BASE_REF=main)" >&2
  exit 2
fi

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "::error title=simulate-fresh-merge::not inside a git repository" >&2
  exit 2
fi

echo "=== Simulating a fresh merge with ${BASE_REF} ==="

# The merge commit is thrown away with the runner, but git refuses to make one
# without an identity. The 41898282+ prefix is what attributes it to
# github-actions[bot] rather than leaving it unattributed.
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git config user.name "github-actions[bot]"

# Most checkouts here are shallow (fetch-depth defaults to 1), and a shallow
# HEAD has no common ancestor with a freshly fetched base tip: the merge would
# fail with "refusing to merge unrelated histories", which is not a conflict
# and must not be reported as one. Deepen first.
if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
  echo "Shallow checkout; deepening before the merge..."
  git fetch --no-tags --quiet --unshallow origin 2>/dev/null \
    || git fetch --no-tags --quiet --deepen="$MERGE_DEEPEN" origin \
    || echo "::warning title=simulate-fresh-merge::could not deepen the checkout"
fi

# Every checkout in this repository sets `persist-credentials: false`
# (zizmor's artipacked rule), so this fetch is anonymous. That is fine here
# because the repository is public; making this work on a private repository
# would mean handing the action a token, not dropping the hardening.
#
# Retried, because this step now runs in sixteen jobs: a single flaky fetch
# would fail all of them, and a check that fails for a reason unrelated to the
# code under test is the false positive this whole pull request is about. Three
# attempts is enough for a blip and short enough that a genuinely missing base
# branch is still reported promptly.
fetched=0
for attempt in $(seq 1 "$FETCH_RETRIES"); do
  if git fetch --no-tags origin "+refs/heads/${BASE_REF}:refs/remotes/origin/${BASE_REF}"; then
    fetched=1
    break
  fi
  if [ "$attempt" -lt "$FETCH_RETRIES" ]; then
    echo "Fetch of ${BASE_REF} failed (attempt ${attempt}/${FETCH_RETRIES}); retrying in ${FETCH_DELAY}s..."
    sleep "$FETCH_DELAY"
  fi
done

if [ "$fetched" -ne 1 ]; then
  echo "::error title=simulate-fresh-merge::cannot fetch ${BASE_REF} from origin after ${FETCH_RETRIES} attempts" >&2
  exit 2
fi

echo "Merge preview:      $(git rev-parse HEAD)"
echo "Base branch tip:    $(git rev-parse "origin/${BASE_REF}")"

# Without a merge base the count below is meaningless and the merge would be
# an "unrelated histories" error. Degrade with a warning rather than failing
# every job: an unmergeable-looking history here means the deepening above did
# not reach far enough, which is a CI configuration problem, not the pull
# request's fault.
if ! git merge-base HEAD "origin/${BASE_REF}" >/dev/null 2>&1; then
  echo "::warning title=simulate-fresh-merge::no common ancestor with origin/${BASE_REF} after deepening; checks run against the merge preview as checked out"
  exit 0
fi

BEHIND_COUNT="$(git rev-list --count "HEAD..origin/${BASE_REF}")"

if [ "$BEHIND_COUNT" -eq 0 ]; then
  echo "The merge preview already contains every commit on ${BASE_REF}. Nothing to do."
  exit 0
fi

echo "${BASE_REF} has ${BEHIND_COUNT} commit(s) the merge preview does not."
echo "Merging origin/${BASE_REF} so the checks run against the real merge result..."

if git merge "origin/${BASE_REF}" --no-edit; then
  echo "Fresh merge succeeded; the checks below report on the merged tree."
  exit 0
fi

# Leave the working tree usable and name the files, so the annotation says what
# to fix instead of only that something is wrong.
CONFLICTS="$(git diff --name-only --diff-filter=U 2>/dev/null || true)"
git merge --abort 2>/dev/null || true

echo "::error title=Merge conflict::${BASE_REF} cannot be merged into this pull request. Rebase or merge ${BASE_REF} locally and resolve the conflicts."
if [ -n "$CONFLICTS" ]; then
  echo "Conflicting paths:"
  printf '%s\n' "$CONFLICTS" | sed 's/^/  /'
fi
echo
echo "Reproduce locally:"
echo "  git fetch origin ${BASE_REF} && git merge origin/${BASE_REF}"
exit 1
