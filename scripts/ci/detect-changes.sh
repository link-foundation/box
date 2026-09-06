#!/usr/bin/env bash
#
# CI change detection for the Build and Release workflow (.github/workflows/release.yml).
#
# Decides which Docker images need to be (re)built/tested for a given event and
# writes the per-category / per-image / per-language flags plus the aggregate
# `should-build` decision to $GITHUB_OUTPUT (and stdout for the run log).
#
# The single most important rule (issue #108):
#
#   For `pull_request` events we evaluate ONLY the PR head's latest commit, not
#   the whole PR diff. GitHub Actions checks out a synthetic merge commit
#   (refs/pull/N/merge) whose first parent (HEAD^1) is the base branch and
#   whose second parent (HEAD^2) is the PR head. Comparing HEAD^2^..HEAD^2
#   yields exactly what the most recent push changed. This means a trivial
#   synchronize commit (a `.gitkeep`, a docs tweak, a Markdown edit) skips the
#   expensive build+test matrix even when EARLIER commits in the same PR did
#   change image source — those earlier commits were already exercised when
#   they were pushed.
#
#   For `push` events (including the merge-to-main release commit) we evaluate
#   the full pushed range so a real release build is never skipped.
#
# This mirrors the canonical `detect-code-changes` scripts shipped in the
# link-foundation js/rust/python/csharp pipeline templates, which all use the
# HEAD^2^..HEAD^2 per-commit diff for pull_request events.
#
# Testability: the file-classification logic is pure. Set CHANGED_FILES_OVERRIDE
# to a newline-separated list of paths to bypass git entirely (used by the unit
# test experiments/test-issue108-detect-changes.sh). The git-range resolution is
# itself exercised by the same test against throwaway repositories.
#
# Inputs (environment):
#   GITHUB_EVENT_NAME   - 'pull_request' | 'push' | 'workflow_dispatch' | ...
#   PR_BASE_SHA         - github.event.pull_request.base.sha (fallback only)
#   PUSH_BEFORE_SHA     - github.event.before (push fallback)
#   CHANGED_FILES_OVERRIDE - optional newline list of paths (skips git)
#   GITHUB_OUTPUT       - optional GitHub Actions output file
#
# Languages must stay in sync with the matrices in release.yml.

set -euo pipefail

LANGUAGES="python go rust java kotlin ruby php perl swift lean rocq cpp assembly dotnet r"

log() { echo "$@"; }

# Resolve the "A B" git range whose `git diff --name-only A B` is the set of
# files we want to classify for this event. Prints the range on stdout.
resolve_range() {
  local event="${GITHUB_EVENT_NAME:-}"

  if [ "$event" = "pull_request" ]; then
    # Synthetic merge commit: HEAD^1=base, HEAD^2=PR head.
    if git rev-parse --verify -q "HEAD^2" >/dev/null 2>&1; then
      if git rev-parse --verify -q "HEAD^2^" >/dev/null 2>&1; then
        echo "HEAD^2^ HEAD^2" # per-commit diff of the PR head (issue #108)
        return
      fi
      # First commit on the PR head has no parent inside the PR: diff the PR
      # head against the base branch tip (HEAD^1).
      echo "HEAD^1 HEAD^2"
      return
    fi
    # No merge commit (forks, fast-forward, shallow checkout): fall back to the
    # whole-PR diff against the base SHA so we never under-build.
    if [ -n "${PR_BASE_SHA:-}" ] && git rev-parse --verify -q "$PR_BASE_SHA" >/dev/null 2>&1; then
      echo "$PR_BASE_SHA HEAD"
      return
    fi
    last_resort_range
    return
  fi

  # push / other events: evaluate the full pushed range. github.event.before is
  # the tip before the push; for a merge-to-main it is the previous main tip so
  # the whole merge (every PR commit) is evaluated and the release build runs.
  local before="${PUSH_BEFORE_SHA:-}"
  local zero="0000000000000000000000000000000000000000"
  if [ -n "$before" ] && [ "$before" != "$zero" ] && git rev-parse --verify -q "$before" >/dev/null 2>&1; then
    echo "$before HEAD"
    return
  fi
  last_resort_range
}

# HEAD~1..HEAD, but only if HEAD~1 is actually reachable. It is not in a
# shallow checkout - actions/checkout defaults to fetch-depth: 1 - nor on a
# repository's root commit. Printing a range that cannot be resolved used to
# take the whole script down: `git diff` exits 128, and the `|| git diff
# --name-only HEAD~1 HEAD` fallback below re-ran the identical failing command,
# so under `set -euo pipefail` the script died with `error: Could not access
# HEAD~1` and wrote not one output. Print nothing instead and let the caller
# degrade (issue #115).
last_resort_range() {
  if git rev-parse --verify -q "HEAD~1" >/dev/null 2>&1; then
    echo "HEAD~1 HEAD"
  fi
}

