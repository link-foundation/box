#!/usr/bin/env bash
# Build the role-by-role matrix issue #123 asks for: "compare the full file tree
# of every GitHub workflow and CI/CD script" against the seven
# link-foundation/*-ai-driven-development-pipeline-template repositories.
#
# A role is a script's job, not its filename: the same job is
# `check-file-size.mjs` in js, `check_file_size.py` in python and
# `check-file-size.sh` in php, so the name is normalised by dropping the
# extension and mapping `_` to `-`. Test files (`*.test.*`, `test_*`) are folded
# onto the role they test rather than counted as roles of their own.
#
# Reads the snapshots under dev/log/issues/123/pulls/124/templates/ that
# snapshot-templates.sh collected, so it is offline and reproducible: rerunning
# it a month from now compares the same revisions, which is the point of pinning
# them in SNAPSHOT.txt.
#
# Usage:
#   bash experiments/issue-123/compare-template-roles.sh [--workflows]
#
#   (no argument)  the script-role matrix
#   --workflows    the workflow-file matrix instead
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATES="$REPO_ROOT/dev/log/issues/123/pulls/124/templates"
MODE="${1:-scripts}"

NAMES=(box js python rust php csharp go java)

# Normalise one path to a role, or print nothing when the path is not one.
role_of() {
  local path="$1" base
  case "$MODE" in
    --workflows)
      case "$path" in
        .github/workflows/*) base="${path##*/}" ;;
        *) return ;;
      esac
      printf '%s\n' "${base%.yml}"
      return
      ;;
  esac

  case "$path" in
    .github/workflows/* | .github/actions/*) return ;;
    scripts/* | .githooks/*) ;;
    *) return ;;
  esac

  base="${path##*/}"
  case "$base" in
    *.mjs | *.js | *.sh | *.py | *.php | *.rs | *.ts) ;;
    *) return ;;
  esac

  base="${base%.*}"
  base="${base%.test}"
  base="${base#test_}"
  base="${base#test-}"
  printf '%s\n' "${base//_/-}"
}

roles_for() {
  local name="$1" tree="$TEMPLATES/${1}.file-tree.txt" path
  [ -f "$tree" ] || return
  while IFS= read -r path; do
    role_of "$path"
  done <"$tree" | sort -u
}

for name in "${NAMES[@]}"; do
  roles_for "$name" >"/tmp/roles-${name}.txt"
done

cat /tmp/roles-*.txt | sort -u >/tmp/roles-all.txt

printf 'role'
for name in "${NAMES[@]}"; do printf '\t%s' "$name"; done
printf '\n'

while IFS= read -r role; do
  printf '%s' "$role"
  for name in "${NAMES[@]}"; do
    if grep -qxF "$role" "/tmp/roles-${name}.txt"; then printf '\tx'; else printf '\t.'; fi
  done
  printf '\n'
done </tmp/roles-all.txt

printf '\n# %s role(s) total\n' "$(wc -l </tmp/roles-all.txt)"
for name in "${NAMES[@]}"; do
  printf '# %-7s %3s role(s)\n' "$name" "$(wc -l <"/tmp/roles-${name}.txt")"
done
