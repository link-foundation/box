#!/usr/bin/env bash
# test-issue115-links-gate.sh
#
# Issue #115, best practice #12 (documentation validation). Pins the link
# checker and, more importantly, the policy that keeps it honest.
#
# Nothing in this repository had ever resolved a URL. The first lychee run over
# the tracked markdown reported 113 failures over 16 files - 107 distinct URLs:
# case studies citing CI logs GitHub had already deleted (90-day retention), 85
# README links to GHCR packages that were never published, an OWASP page that
# 404s, a GitHub repository that had been transferred. Every one of them was
# fixed in the diff. The failure mode this suite exists to prevent is the cheap
# alternative - moving a dead link into .lycheeignore, which turns a real
# finding into permanent silence.
#
# So the assertions are of two kinds:
#   1. the gate exists, is wired to files that exist, and reports a failure
#      rather than a green tick (lychee's own `fail: false` + an explicit step);
#   2. .lycheeignore silences only URLs that are correct-but-unverifiable, and
#      no pattern in it is broad enough to cover a URL this repository relies
#      on being right.
#
# Static assertions plus offline unit tests of the Wayback parser. Set
# LINKS_LIVE=1 to also run lychee for real (needs docker + network).
#
# Usage: bash experiments/test-issue115-links-gate.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

IGNORE=".lycheeignore"
# The image the workflow's comments tell a reader to reproduce with; the
# fixtures below use the same one so "it passes locally" means the same thing.
LYCHEE_IMAGE="lycheeverse/lychee:0.24.2"
WORKFLOW=".github/workflows/links.yml"
ARCHIVE="scripts/ci/check-web-archive.mjs"
PASS=0
FAIL=0

pass() {
  echo "PASS: $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "FAIL: $1"
  FAIL=$((FAIL + 1))
}

for f in "$IGNORE" "$WORKFLOW" "$ARCHIVE"; do
  if [ -f "$f" ]; then
    pass "$f exists"
  else
    fail "$f is missing"
  fi
done

if [ "$FAIL" -gt 0 ]; then
  echo
  echo "$PASS passed, $FAIL failed"
  exit 1
fi

WORKFLOW_SRC="$(cat "$WORKFLOW")"

# --- the gate is wired to files that exist ------------------------------------

# A workflow that runs a script which is not in the tree fails at the step, not
# at review time; issue #115 already found one such reference (RC-15).
MISSING=0
while IFS= read -r referenced; do
  [ -n "$referenced" ] || continue
  if [ ! -f "$referenced" ]; then
    fail "$WORKFLOW runs $referenced, which does not exist"
    MISSING=$((MISSING + 1))
  fi
done < <(grep -oE '(scripts|experiments)/[A-Za-z0-9._/-]+\.(sh|mjs|js|py)' "$WORKFLOW" | sort -u)
[ "$MISSING" -eq 0 ] && pass "every script $WORKFLOW runs exists in the tree"

if node --check "$ARCHIVE" 2>/dev/null; then
  pass "$ARCHIVE parses as an ES module"
else
  fail "$ARCHIVE has a syntax error"
fi

# --- the gate reports rather than passes --------------------------------------

# lychee-action's `fail: false` is deliberate: the run has to reach the Wayback
# lookup and the summary before it fails. That only stays true while an
# explicit step turns a non-zero lychee exit code back into a failed job.
if [[ "$WORKFLOW_SRC" == *"fail: false"* ]]; then
  pass "lychee itself does not abort the job (the later steps still run)"
else
  fail "lychee aborts the job, so the Wayback lookup and summary never run"
fi

if [[ "$WORKFLOW_SRC" == *"steps.lychee.outputs.exit_code != 0"* ]] \
  && [[ "$WORKFLOW_SRC" == *"exit 1"* ]]; then
  pass "a non-zero lychee exit code fails the job explicitly"
else
  fail "nothing turns a non-zero lychee exit code into a failed job"
fi

