#!/usr/bin/env bash
# Census every warning and error in the nine runs issue #123 lists.
#
# The issue asks for "all false positives, false negatives, warnings and errors"
# to be found and fixed, so the first question is how many there are. GitHub's
# annotation API answers only part of it: an annotation exists only where a tool
# emitted a `##[…]` workflow command or the runner itself failed a step, and the
# nine runs carry seven of those (../annotations/README.md). Everything else a
# tool warned about is in the log text and in no API.
#
# So this reads the logs instead, and classifies every line carrying the word
# `warn`/`error` rather than counting them, because the raw count is dominated by
# text that is neither a warning nor an error: apt's `E:`-free progress output,
# a CodeQL action printing its own `--verbosity` help, and this repository's own
# suites printing `PASS: … warns without failing` on purpose.
#
# Classes, in the order they are tested (first match wins):
#
#   annotation      a `##[error|warning|notice]` workflow command -- the lines
#                   that become GitHub annotations
#   step-script     the runner echoing the step's own `run:` text back, which it
#                   does in cyan and under `##[group]Run `; the text of an
#                   `echo "==> WARNING: ..."` is not a warning. `gh run view
#                   --log` writes the escape as the two characters `^` `[`, not
#                   as an ESC byte -- checked with `od -c` before matching it.
#   assertion       a suite's own PASS/ok line naming a warning it asserts about
#   action-help     an action printing its own input schema (CodeQL does this)
#   docker-build    a BuildKit `#NN` progress line
#   tool            everything else: a tool talking about a warning or an error
#
# Only the `annotation` and `tool` classes can hold a defect. Usage:
#   bash experiments/issue-123/census-warnings-errors.sh [OUT_DIR]
set -uo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
log_dir="${repo_root}/dev/log/issues/123/pulls/124/ci-logs"
out_dir="${1:-${repo_root}/dev/log/issues/123/pulls/124/analysis}"
mkdir -p "${out_dir}"

[ -d "${log_dir}" ] || {
  echo "no logs at ${log_dir}" >&2
  exit 1
}

classify() {
  # Reads `job<TAB>step<TAB>text`, writes `class<TAB>job<TAB>text`.
  awk -F'\t' '
    {
      job = $1
      text = $0
      sub(/^[^\t]*\t[^\t]*\t/, "", text)
      # Strip the leading ISO timestamp the runner prefixes to every line.
      sub(/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z /, "", text)
      lower = tolower(text)
      if (lower !~ /warn|error/) next

      if (text ~ /##\[(error|warning|notice)\]/)                 class = "annotation"
      else if (text ~ /\^\[\[36;1m/ || text ~ /##\[group\]Run /)    class = "step-script"
      else if (text ~ /^(PASS|ok|FAIL|  ok|  PASS)[: ]/)         class = "assertion"
      else if (text ~ /^ *"(description|title|pattern)" *:/)     class = "action-help"
      else if (text ~ /^#[0-9]+ /)                               class = "docker-build"
      else                                                       class = "tool"
      printf "%s\t%s\t%s\n", class, job, text
    }
  '
}

raw="${out_dir}/warnings-errors.raw.tsv"
: >"${raw}"
for f in "${log_dir}"/*.log.gz "${log_dir}"/jobs/*.log.gz "${log_dir}"/release-*/*.log.gz; do
  [ -e "${f}" ] || continue
  run=$(basename "${f}" .log.gz)
  zcat "${f}" | classify | sed "s|^|${run}\t|"
done >>"${raw}"

summary="${out_dir}/warnings-errors.census.md"
{
  echo "# Every line in the nine runs that says \`warn\` or \`error\`"
  echo
  echo "Regenerate with \`bash experiments/issue-123/census-warnings-errors.sh\`."
  echo "Columns of \`warnings-errors.raw.tsv\`: source, class, job, text."
  echo
  echo "| Class | Lines | Distinct texts |"
  echo "| --- | ---: | ---: |"
  for class in annotation tool assertion action-help step-script docker-build; do
    lines=$(awk -F'\t' -v c="${class}" '$2 == c' "${raw}" | wc -l)
    distinct=$(awk -F'\t' -v c="${class}" '$2 == c {print $4}' "${raw}" | sort -u | wc -l)
    printf '| `%s` | %s | %s |\n' "${class}" "${lines}" "${distinct}"
  done
  echo
  echo "## Every \`annotation\` line, deduplicated"
  echo
  echo '```'
  awk -F'\t' '$2 == "annotation" {printf "%s | %s\n", $3, substr($4, 1, 160)}' "${raw}" | sort | uniq -c | sort -rn
  echo '```'
  echo
  echo "## Every \`tool\` line, deduplicated"
  echo
  echo '```'
  awk -F'\t' '$2 == "tool" {printf "%s | %s\n", $3, substr($4, 1, 160)}' "${raw}" | sort | uniq -c | sort -rn
  echo '```'
  echo
  echo "## Every \`docker-build\` line that is a warning, deduplicated"
  echo
  echo "The class is large (a package name containing \`error\` is in it) and"
  echo "almost all of it is neither a warning nor an error, so this is the subset"
  echo "where a tool inside the build said the word in the first person. The"
  echo "\`#NN N.NN\` BuildKit prefix is stripped so the same line from two"
  echo "architectures folds together."
  echo
  echo '```'
  awk -F'\t' '$2 == "docker-build" && $4 ~ /(^|[^a-z])([Ww]arning|WARNING|warn)([^a-z]|$)/ {
                 line = $4
                 sub(/^#[0-9]+ +[0-9.]+ +/, "", line)
                 print substr(line, 1, 160)
               }' "${raw}" | sort | uniq -c | sort -rn
  echo '```'
} >"${summary}"

echo "wrote ${raw} ($(wc -l <"${raw}") lines) and ${summary}"
