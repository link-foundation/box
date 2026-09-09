#!/bin/bash
# git-push-failure-classifier.sh - Tell the two rejected pushes apart
#
# Sourced by git-push-with-retry.sh; also usable standalone:
#   source scripts/release/git-push-failure-classifier.sh
#   is_repository_rule_rejection "$output" && ...
#
# Two rejections print the same word and need opposite recoveries:
#
#   lost race - rebasing onto the new remote head fixes it
#     ! [rejected]        main -> main (non-fast-forward)
#
#   repository rule violation - rebasing can NEVER fix it
#     remote: error: GH013: Repository rule violations found for refs/heads/main.
#     remote: - Changes must be made through a pull request.
#      ! [remote rejected] main -> main (push declined due to repository rule violations)
#
# Reading the second as the first is what makes a release die after the version
# bump has already been committed on the runner: both attempts fail and the log
# blames a race that never happened.
#
# See: https://github.com/link-foundation/box/issues/121
#      https://github.com/link-assistant/hive-mind/blob/main/docs/CI-CD-BEST-PRACTICES.md (principle 10)

# Server-side refusals to accept a direct push: legacy branch protection (GH006)
# and repository rulesets (GH013). No client-side history rewrite satisfies
# them; the change has to arrive through a pull request instead.
GIT_PUSH_RULE_PATTERNS=(
  'gh006'
  'gh013'
  'repository rule violations'
  'changes must be made through a pull request'
  'protected branch'
  'push declined'
)

# Rejections caused by the remote branch having advanced. Only these are fixed
# by rebasing onto the new remote head and pushing again.
GIT_PUSH_RACE_PATTERNS=(
  '[rejected]'
  'non-fast-forward'
  'fetch first'
  'updates were rejected'
)

# Lowercase haystack, so the patterns above can stay lowercase.
_git_push_haystack() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Did the remote refuse the push because of branch protection or a ruleset?
is_repository_rule_rejection() {
  local haystack pattern
  haystack="$(_git_push_haystack "${1:-}")"

  for pattern in "${GIT_PUSH_RULE_PATTERNS[@]}"; do
    case "$haystack" in
      *"$pattern"*) return 0 ;;
    esac
  done
  return 1
}

# Did the remote refuse the push because the branch has advanced?
#
# A ruleset rejection also prints "rejected", so it is excluded first: rebasing
# cannot satisfy a rule, and misreading it as a lost race burns the retry and
# reports the wrong cause.
is_non_fast_forward_rejection() {
  local haystack pattern
  is_repository_rule_rejection "${1:-}" && return 1
  haystack="$(_git_push_haystack "${1:-}")"

  for pattern in "${GIT_PUSH_RACE_PATTERNS[@]}"; do
    case "$haystack" in
      *"$pattern"*) return 0 ;;
    esac
  done
  return 1
}
