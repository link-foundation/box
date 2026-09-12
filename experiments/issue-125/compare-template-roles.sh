#!/usr/bin/env bash
# Produce a language-neutral role matrix from the complete tracked trees stored
# by snapshot-templates.sh. Pass --workflows for workflow filenames instead of
# CI/CD script roles.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
trees="${repo_root}/dev/log/issues/125/pulls/126/templates"
mode="${1:-scripts}"
names=(box js python rust php)
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

role_of() {
  local path="$1" base
  if [ "${mode}" = '--workflows' ]; then
    case "${path}" in .github/workflows/*) base="${path##*/}" ;; *) return ;; esac
    printf '%s\n' "${base%.yml}"
    return
  fi

  case "${path}" in
    .github/workflows/* | .github/actions/*) return ;;
    scripts/* | .githooks/*) ;;
    *) return ;;
  esac
  base="${path##*/}"
  case "${base}" in *.mjs | *.js | *.sh | *.py | *.php | *.rs | *.ts) ;; *) return ;; esac
  base="${base%.*}"
  base="${base%.test}"
  base="${base#test_}"
  base="${base#test-}"
  printf '%s\n' "${base//_/-}"
}

for name in "${names[@]}"; do
  while IFS= read -r path; do role_of "${path}"; done \
    <"${trees}/${name}.file-tree.txt" | sort -u >"${work}/${name}.txt"
done

cat "${work}"/*.txt | sort -u >"${work}/all.txt"
printf 'role'
for name in "${names[@]}"; do printf '\t%s' "${name}"; done
printf '\n'
while IFS= read -r role; do
  printf '%s' "${role}"
  for name in "${names[@]}"; do
    if grep -qxF "${role}" "${work}/${name}.txt"; then printf '\tx'; else printf '\t.'; fi
  done
  printf '\n'
done <"${work}/all.txt"

printf '\n# %s role(s) total\n' "$(wc -l <"${work}/all.txt")"
for name in "${names[@]}"; do
  printf '# %-6s %3s role(s)\n' "${name}" "$(wc -l <"${work}/${name}.txt")"
done
