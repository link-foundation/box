#!/bin/bash
# git-push-with-retry.sh - Push HEAD to a shared branch, recovering from both
# ways the push can be rejected.
#
# Usage: ./git-push-with-retry.sh [remote] [branch] [label]
#   remote  git remote to push to            (default: origin)
#   branch  branch to land HEAD on           (default: main)
#   label   names the fallback pull request  (default: the VERSION file)
#
# Environment:
#   GIT_PUSH_MAX_ATTEMPTS   rebase-and-retry attempts       (default: 3)
#   GIT_PUSH_RETRY_DELAY    seconds between attempts        (default: 5)
#   GIT_PUSH_MERGE_ATTEMPTS polls while GitHub computes mergeability (default: 10)
#   GIT_PUSH_MERGE_DELAY    seconds between merge polls     (default: 5)
#   GIT_PUSH_VERBOSE=1      trace every git/gh invocation   (default: off)
#
# Why this exists (issue #121). Three jobs in this repository pushed straight to
# main with a bare `git push origin main`: the release workflow's version bump,
# scripts/release/apply-changesets.sh, and the disk-space measurement commit.
# Serialising writers with a concurrency group orders them, it does not rebase
# them - `actions/checkout` checks out `github.sha`, so the second writer in the
# queue is behind the branch the moment the first one lands, and its push is
# rejected. The measurement job runs for about 18 minutes before it pushes,
# which is a wide window to lose.
#
# `git pull --rebase` alone is not the fix either: it closes most of the window
# but not the seconds between the rebase and the push, it never retries, and it
# answers a repository-rule rejection with a rebase that cannot possibly help.
#
# See: https://github.com/link-assistant/hive-mind/blob/main/docs/CI-CD-BEST-PRACTICES.md (principle 10)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/release/git-push-failure-classifier.sh
source "$SCRIPT_DIR/git-push-failure-classifier.sh"

REMOTE="${1:-origin}"
BRANCH="${2:-main}"
LABEL="${3:-}"

MAX_ATTEMPTS="${GIT_PUSH_MAX_ATTEMPTS:-3}"
RETRY_DELAY="${GIT_PUSH_RETRY_DELAY:-5}"
MERGE_ATTEMPTS="${GIT_PUSH_MERGE_ATTEMPTS:-10}"
MERGE_DELAY="${GIT_PUSH_MERGE_DELAY:-5}"
VERBOSE="${GIT_PUSH_VERBOSE:-0}"

log() { echo "==> $*"; }
trace() { [ "$VERBOSE" = "1" ] && echo "[git-push] $*" >&2 || true; }

if [ -z "$LABEL" ]; then
  LABEL="$(tr -d '[:space:]' <VERSION 2>/dev/null || true)"
  LABEL="${LABEL:-automation}"
fi

# Land an already-created commit on a branch that refuses direct pushes.
#
# A ruleset with a `pull_request` rule whose bypass_actors omits the Actions app
# rejects every direct push with GH013. Weakening the ruleset is the wrong fix;
# the commit can arrive the way the rule asks for. Two ruleset details shape
# this: a `non_fast_forward`/`deletion` rule on `~ALL` forbids force-pushing and
# deleting any ref, so the temporary branch is never reused and never deleted -
# the run id makes each attempt's name unique - and `allowed_merge_methods` may
# be `["merge"]` only, so the merge must not assume squash or rebase.
land_via_pull_request() {
  local slug pr_branch url attempt

  slug="$(printf '%s' "$LABEL" | tr -c 'A-Za-z0-9._-' '-' | sed 's/^-*//; s/-*$//')"
  pr_branch="release/${slug:-automation}-${GITHUB_RUN_ID:-local}"

  log "Pushing HEAD to $pr_branch and landing it through a pull request"
  trace "git push $REMOTE HEAD:$pr_branch"
  git push "$REMOTE" "HEAD:$pr_branch"

  url="$(gh pr list --head "$pr_branch" --base "$BRANCH" --state open --json url --jq '.[0].url // ""' 2>/dev/null || true)"
  if [ -z "$url" ]; then
    url="$(gh pr create --head "$pr_branch" --base "$BRANCH" \
      --title "$LABEL" \
      --body "Opened by scripts/release/git-push-with-retry.sh because a repository rule declined a direct push to \`$BRANCH\`." \
      2>&1 | tail -n1)"
  fi
  log "Pull request: $url"

  # `gh pr merge` answers "Pull request is not mergeable" for a few seconds
  # after creation, while GitHub is still computing the field. Treating that as
  # a hard failure aborts a release one poll from success.
  attempt=1
  while [ "$attempt" -le "$MERGE_ATTEMPTS" ]; do
    if gh pr merge "$url" --merge; then
      log "Merged $url on attempt $attempt"
      # Fast-forward the checkout to the merged branch so the rest of the job
      # (publish, release notes, tags) proceeds unchanged in the same run.
      git fetch "$REMOTE" "$BRANCH"
      git checkout -B "$BRANCH" "$REMOTE/$BRANCH"
      return 0
    fi
    if [ "$attempt" -eq "$MERGE_ATTEMPTS" ]; then
      break
    fi
    log "Merge attempt $attempt/$MERGE_ATTEMPTS did not succeed yet; GitHub may still be computing mergeability. Retrying in ${MERGE_DELAY}s..."
    sleep "$MERGE_DELAY"
    attempt=$((attempt + 1))
  done

  echo "::error title=Could not land the commit::A repository rule declined the direct push to ${BRANCH} and the fallback pull request ${url} could not be merged after ${MERGE_ATTEMPTS} attempts." >&2
  return 1
}

attempt=1
while :; do
  log "Pushing HEAD to $REMOTE/$BRANCH (attempt $attempt/$MAX_ATTEMPTS)"
  trace "git push $REMOTE HEAD:$BRANCH"
  # Capture while still streaming: the output has to be inspectable to be
  # classified, but a silent push is not debuggable (same reasoning as
  # docker-push-with-retry.sh).
  if output="$(git push "$REMOTE" "HEAD:$BRANCH" 2>&1 | tee /dev/stderr)"; then
    log "Push succeeded"
    exit 0
  fi

  if is_repository_rule_rejection "$output"; then
    echo "::notice title=Direct push declined by a repository rule::Landing the commit on ${BRANCH} through a pull request instead."
    land_via_pull_request
    exit $?
  fi

  # Auth, network, a missing remote: rebasing would hide the real error and
  # report a race that never happened.
  if ! is_non_fast_forward_rejection "$output"; then
    echo "::error title=Push to ${BRANCH} failed::The rejection is neither a lost race nor a repository rule, so no retry can fix it. See the output above." >&2
    exit 1
  fi

  if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
    echo "::error title=Push to ${BRANCH} failed::Lost the race with another writer ${MAX_ATTEMPTS} times." >&2
    exit 1
  fi

  echo "::warning title=Rebasing before retry::${REMOTE}/${BRANCH} advanced while this job was running; rebasing onto it and pushing again."
  sleep "$RETRY_DELAY"
  # Rebase, never force: the point is for the later commit to end up on top of
  # the earlier one. --force-with-lease would delete whatever the writer ahead
  # of us landed.
  git pull --rebase "$REMOTE" "$BRANCH"
  attempt=$((attempt + 1))
done
