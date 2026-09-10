#!/usr/bin/env bash
# release-version.sh
#
# "Which version is this release publishing?" - asked once by the pipeline, and
# answered the same way by every job that puts that answer on an image.
#
# Why this exists (issue #123)
# ----------------------------
#
# Eighteen steps across the six release workflows read the VERSION file, and
# every one of them read it the same way:
#
#   VERSION=$(tr -d '[:space:]' < VERSION)
#   echo "version=$VERSION" >> "$GITHUB_OUTPUT"
#
# A *missing* VERSION file is caught, but only by accident: the runner's default
# shell is `bash -e {0}`, the redirection fails, and the step fails with it. An
# empty or whitespace-only VERSION file is not caught by anything. `tr` reads it,
# succeeds, prints nothing, and the step writes `version=` to $GITHUB_OUTPUT with
# exit 0 - measured, not assumed:
#
#   $ : > VERSION
#   $ V=$(tr -d '[:space:]' < VERSION); echo "[$V] status=$?"
#   [] status=0
#
# Where that empty string lands decides how bad it is. In a build job it becomes
# an image tag - `ghcr.io/link-foundation/box-js:-amd64`. In the two jobs that
# *bump* the version it is arithmetic:
#
#   $ IFS='.' read -r MAJOR MINOR PATCH <<< ""
#   $ MAJOR=$((MAJOR + 1)); echo "$MAJOR.0.0"
#   1.0.0
#
# so an unreadable VERSION file does not stop a release, it releases 1.0.0 -
# a version below every version this repository has ever published, computed
# from a file nothing looked at, and pushed to main.
#
# The second half of the same step was
#
#   git pull origin main || true
#
# in sixteen of the eighteen - every one except release.yml's version-bump read
# and the read in its "Fetch latest changes" step, which pulls without `|| true`
# before it. It is not needed and it is not safe. Not needed,
# because every one of those jobs checks out with `ref: main`, which actions/
# checkout resolves against the remote when the job starts - after
# apply-changesets has pushed the bump, since every build job `needs` it. Not
# safe, because the only thing the pull can still bring in is a commit somebody
# pushed to main *after* this release started: the late jobs of a release then
# build and tag a different tree from the early ones, and `|| true` means no
# log says which. The release is one release; the version has to be one version.
#
# This is the same shape as issue #119b's image-tags.sh - "One job computes this
# list and hands it to the others, so 'which tags does this release write?' has
# exactly one answer per run". The pipeline already computes the version once,
# in release.yml's detect-changes job, and already hands it to every called
# workflow inside `changes`. This helper reads that answer, checks it against
# the VERSION file in the checkout, and refuses to invent one.
#
# Usage (executed, in a workflow step):
#   - name: Get the version this release publishes
#     id: version
#     env:
#       PIPELINE_VERSION: ${{ fromJSON(inputs.changes)['version'] }}
#     run: bash scripts/release/release-version.sh
#
#   Prints the version on stdout and appends `version=<version>` to
#   $GITHUB_OUTPUT when the runner set it. Exits 1, having printed an ::error
#   naming what each source said, when there is no sane version to print.
#
#   --file PATH     read this file instead of ./VERSION
#   --output NAME   name the $GITHUB_OUTPUT key (default: version)
#   --no-output     print only; do not write to $GITHUB_OUTPUT
#
# Usage (sourced, for scripts that already have their own error handling):
#   source "$(dirname "${BASH_SOURCE[0]}")/release-version.sh"
#   if ! version="$(read_version_file VERSION)"; then exit 1; fi
#
# Environment:
#   PIPELINE_VERSION            the version the pipeline already decided
#   RELEASE_VERSION_VERBOSE=1   trace which source won and why  (default: off)
#   BOX_VERBOSE=1               the same switch, repository-wide (default: off)
#
# The failure path already says everything it can. The trace is about the path
# that *succeeds*: the eighteen steps this replaces printed either nothing or
# a bare "Detected version: 2.9.0", so "which of the two sources did this job
# believe, and did they agree?" could not be answered from a log at all. Off by
# default, because it belongs on stderr of a passing step only when someone is
# asking.

# Not `set -e`: this file is sourced into scripts with their own error handling,
# and a sourced `set -e` would change theirs.

