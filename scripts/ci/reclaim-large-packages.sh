#!/usr/bin/env bash
# reclaim-large-packages.sh - remove the runner's pre-installed bulk packages.
#
# This is the `large-packages` half of jlumbroso/free-disk-space, done here
# because that half warns on every arm64 job we run (issue #121).
#
# The action removes fixed package names:
#
#   sudo apt-get remove -y azure-cli google-chrome-stable firefox powershell \
#     mono-devel libgl1-mesa-dri --fix-missing || echo "::warning::…"
#
# `ubuntu-24.04-arm` has no Google Chrome apt source - Google publishes no
# arm64 .deb repository - so apt stops at `E: Unable to locate package
# google-chrome-stable`, exits 100 without removing any of the six, and the
# action turns that into an annotation. Release run 34293699247 collected 28 of
# them, one per arm64 job, every one of them describing an absence rather than a
# fault. A warning that fires on every run of a green build teaches the reader
# to stop looking at warnings, which is the cost that matters.
#
# The names apt could not locate were never installed, so the correct set to
# remove is "the packages matching these patterns that dpkg reports as
# installed". That set is computed here and handed to apt, which means apt is
# asked only for things that exist: no unlocatable name, no warning, and the
# same packages removed. `libgl1-mesa-dri` is in the list because the action
# has it there; the aim is parity with the reclaim, minus the noise.
#
# Environment:
#   BOX_VERBOSE       1 to echo every command and the full package lists,
#                     default 0
#   RECLAIM_DRY_RUN   1 to print the plan and change nothing, default 0
#   DPKG_QUERY        the command listing installed packages, default
#                     `dpkg-query -W -f=${Package}\t${db:Status-Status}\n`
#                     (overridden by the regression suite)
#   APT_GET           the apt-get to call, default `sudo apt-get`
#
# Usage: bash scripts/ci/reclaim-large-packages.sh

set -uo pipefail

BOX_VERBOSE="${BOX_VERBOSE:-0}"
RECLAIM_DRY_RUN="${RECLAIM_DRY_RUN:-0}"
APT_GET="${APT_GET:-sudo apt-get}"

log() { echo "[reclaim] $*"; }
vlog() {
  [ "$BOX_VERBOSE" = "1" ] && echo "[reclaim] $*"
  return 0
}

# The action's patterns, kept in its order and its spelling. apt applies a
# POSIX regex to package names when an argument is not a plain name; grep -E
# applies the same regex the same way, unanchored unless the pattern anchors
# itself, so `php.*` still matches `libapache2-mod-php` exactly as apt's did.
PATTERNS=(
  '^aspnetcore-.*'
  '^dotnet-.*'
  '^llvm-.*'
  'php.*'
  '^mongodb-.*'
  '^mysql-.*'
  '^azure-cli$'
  '^google-chrome-stable$'
  '^firefox$'
  '^powershell$'
  '^mono-devel$'
  '^libgl1-mesa-dri$'
  '^google-cloud-sdk$'
  '^google-cloud-cli$'
)

# Only packages dpkg reports as fully installed. A package in state `config-
# files` (removed, conffiles kept) occupies no meaningful space and asking apt
# to remove it again is another way to get an exit code for nothing.
list_installed() {
  if [ -n "${DPKG_QUERY:-}" ]; then
    eval "$DPKG_QUERY"
  else
    dpkg-query -W -f='${Package}\t${db:Status-Status}\n' 2>/dev/null
  fi
}

INSTALLED="$(list_installed | awk -F'\t' '$2 == "installed" { print $1 }' | sort -u)"

if [ -z "$INSTALLED" ]; then
  log "dpkg reports no installed packages; nothing to do"
  exit 0
fi

vlog "$(printf '%s\n' "$INSTALLED" | wc -l) installed package(s) to match against ${#PATTERNS[@]} pattern(s)"

SELECTED=""
for pattern in "${PATTERNS[@]}"; do
  matched="$(printf '%s\n' "$INSTALLED" | grep -E -- "$pattern" || true)"
  if [ -n "$matched" ]; then
    vlog "$pattern -> $(printf '%s' "$matched" | tr '\n' ' ')"
    SELECTED="$SELECTED$matched"$'\n'
  else
    vlog "$pattern -> (nothing installed)"
  fi
done

mapfile -t PACKAGES < <(printf '%s' "$SELECTED" | grep -v '^$' | sort -u)

if [ "${#PACKAGES[@]}" -eq 0 ]; then
  log "none of the ${#PATTERNS[@]} bulk package patterns matched anything installed; nothing to remove"
  exit 0
fi

log "removing ${#PACKAGES[@]} installed package(s): ${PACKAGES[*]}"

if [ "$RECLAIM_DRY_RUN" = "1" ]; then
  log "RECLAIM_DRY_RUN=1, so nothing was removed"
  exit 0
fi

before="$(df --output=avail -k / 2>/dev/null | tail -1 | tr -d ' ')"

# `--fix-missing` matches the action. A failure here is worth saying out loud -
# unlike the absences above, it means apt could not remove something that is
# actually installed - but it is not worth failing the job over: the reclaim is
# an optimisation, and the build that follows is what should report running out
# of disk.
if ! $APT_GET remove -y --fix-missing "${PACKAGES[@]}"; then
  echo "::warning title=reclaim-large-packages::apt-get could not remove every selected package. The packages were all reported installed by dpkg, so this is a real apt failure rather than an absent package; the build continues with less disk than expected."
fi

for step in autoremove clean; do
  if ! $APT_GET "$step" -y; then
    echo "::warning title=reclaim-large-packages::apt-get $step failed. The build continues with less disk than expected."
  fi
done

after="$(df --output=avail -k / 2>/dev/null | tail -1 | tr -d ' ')"
if [ -n "$before" ] && [ -n "$after" ]; then
  log "reclaimed $(((after - before) / 1024)) MB from / (now $((after / 1024 / 1024)) GB available)"
fi