# Print the newline-separated list of changed file paths for this event.
get_changed_files() {
  if [ -n "${CHANGED_FILES_OVERRIDE:-}" ]; then
    printf '%s\n' "$CHANGED_FILES_OVERRIDE"
    return
  fi
  local range files
  range=$(resolve_range)

  if [ -n "$range" ]; then
    log "Comparing range: ${range}" >&2
    # shellcheck disable=SC2086
    if files="$(git diff --name-only $range 2>/dev/null)"; then
      printf '%s\n' "$files"
      return
    fi
    log "Range ${range} did not resolve; falling back to every tracked file" >&2
  else
    log "No diff range available (shallow checkout or root commit); falling back to every tracked file" >&2
  fi

  # Never under-build. With no usable range the safe classification is "all of
  # it changed": a build that was not needed costs runner minutes, a build that
  # was needed and skipped ships an unbuilt image.
  git ls-files
}

# matches REGEX < files -> echoes "true"/"false"
matches() {
  local regex="$1"
  if grep -qE "$regex" 2>/dev/null; then
    echo "true"
  else
    echo "false"
  fi
}

set_output() {
  local name="$1" value="$2"
  log "${name}=${value}"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "${name}=${value}" >>"$GITHUB_OUTPUT"
  fi
}

main() {
  local changed_files
  changed_files="$(get_changed_files)"

  log "=== Changed files (classified for build decision) ==="
  if [ -z "$changed_files" ]; then
    log "  (none)"
  else
    printf '%s\n' "$changed_files" | sed 's/^/  /'
  fi
  log ""

  # --- Top-level categories ---
  local docker scripts ubuntu workflow version
  docker=$(printf '%s\n' "$changed_files" | matches '^Dockerfile$')
  scripts=$(printf '%s\n' "$changed_files" | matches '^scripts/')
  ubuntu=$(printf '%s\n' "$changed_files" | matches '^ubuntu/')
  workflow=$(printf '%s\n' "$changed_files" | matches '^\.github/(workflows|actions)/')
  version=$(printf '%s\n' "$changed_files" | matches '^VERSION$')
  set_output docker "$docker"
  set_output scripts "$scripts"
  set_output ubuntu "$ubuntu"
  set_output workflow "$workflow"
  set_output version "$version"

  # --- Per-image categories ---
  local js essentials full common dind
  js=$(printf '%s\n' "$changed_files" | matches '^ubuntu/24\.04/js/')
  essentials=$(printf '%s\n' "$changed_files" | matches '^ubuntu/24\.04/essentials-box/')
  full=$(printf '%s\n' "$changed_files" | matches '^(ubuntu/24\.04/full-box/|Dockerfile$|scripts/)')
  common=$(printf '%s\n' "$changed_files" | matches '^ubuntu/24\.04/common\.sh$')
  # dind: image source and the CI example tests that exercise it. Documentation
  # under docs/dind/ is intentionally NOT a build trigger (issue #108: docs and
  # other non-essential files must not run the image build/test matrix).
  dind=$(printf '%s\n' "$changed_files" | matches '^(ubuntu/24\.04/dind/|tests/dind/)')
  set_output js "$js"
  set_output essentials "$essentials"
  set_output full "$full"
  set_output common "$common"
  set_output dind "$dind"

  # --- Per-language categories ---
  local lang val
  for lang in $LANGUAGES; do
    val=$(printf '%s\n' "$changed_files" | matches "^ubuntu/24\\.04/${lang}/")
    set_output "$lang" "$val"
  done

  # --- Aggregate build decision ---
  local should_build="false" reason="no relevant changes detected"
  if [ "${GITHUB_EVENT_NAME:-}" = "workflow_dispatch" ]; then
    should_build="true"
    reason="manual dispatch"
  elif [ "$docker" = "true" ]; then
    should_build="true"
    reason="Dockerfile changes"
  elif [ "$scripts" = "true" ]; then
    should_build="true"
    reason="scripts changes"
  elif [ "$ubuntu" = "true" ]; then
    should_build="true"
    reason="ubuntu modular scripts changes"
  elif [ "$workflow" = "true" ]; then
    should_build="true"
    reason="workflow/action changes"
  elif [ "$version" = "true" ]; then
    should_build="true"
    reason="VERSION file changes"
  elif [ "$dind" = "true" ]; then
    should_build="true"
    reason="dind image/test changes"
  fi
  set_output should-build "$should_build"
  log ""
  if [ "$should_build" = "true" ]; then
    log "Build needed: ${reason}"
  else
    log "No build needed: ${reason}"
  fi
}

main "$@"