# shellcheck source=scripts/ci/run-with-commands-stopped.sh
source "$(dirname "${BASH_SOURCE[0]}")/../ci/run-with-commands-stopped.sh"

RELEASE_VERSION_VERBOSE="${RELEASE_VERSION_VERBOSE:-${BOX_VERBOSE:-0}}"

# Traces go to stderr: every executed caller reads this file's stdout through a
# command substitution or a step output, so a trace on stdout would become part
# of the answer - a version string with a diagnostic line in it, which is a
# worse failure than the one this helper exists to fix.
rv_trace() {
  [ "$RELEASE_VERSION_VERBOSE" = "1" ] || return 0
  # A version string is text this repository does not always write - it can come
  # from a workflow input - and `##[` anywhere in a physical line is a command
  # to the runner (this issue's log-injection class).
  run_with_commands_stopped printf '[release-version] %s\n' "$*" >&2
}

# What this repository calls a version: MAJOR.MINOR.PATCH and nothing else.
#
# Not semver's full grammar, deliberately. Two callers of this reader bump the
# number they are given with `IFS='.' read -r MAJOR MINOR PATCH` followed by
# `$((PATCH + 1))`, and a pre-release suffix makes PATCH the string `0-rc`,
# which is an arithmetic error and not a version. Accepting a shape the
# consumers cannot use would move the failure one step further from its cause -
# which is the defect this whole issue is about. If this repository ever
# publishes a pre-release, this is the line that has to change first, and every
# consumer of it is one `grep version_is_sane` away.
version_is_sane() {
  [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# How the error message describes PIPELINE_VERSION. Written once because the
# same three states - unset, set to something usable, set to something that is
# not a version - are reported from two places.
rv_pipeline_state() {
  local value
  value="$(printf '%s' "${PIPELINE_VERSION:-}" | tr -d '[:space:]')"
  if [ -z "$value" ]; then
    printf 'not set'
  elif version_is_sane "$value"; then
    printf "set to '%s'" "$value"
  else
    # The raw value, not the whitespace-stripped one that was tested: a reader
    # who wrote "v2.9.0 " needs to see what they wrote.
    printf "holds '%s', which is not a version" "${PIPELINE_VERSION:-}"
  fi
}

# How the error message describes the VERSION file, given what came out of it.
rv_file_state() {
  local raw="$1"
  if [ -z "$raw" ]; then
    printf 'is empty'
  else
    printf "holds '%s', which is not a version" "$raw"
  fi
}

# Everything this helper refuses to guess, said once, with the reason.
rv_error() {
  local file="$1" file_state="$2" pipeline_state="$3"
  echo "::error title=release-version::Cannot tell which version this release publishes"
  echo ""
  echo "Every image tag, release note and manifest in this run is named after"
  echo "one version string, and neither source produced a usable one. Publishing"
  echo "under a version nothing confirmed would overwrite whatever already holds"
  echo "that tag, so this is an error rather than a default."
  echo ""
  run_with_commands_stopped echo "  ${file}: ${file_state}"
  # Omitted by read_version_file, which does not consult PIPELINE_VERSION:
  # naming a source that was never asked would send a reader looking for a
  # setting that has nothing to do with the failure.
  if [ -n "$pipeline_state" ]; then
    run_with_commands_stopped echo "  PIPELINE_VERSION: ${pipeline_state}"
  fi
  echo ""
  # `apply-changesets.sh`, not its path. check-checkout-credentials.mjs follows
  # every `scripts/...` string in a job's closure and calls the job a pusher if
  # anything it reaches pushes - so spelling the path here, in text this helper
  # only prints, classified all 17 jobs that reach it as writers to the remote
  # and asked them to keep a credential none of them uses. The bare name reads
  # the same.
  echo "A version here is MAJOR.MINOR.PATCH and nothing else - the shape"
  echo "apply-changesets.sh writes and the shape the bump"
  echo "arithmetic can read back. Usual causes: a VERSION file truncated to zero"
  echo "bytes by an interrupted bump, or a job reading a checkout the bump never"
  echo "reached."
}

# The trimmed contents of the VERSION file, or a named failure. Distinguishes
# the three ways it can go wrong - absent, unreadable, present but not a version
# - because they have different causes and the caller's log is the only place
# anyone will look.
read_version_file() {
  local file="${1:-VERSION}" raw

  if [ ! -e "$file" ]; then
    rv_error "$file" "does not exist" "" >&2
    return 1
  fi
  if ! raw="$(cat -- "$file" 2>&1)"; then
    rv_error "$file" "could not be read - $raw" "" >&2
    return 1
  fi

  raw="$(printf '%s' "$raw" | tr -d '[:space:]')"
  if ! version_is_sane "$raw"; then
    rv_error "$file" "$(rv_file_state "$raw")" "" >&2
    return 1
  fi

  printf '%s\n' "$raw"
  return 0
}

# The version this run publishes. PIPELINE_VERSION is the pipeline's own answer,
# computed once in release.yml's detect-changes job and handed to every called
# workflow; the VERSION file in this job's checkout is the cross-check.
resolve_release_version() {
  local file="${1:-VERSION}" from_file='' from_pipeline='' file_state pipeline_state raw

  pipeline_state="$(rv_pipeline_state)"
  from_pipeline="$(printf '%s' "${PIPELINE_VERSION:-}" | tr -d '[:space:]')"
  version_is_sane "$from_pipeline" || from_pipeline=''

  if [ ! -e "$file" ]; then
    file_state="does not exist"
  elif ! raw="$(cat -- "$file" 2>&1)"; then
    file_state="could not be read - $raw"
  else
    raw="$(printf '%s' "$raw" | tr -d '[:space:]')"
    if version_is_sane "$raw"; then
      from_file="$raw"
      file_state="holds '${raw}'"
    else
      file_state="$(rv_file_state "$raw")"
    fi
  fi

  if [ -z "$from_file" ] && [ -z "$from_pipeline" ]; then
    rv_error "$file" "$file_state" "$pipeline_state" >&2
    return 1
  fi

  # Both usable and disagreeing is not a reason to stop - one of the two is the
  # release, and it is the pipeline's - but it is never normal. It means main
  # moved while this release was building, so the tree this job checked out is
  # not the tree the release started from. Nothing downstream can see that; this
  # warning is the only place it is visible.
  if [ -n "$from_file" ] && [ -n "$from_pipeline" ] && [ "$from_file" != "$from_pipeline" ]; then
    run_with_commands_stopped echo \
      "::warning title=release-version::This job checked out VERSION ${from_file} while the release is publishing ${from_pipeline}. main moved after the release started; tagging with ${from_pipeline} so every image of this run carries one version." >&2
  fi

  if [ -n "$from_pipeline" ]; then
    rv_trace "using the pipeline's version ${from_pipeline} (${file} ${file_state})"
    printf '%s\n' "$from_pipeline"
  else
    rv_trace "PIPELINE_VERSION ${pipeline_state}; using ${file}, which ${file_state}"
    printf '%s\n' "$from_file"
  fi
  return 0
}

# Executed rather than sourced: resolve, print, and hand the answer to the step
# that follows.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail

  RV_FILE='VERSION'
  RV_OUTPUT_NAME='version'
  RV_WRITE_OUTPUT=1

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --file)
        RV_FILE="${2:-}"
        shift 2
        ;;
      --output)
        RV_OUTPUT_NAME="${2:-}"
        shift 2
        ;;
      --no-output)
        RV_WRITE_OUTPUT=0
        shift
        ;;
      *)
        echo "::error title=release-version::Unknown argument: $1" >&2
        echo "usage: release-version.sh [--file PATH] [--output NAME] [--no-output]" >&2
        exit 2
        ;;
    esac
  done

  RV_VERSION="$(resolve_release_version "$RV_FILE")" || exit 1

  if [ "$RV_WRITE_OUTPUT" = "1" ] && [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$RV_OUTPUT_NAME" "$RV_VERSION" >>"$GITHUB_OUTPUT"
  fi

  # The line release.yml's two version steps used to print, kept: it is what a
  # reader scanning a release log looks for. On stderr, so that a caller reading
  # this script's stdout gets the version and nothing else - both streams are
  # the same step log on a runner.
  run_with_commands_stopped echo "Detected version: ${RV_VERSION}" >&2
  printf '%s\n' "$RV_VERSION"
fi
