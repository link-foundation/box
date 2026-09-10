#!/usr/bin/env bash
# File the upstream reports of issue #123 as GitHub issues, one per recipient.
#
# The bodies are the rendered/hand-authored files in
# dev/log/issues/123/pulls/124/upstream/filed/<report>.md, whose first line is
# the issue title and whose remainder is the body. Each body promises its
# reproduction fixture "attached below", so this script appends the fixture
# itself in a collapsed <details> block: an upstream reader must be able to run
# the reproduction without cloning box.
#
# Default is a dry run that writes what it would file to a directory and prints
# a plan. Pass --execute to create the issues.
#
#   bash experiments/issue-123/file-upstream-reports.sh              # plan only
#   bash experiments/issue-123/file-upstream-reports.sh --execute
#   bash experiments/issue-123/file-upstream-reports.sh --only F-rust... --execute
#
# Filing is recorded in upstream/filed/index.tsv (report, repo, url), appended
# as each issue is created, so an interrupted run can be resumed: a report
# already present in the index is skipped.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FILED="${ROOT}/dev/log/issues/123/pulls/124/upstream/filed"
EXPERIMENTS="${ROOT}/experiments/issue-123"
INDEX="${FILED}/index.tsv"
RENDERED="${ROOT}/dev/log/issues/123/pulls/124/upstream/rendered"

execute=0
only=""
while [ $# -gt 0 ]; do
  case "$1" in
    --execute) execute=1 ;;
    --only)
      shift
      only="$1"
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

# report -> recipient repository (short name), and report -> fixture list.
# D-csharp-53-comment is a comment on an existing issue, not a new one.
repo_of() {
  case "$1" in
    *-js) echo js ;;
    *-python) echo python ;;
    *-rust) echo rust ;;
    *-php) echo php ;;
    *-csharp) echo csharp ;;
    *-go) echo go ;;
    *-java) echo java ;;
    E-csharp-exec-injection) echo csharp ;;
    F-java-changeset-not-validated) echo java ;;
    F-rust-checks-swallow-git-failures) echo rust ;;
    *) return 1 ;;
  esac
}

fixtures_of() {
  case "$1" in
    A-*) echo repro-supersede.sh ;;
    B-*) echo repro-budget-survivor.sh ;;
    C-*) echo repro-log-injection-changeset.sh ;;
    D-*) echo repro-dispatch-description-injection.sh ;;
    E-*) echo repro-csharp-exec-escaping.sh ;;
    F-*) echo "repro-changeset-validation-fallback.sh probe-shallow-base-ref.sh" ;;
  esac
}

# A caption for the fixtures a report attaches without naming in its prose, so a
# reader knows which measurement each one produced.
caption_of() {
  case "$1" in
    probe-shallow-base-ref.sh)
      echo "The probe behind the \`fetch before the diff\` table: it builds a shallow single-branch clone and asks the same diff after each of the five fetch forms."
      ;;
  esac
}

body_of() {
  local report="$1" fixture caption
  tail -n +2 "${FILED}/${report}.md"
  echo
  echo "### The fixtures, so this is runnable without cloning \`box\`"
  echo
  for fixture in $(fixtures_of "$report"); do
    caption="$(caption_of "${fixture}")"
    [ -n "${caption}" ] && {
      echo "${caption}"
      echo
    }
    echo "<details>"
    echo "<summary><code>experiments/issue-123/${fixture}</code></summary>"
    echo
    echo '```bash'
    cat "${EXPERIMENTS}/${fixture}"
    echo '```'
    echo
    echo "</details>"
    echo
  done
}

mkdir -p "${RENDERED}"
touch "${INDEX}"

planned=0
for path in "${FILED}"/*.md; do
  report="$(basename "${path}" .md)"
  [ -n "${only}" ] && [ "${report}" != "${only}" ] && continue
  if ! repo="$(repo_of "${report}")"; then
    echo "skip  ${report} (not a new issue; file it by hand)"
    continue
  fi
  if grep -q "^${report}	" "${INDEX}"; then
    echo "done  ${report} -> $(awk -F'\t' -v r="${report}" '$1==r {print $3}' "${INDEX}")"
    continue
  fi
  title="$(head -1 "${path}")"
  full="link-foundation/${repo}-ai-driven-development-pipeline-template"
  body_of "${report}" >"${RENDERED}/${report}.body.md"
  bytes="$(wc -c <"${RENDERED}/${report}.body.md" | tr -d ' ')"
  planned=$((planned + 1))
  echo "plan  ${report} -> ${full} (${bytes} bytes)"
  echo "        ${title}"
  if [ "${execute}" = 1 ]; then
    url="$(gh issue create --repo "${full}" --title "${title}" \
      --body-file "${RENDERED}/${report}.body.md")"
    printf '%s\t%s\t%s\n' "${report}" "${full}" "${url}" >>"${INDEX}"
    echo "        filed ${url}"
  fi
done

echo
if [ "${execute}" = 1 ]; then
  echo "filed ${planned} issue(s); index: ${INDEX#"${ROOT}"/}"
else
  echo "${planned} issue(s) would be filed; bodies written to ${RENDERED#"${ROOT}"/}"
  echo "re-run with --execute to create them"
fi