if [[ "$WORKFLOW_SRC" == *"jobSummary: true"* ]]; then
  pass "the broken-link report is written to the job summary"
else
  fail "the report is not surfaced in the job summary"
fi

if [[ "$WORKFLOW_SRC" == *"--exclude-path dev/log"* ]]; then
  pass "the vendored evidence tree is excluded, like every other linter here"
else
  fail "dev/log is not excluded; other projects' links are not ours to fix"
fi

# Issue #121. Without --include-fragments lychee resolves the document and
# stops, so every `#anchor` in the tree was unchecked: a heading rename broke
# the link and this gate stayed green. Part 6 below proves the flag is what
# makes the difference; this asserts it is still passed.
if [[ "$WORKFLOW_SRC" == *"--include-fragments"* ]]; then
  pass "anchors are checked, not just the documents they point into"
else
  fail "--include-fragments is not passed; a renamed heading breaks links silently"
fi

# The failure message hands the reader a command to reproduce with. A command
# that omits a flag the job uses reproduces something else, and the difference
# shows up as "it passes locally" - the same drift as a stale README.
REPRODUCE_LINES="$(grep -c -- '--include-fragments' "$WORKFLOW")"
if [ "$REPRODUCE_LINES" -ge 3 ]; then
  pass "the header comment, the args and the failure message all carry the flag"
else
  fail "--include-fragments appears $REPRODUCE_LINES time(s); the documented reproduce command does not match the job"
fi

if [[ "$WORKFLOW_SRC" == *"schedule:"* ]] && [[ "$WORKFLOW_SRC" == *"cron:"* ]]; then
  pass "the check is also scheduled: a link rots without anyone touching the repo"
else
  fail "the check only runs on changes, so link rot is never noticed"
fi

if [[ "$WORKFLOW_SRC" == *"timeout-minutes:"* ]]; then
  pass "the job has a timeout"
else
  fail "the job has no timeout; a hung fetch would burn a runner for 6 hours"
fi

# --- .lycheeignore policy -----------------------------------------------------

# Read the patterns once: comments and blank lines are not patterns.
mapfile -t PATTERNS < <(grep -vE '^\s*(#|$)' "$IGNORE")

if [ "${#PATTERNS[@]}" -gt 0 ]; then
  pass "${#PATTERNS[@]} ignore pattern(s) are defined"
else
  fail "$IGNORE has no patterns"
fi

# Every pattern must carry a reason. The file is the only place where a real
# finding can be made to disappear, so an unexplained line is not allowed.
if grep -qE '^\s*#.*false positive' "$IGNORE"; then
  pass "$IGNORE states the rule it is applying"
else
  fail "$IGNORE does not state why an entry is allowed"
fi

# No pattern may swallow a URL the repository depends on being correct. These
# are load-bearing: the Docker Hub repositories that hold every published box,
# the repository itself, and the upstream projects the case studies cite.
LOAD_BEARING=(
  "https://hub.docker.com/r/konard/box-js"
  "https://github.com/link-foundation/box"
  "https://github.com/link-foundation/box/issues/115"
  "https://github.com/link-assistant/hive-mind/blob/main/docs/CI-CD-BEST-PRACTICES.md"
  "https://docs.docker.com/build/ci/github-actions/"
  "https://archive.org/help/wayback_api.php"
)
for url in "${LOAD_BEARING[@]}"; do
  hit=""
  for p in "${PATTERNS[@]}"; do
    if printf '%s' "$url" | grep -qE -- "$p"; then
      hit="$p"
      break
    fi
  done
  if [ -z "$hit" ]; then
    pass "no ignore pattern silences $url"
  else
    fail "pattern '$hit' silences $url, a URL that must stay verified"
  fi
done

# --- the Wayback parser -------------------------------------------------------

