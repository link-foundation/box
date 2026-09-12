#!/usr/bin/env bash
# Classify every log line containing "warn" or "error" in the nine runs named
# by issue #125. Only annotation/tool lines can be defects; the other classes
# prevent echoed scripts, tests, schemas, and BuildKit progress from inflating
# the result.
set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
evidence="${repo_root}/dev/log/issues/125/pulls/126"
log_dir="${evidence}/ci-logs"
out_dir="${1:-${evidence}/analysis}"
mkdir -p "${out_dir}"

classify() {
  awk -F'\t' '
    BEGIN { esc = sprintf("%c", 27); commands_stopped = 0 }
    {
      job = $1
      text = $0
      sub(/^[^\t]*\t[^\t]*\t/, "", text)
      sub(/^[[:space:]]*[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z /, "", text)
      sub(/[[:space:]]+$/, "", text)

      # GitHub masks the random stop token in archived logs, but preserves the
      # stop/resume pair. Text between them is deliberately inert and cannot
      # create an annotation even when it quotes `##[error]`.
      if (text ~ /^::stop-commands::/) { commands_stopped = 1; next }
      if (commands_stopped && text ~ /^::\*\*\*::$/) { commands_stopped = 0; next }

      lower = tolower(text)
      if (lower !~ /warn|error/) next

      if (commands_stopped)                                        class = "bracketed-text"
      else if (text ~ /##\[(error|warning|notice)\]/)             class = "annotation"
      else if (index(text, esc "[36;1m") || text ~ /\^\[\[36;1m/ || text ~ /##\[group\]Run /)
                                                                    class = "step-script"
      else if (text ~ /^(PASS|ok|FAIL|  ok|  PASS)[: ]/)           class = "assertion"
      else if (text ~ /^ *"(description|title|pattern)" *:/)      class = "action-help"
      else if (text ~ /^#[0-9]+ /)                                 class = "docker-build"
      else                                                          class = "tool"
      printf "%s\t%s\t%s\n", class, job, text
    }
  '
}

raw="${out_dir}/warnings-errors.raw.tsv"
: >"${raw}"

# The aggregate release log needs more API requests than `gh run view` permits,
# so its official log archive is unpacked one job per text file. The other
# eight are their complete `gh run view --log` streams.
for file in "${log_dir}"/34455018*.log.gz; do
  [ -e "${file}" ] || continue
  [ "$(basename "${file}")" = '34455018919.log.gz' ] && continue
  source="$(basename "${file}" .log.gz)"
  zcat "${file}" | classify | sed "s|^|${source}\t|"
done >>"${raw}"

for file in "${log_dir}"/build-release-34455018919-jobs/*.txt.gz; do
  [ -e "${file}" ] || continue
  job="$(basename "${file}" .txt.gz)"
  zcat "${file}" | sed "s|^|${job}\t\t|" | classify \
    | sed 's|^|34455018919\t|'
done >>"${raw}"

summary="${out_dir}/warnings-errors.census.md"
{
  echo '# Warning/error text census for all nine issue #125 runs'
  echo
  echo 'Regenerate with `bash experiments/issue-125/census-warnings-errors.sh`.'
  echo 'The raw TSV columns are source, class, job, text.'
  echo
  echo '| Class | Lines | Distinct texts |'
  echo '| --- | ---: | ---: |'
  for class in annotation tool bracketed-text assertion action-help step-script docker-build; do
    lines="$(awk -F'\t' -v c="${class}" '$2 == c' "${raw}" | wc -l)"
    distinct="$(awk -F'\t' -v c="${class}" '$2 == c {print $4}' "${raw}" | sort -u | wc -l)"
    printf '| `%s` | %s | %s |\n' "${class}" "${lines}" "${distinct}"
  done
  for class in annotation tool; do
    echo
    echo "## Every \`${class}\` line, deduplicated"
    echo
    echo '```text'
    awk -F'\t' -v c="${class}" '$2 == c {
        text = substr($4, 1, 220); sub(/[[:space:]]+$/, "", text)
        printf "%s | %s\n", $3, text
      }' "${raw}" \
      | sort | uniq -c | sort -rn
    echo '```'
  done
  echo
  echo '## BuildKit lines containing a warning token, deduplicated'
  echo
  echo '```text'
  awk -F'\t' '$2 == "docker-build" && tolower($4) ~ /(^|[^a-z])warn(ing)?([^a-z]|$)/ {
      line = $4; sub(/^#[0-9]+ +[0-9.]+ +/, "", line); print substr(line, 1, 220)
    }' "${raw}" | sort | uniq -c | sort -rn
  echo '```'
} >"${summary}"

echo "wrote ${raw} ($(wc -l <"${raw}") lines) and ${summary}"