# The parser decides what counts as broken. A regression here is silent: it
# would report "no broken URLs found" on a report full of them.
NODE_TESTS="$(mktemp -t links-gate-XXXXXX.mjs)"
FIXTURE_DIR="$(mktemp -d -t links-gate-XXXXXX)"
trap 'rm -f "$NODE_TESTS"; rm -rf "$FIXTURE_DIR"' EXIT

cat >"$NODE_TESTS" <<'NODE'
const { extractBrokenLinks, extractErrorsSection, formatTimestamp } =
  await import(process.env.ARCHIVE_MODULE);

const results = [];
const check = (ok, name) => results.push([ok, name]);

const report = `# Summary

| Status | Count |
|--------|-------|
| 🚫 Errors | 2 |

## Errors per input

### Errors in README.md

* [404] https://example.org/gone | Not Found
* [ERROR] <docs/missing.md> | Cannot find file

## Redirects per input

### Redirects in README.md

* [301] https://example.org/moved | Moved Permanently
`;

const section = extractErrorsSection(report);
check(!section.includes('example.org/moved'),
  'the redirects section is not scanned (a redirect is not a broken link)');

const { urls, others } = extractBrokenLinks(report);
check(urls.length === 1 && urls[0] === 'https://example.org/gone',
  'a 404 URL is extracted as a broken URL');
check(others.length === 1 && others[0] === 'docs/missing.md',
  'a missing local file is extracted as unarchivable, not as a URL');

const dupes = extractBrokenLinks(`## Errors per input

* [404] https://example.org/gone
* [500] https://example.org/gone
`);
check(dupes.urls.length === 1, 'the same broken URL is reported once');

const noHeading = extractBrokenLinks('* [404] https://example.org/gone\n');
check(noHeading.urls.length === 1,
  'a report without the "Errors per input" heading is still parsed in full');

check(formatTimestamp('20231015143022') === '2023-10-15',
  'a Wayback timestamp renders as a date');

let bad = 0;
for (const [ok, name] of results) {
  console.log(`${ok ? 'PASS' : 'FAIL'}: ${name}`);
  if (!ok) bad++;
}
process.exit(bad === 0 ? 0 : 1);
NODE

NODE_OUT="$(ARCHIVE_MODULE="$(pwd)/$ARCHIVE" node "$NODE_TESTS" 2>&1)"
NODE_STATUS=$?
while IFS= read -r line; do
  case "$line" in
    PASS:*) pass "${line#PASS: }" ;;
    FAIL:*) fail "${line#FAIL: }" ;;
    *) [ -n "$line" ] && echo "      $line" ;;
  esac
done <<<"$NODE_OUT"
if [ "$NODE_STATUS" -ne 0 ] && ! grep -q '^FAIL:' <<<"$NODE_OUT"; then
  fail "the parser unit tests did not run: $NODE_OUT"
fi

# --- the script's exit codes --------------------------------------------------

# No report at all means lychee never ran; that is not a documentation failure,
# and the workflow's own step ordering already covers it.
if LYCHEE_OUTPUT="$FIXTURE_DIR/absent.md" node "$ARCHIVE" >/dev/null 2>&1; then
  pass "a missing lychee report is skipped, not failed"
else
  fail "a missing lychee report fails the check"
fi

# A broken link the Wayback Machine cannot answer for has to fail, and this
# path reaches the exit without any network access.
cat >"$FIXTURE_DIR/local.md" <<'MD'
## Errors per input

* [ERROR] <docs/missing.md> | Cannot find file
MD
if LYCHEE_OUTPUT="$FIXTURE_DIR/local.md" node "$ARCHIVE" >/dev/null 2>&1; then
  fail "a broken local link exits 0; the gate would pass with a dead link"
else
  pass "a broken local link fails the check (no archive can answer for it)"
fi

cat >"$FIXTURE_DIR/clean.md" <<'MD'
# Summary

| Status | Count |
|--------|-------|
| ✅ Successful | 42 |
MD
if LYCHEE_OUTPUT="$FIXTURE_DIR/clean.md" node "$ARCHIVE" >/dev/null 2>&1; then
  pass "a clean report passes"
else
  fail "a clean report fails the check"
fi

# --- the fragment flag is load-bearing ----------------------------------------

# Asserting that a flag is present is not the same as knowing what it does, and
# what it does is the whole finding: run the same corpus with it and without it
# and only one of the two reports the broken anchor. `--offline` keeps this to
# the filesystem, so the fixture needs docker but no network and finishes in
# milliseconds once the image is local.
echo "--- the --include-fragments mutation fixture ---"
FRAG_SKIP=""
if ! command -v docker >/dev/null 2>&1; then
  FRAG_SKIP="docker is not on PATH"
elif ! docker image inspect "$LYCHEE_IMAGE" >/dev/null 2>&1 \
  && ! docker pull -q "$LYCHEE_IMAGE" >/dev/null 2>&1; then
  FRAG_SKIP="$LYCHEE_IMAGE could not be pulled"
fi

if [ -n "$FRAG_SKIP" ]; then
  # Named, not silent: the reader has to be able to tell "this passed" from
  # "this did not run". The CI runners have docker, so this is a local-only
  # gap.
  echo "SKIP: the fragment mutation fixture did not run ($FRAG_SKIP)"
else
  FRAG_DIR="$FIXTURE_DIR/fragments"
  mkdir -p "$FRAG_DIR"
  cat >"$FRAG_DIR/a.md" <<'MD'
# Title

See [the section](#the-section) and [another file](b.md#other-heading).
MD
  cat >"$FRAG_DIR/b.md" <<'MD'
# B

## Other Heading
MD

  frag_run() {
    docker run --rm -v "$FRAG_DIR:/repo" -w /repo "$LYCHEE_IMAGE" \
      --no-progress --offline "$@" './**/*.md' 2>&1
  }

  # Intact: the same-file heading exists, so both anchors resolve.
  printf '\n## The Section\n' >>"$FRAG_DIR/a.md"
  if frag_run --include-fragments | grep -q '0 Errors'; then
    pass "with the flag, anchors that resolve are reported OK (no false positive)"
  else
    fail "with the flag, valid anchors are reported broken"
  fi

  # Rename both targets: one same-file anchor, one cross-file anchor.
  sed -i 's/## The Section/## Renamed Section/' "$FRAG_DIR/a.md"
  sed -i 's/## Other Heading/## Renamed Other/' "$FRAG_DIR/b.md"

  BROKEN_WITH="$(frag_run --include-fragments)"
  if grep -q 'a.md#the-section' <<<"$BROKEN_WITH"; then
    pass "with the flag, a renamed same-file heading is reported broken"
  else
    fail "with the flag, a renamed same-file heading is not reported"
  fi
  if grep -q 'b.md#other-heading' <<<"$BROKEN_WITH"; then
    pass "with the flag, a renamed heading in another file is reported broken"
  else
    fail "with the flag, a cross-file anchor is not checked"
  fi

  # The false negative this repository shipped until issue #121: the identical
  # corpus, one flag short, reports nothing wrong.
  BROKEN_WITHOUT="$(frag_run)"
  if grep -q '0 Errors' <<<"$BROKEN_WITHOUT"; then
    pass "without the flag the same broken anchors pass, so the flag is what checks them"
  else
    fail "the fixture does not isolate the flag: the run without it also fails"
  fi
fi

# --- optional live run --------------------------------------------------------

if [ "${LINKS_LIVE:-0}" = "1" ]; then
  echo "--- LINKS_LIVE=1: running lychee over the tracked markdown ---"
  if docker run --rm -v "$PWD:/repo" -w /repo "$LYCHEE_IMAGE" \
    --no-progress --include-fragments --exclude-path dev/log './**/*.md'; then
    pass "the live link check passes"
  else
    fail "the live link check found broken links"
  fi
else
  echo "note: set LINKS_LIVE=1 to run lychee for real (needs docker + network)"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
