#!/usr/bin/env bash
# test-issue123-sigpipe-writers.sh
#
# Issue #123. `producer | head` is not safe on a GitHub Actions runner.
#
# The defect. Two of the nine runs the issue lists carry error text that no
# check emitted and nothing acted on:
#
#   run 34366975942, security / secretlint
#     tr: write error: Broken pipe          (twice, from run-secretlint.sh's
#                                            canary generator)
#   run 34366976358, full / docker-build-push
#     grep: write error: Broken pipe
#     tr: write error: Broken pipe          (from resolve_node_lts_major)
#
# In both, a reader exits before its writer is done. Normally the writer then
# dies of SIGPIPE, silently, which is why neither line ever appeared on a
# developer's terminal. A runner step is not that environment: its shell is
# started with SIGPIPE already set to SIG_IGN, bash passes an inherited SIG_IGN
# on to the commands it starts, and an ignored SIGPIPE turns the failed write
# into EPIPE - reported on stderr, non-zero exit. Under `set -o pipefail`, which
# both files set, that status is the pipeline's.
#
# `trap '' PIPE` is the same disposition, so every assertion below is offline
# and takes no runner.
#
# What is asserted: the retired shapes still reproduce (a fixture that cannot
# fail proves nothing), the shipped replacements are clean under both
# dispositions, they still answer correctly, and no tracked script has grown a
# new unbounded writer feeding an early-exiting reader.
#
# Usage: bash experiments/test-issue123-sigpipe-writers.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"

PASS=0
FAIL=0
pass() {
  PASS=$((PASS + 1))
  echo "PASS: $1"
}
fail() {
  FAIL=$((FAIL + 1))
  echo "FAIL: $1"
  [ $# -gt 1 ] && printf '      %s\n' "$2"
  return 0
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Run a snippet with SIGPIPE ignored ("runner") or left alone ("terminal"),
# and record stdout, stderr and status.
OUT=""
ERR=""
STATUS=0
run_snippet() {
  local disposition="$1" snippet="$2"
  if [ "$disposition" = runner ]; then
    bash -c "trap '' PIPE
$snippet" >"$WORK/out" 2>"$WORK/err"
  else
    bash -c "$snippet" >"$WORK/out" 2>"$WORK/err"
  fi
  STATUS=$?
  OUT="$(cat "$WORK/out")"
  ERR="$(cat "$WORK/err")"
}

echo "=== 1. the disposition, not the code, is what differs ==="

RETIRED_RANDOM='set -euo pipefail
LC_ALL=C tr -dc "A-Za-z0-9" </dev/urandom | head -c 16'

run_snippet terminal "$RETIRED_RANDOM"
[ -z "$ERR" ] \
  && pass "the retired '</dev/urandom | head' shape is silent on a terminal" \
  || fail "fixture: the retired shape already complains with default SIGPIPE" "$ERR"

run_snippet runner "$RETIRED_RANDOM"
case "$ERR" in
  *"Broken pipe"*) pass "and reports 'write error: Broken pipe' with SIGPIPE ignored" ;;
  *) fail "fixture: the retired shape did not reproduce the runner's error" "$ERR" ;;
esac

# The same call one refactor away: as a bare assignment the failed pipeline is
# the command's own status, and `set -e` takes it. This is why the fix is not
# cosmetic.
RETIRED_ASSIGNMENT='set -euo pipefail
x=$(LC_ALL=C tr -dc "A-Za-z0-9" </dev/urandom | head -c 16)
printf %s "$x"'
run_snippet terminal "$RETIRED_ASSIGNMENT"
[ "$STATUS" -ne 0 ] \
  && pass "as a bare assignment the retired shape aborts even on a terminal (exit $STATUS)" \
  || fail "fixture: the retired assignment shape exited 0"
run_snippet runner "$RETIRED_ASSIGNMENT"
[ "$STATUS" -ne 0 ] \
  && pass "and aborts with SIGPIPE ignored too (exit $STATUS)" \
  || fail "fixture: the retired assignment shape exited 0 with SIGPIPE ignored"

echo
echo "=== 2. the shipped canary generator (scripts/ci/run-secretlint.sh) ==="

GENERATOR="$(sed -n '/^rand_alnum()/,/^}$/p' "$ROOT/scripts/ci/run-secretlint.sh")"
[ -n "$GENERATOR" ] \
  && pass "rand_alnum() is where this suite expects it" \
  || fail "rand_alnum() was not found in scripts/ci/run-secretlint.sh"

for disposition in terminal runner; do
  run_snippet "$disposition" "set -euo pipefail
$GENERATOR
canary=\$(rand_alnum 40)
printf %s \"\$canary\""
  [ "$STATUS" -eq 0 ] \
    && pass "rand_alnum 40 exits 0 ($disposition)" \
    || fail "rand_alnum 40 exited $STATUS ($disposition)" "$ERR"
  [ -z "$ERR" ] \
    && pass "rand_alnum 40 writes nothing to stderr ($disposition)" \
    || fail "rand_alnum 40 wrote to stderr ($disposition)" "$ERR"
  [ "${#OUT}" -eq 40 ] \
    && pass "rand_alnum 40 returns 40 characters ($disposition)" \
    || fail "rand_alnum 40 returned ${#OUT} characters ($disposition)" "$OUT"
  case "$OUT" in
    *[!A-Za-z0-9]*) fail "rand_alnum 40 returned a non-alphanumeric character ($disposition)" "$OUT" ;;
    *) pass "rand_alnum 40 returns only alphanumerics ($disposition)" ;;
  esac
done

# Random, still: a generator that degraded to a constant would be an
# allow-listable canary, which is the thing the comment above it forbids.
run_snippet runner "set -euo pipefail
$GENERATOR
printf '%s %s' \"\$(rand_alnum 16)\" \"\$(rand_alnum 16)\""
[ "${OUT% *}" != "${OUT#* }" ] \
  && pass "two calls return different values" \
  || fail "two calls returned the same value" "$OUT"

echo
echo "=== 3. the shipped Node LTS resolver (ubuntu/24.04/common.sh) ==="

# A feed shaped like nodejs.org/dist/index.json: newest first, most entries
# matching, and large enough that the writers are still writing when a
# `head -n1` would leave. Measured 2026-09-10, the real feed is 330601 bytes
# with 287 matching entries, the first of them 57 records in.
FEED="$WORK/index.json"
{
  printf '['
  printf '{"version":"v25.1.0","date":"2026-02-01","lts":false,"security":false},'
  printf '{"version":"v24.21.0","date":"2025-10-01","lts":"Krypton","security":false},'
  for i in $(seq 1 4000); do
    printf '{"version":"v20.%d.0","date":"2023-01-01","lts":"Iron","security":false},' "$i"
  done
  printf '{"version":"v18.0.0","date":"2022-01-01","lts":false,"security":false}]'
} >"$FEED"
FEED_BYTES="$(wc -c <"$FEED")"
[ "$FEED_BYTES" -gt 65536 ] \
  && pass "the feed fixture is larger than a pipe buffer ($FEED_BYTES bytes)" \
  || fail "the feed fixture is only $FEED_BYTES bytes; it cannot reproduce anything"

RETIRED_RESOLVER="set -euo pipefail
cat '$FEED' | tr '{' '\\n' | grep '\"lts\":\"' | head -n1 \\
  | sed -n 's/.*\"version\":\"v\\([0-9][0-9]*\\)\\..*/\\1/p'"
run_snippet runner "$RETIRED_RESOLVER"
case "$ERR" in
  *"grep: write error: Broken pipe"*)
    pass "the retired 'grep | head -n1' shape reproduces the runner's error pair"
    ;;
  *) fail "fixture: the retired resolver shape did not reproduce" "$ERR" ;;
esac

resolve_with_feed() {
  local disposition="$1" feed="$2" env_prefix="${3:-}"
  run_snippet "$disposition" "set -uo pipefail
. '$ROOT/ubuntu/24.04/common.sh'
fetch_release_feed() { cat '$feed'; }
$env_prefix
printf %s \"\$(resolve_node_lts_major)\""
}

for disposition in terminal runner; do
  resolve_with_feed "$disposition" "$FEED"
  [ "$OUT" = "24" ] \
    && pass "resolve_node_lts_major answers 24 over the fixture feed ($disposition)" \
    || fail "resolve_node_lts_major answered '$OUT' ($disposition)" "$ERR"
  [ -z "$ERR" ] \
    && pass "resolve_node_lts_major writes nothing to stderr ($disposition)" \
    || fail "resolve_node_lts_major wrote to stderr ($disposition)" "$ERR"
done

# The first matching entry wins, not the first entry: the feed is newest-first
# and the newest release is usually not an LTS.
printf '%s' '[{"version":"v25.1.0","lts":false},{"version":"v99.0.0","lts":"Nonesuch"},{"version":"v24.0.0","lts":"Krypton"}]' \
  >"$WORK/ordered.json"
resolve_with_feed runner "$WORK/ordered.json"
[ "$OUT" = "99" ] \
  && pass "the first LTS entry wins, not the first entry" \
  || fail "expected 99 from the ordered feed, got '$OUT'" "$ERR"

# An unusable feed is a fallback, not a crash and not an empty version string.
printf '%s' 'this is not the feed you are looking for' >"$WORK/garbage.json"
resolve_with_feed runner "$WORK/garbage.json" "NODE_LTS_FALLBACK=77"
[ "$OUT" = "77" ] \
  && pass "an unparseable feed falls back to NODE_LTS_FALLBACK" \
  || fail "expected the fallback, got '$OUT'" "$ERR"

printf '%s' '' >"$WORK/empty.json"
resolve_with_feed runner "$WORK/empty.json"
[ -n "$OUT" ] \
  && pass "an empty feed still answers ($OUT)" \
  || fail "an empty feed answered nothing" "$ERR"

resolve_with_feed runner "$WORK/garbage.json" "NODE_VERSION=23.4.5"
[ "$OUT" = "23" ] \
  && pass "NODE_VERSION still short-circuits the feed entirely" \
  || fail "NODE_VERSION=23.4.5 gave '$OUT'" "$ERR"

echo
echo "=== 4. no tracked script writes an unbounded stream into an early exit ==="

# The rule is deliberately narrow, because the general shape is not a defect:
# `some-command | head -n1` is safe whenever the writer's whole output fits in
# the 64 KiB pipe buffer, which is one write and no second one to fail. The
# repository has 317 such pipelines and four of them read a network response -
# `curl -sL 'https://go.dev/VERSION?m=text' | head -n1`, whose body is 35 bytes
# (measured 2026-09-10). Flagging those would be the kind of false positive
# this issue exists to remove.
#
# What is flagged is a writer that cannot fit: an endless device, `yes`, or
# this repository's own release-feed fetcher, whose feeds are hundreds of kB.
UNBOUNDED='(/dev/urandom|/dev/zero|(^|[^[:alnum:]_])yes[[:space:]]|fetch_release_feed)'
EARLY_EXIT='\|[[:space:]]*(head([[:space:]]|$)|grep[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*-[a-zA-Z]*[qm])'
# Stages may sit between the two - resolve_node_lts_major had `tr` and `grep`
# between the fetch and the `head -n1`, and each of them was a writer that got
# EPIPE - but a `;` or an `&&` ends the pipeline and starts a different one.
INTERVENING='[^;&]*'

# Files that contain the retired shape on purpose, each with the reason. An
# entry that names nothing is an exemption that silently stopped applying, so
# the loop below insists every path exists.
declare -A SIGPIPE_FIXTURES=(
  ['experiments/issue-123/repro-sigpipe-ignored.sh']="the reproduction: it runs the retired shapes to show what they print"
  ['experiments/test-issue123-sigpipe-writers.sh']="this suite: sections 1 and 3 drive the retired shapes as fixtures"
)
for fixture in "${!SIGPIPE_FIXTURES[@]}"; do
  [ -f "$ROOT/$fixture" ] \
    && pass "exemption names a real file: $fixture" \
    || fail "exemption names '$fixture', which does not exist; it stopped applying"
done

# Line continuations first: resolve_node_lts_major spread its pipeline over
# three physical lines, so a line-at-a-time sweep would have missed the very
# defect this suite was written for.
joined_scan() {
  local file="$1"
  # Whole-line comments go first: this file and the reproduction both quote the
  # retired shape in prose, and a sweep that reads its own explanation as a
  # finding is exactly the false positive this issue is about.
  grep -v '^[[:space:]]*#' "$file" | awk '{
    line = line $0
    if (line ~ /\\$/) { sub(/\\$/, " ", line); next }
    print line
    line = ""
  }
  END { if (line != "") print line }'
}

offenders=""
while IFS= read -r file; do
  case "$file" in
    dev/log/* | docs/*) continue ;;
  esac
  [ -n "${SIGPIPE_FIXTURES[$file]:-}" ] && continue
  hits="$(joined_scan "$ROOT/$file" | grep -nE "${UNBOUNDED}${INTERVENING}${EARLY_EXIT}" 2>/dev/null)"
  [ -n "$hits" ] && offenders="$offenders$file: $hits"$'\n'
done < <(git -C "$ROOT" ls-files '*.sh' '*.bash' '*.yml' '*.yaml')

[ -z "$offenders" ] \
  && pass "no unbounded writer feeds an early-exiting reader in any tracked script" \
  || fail "an unbounded writer feeds an early-exiting reader" "$(printf '%s' "$offenders")"

# And the sweep can find one, so its silence means something.
cat >"$WORK/planted.sh" <<'PLANT'
#!/usr/bin/env bash
token=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom \
  | head -c 12)
echo "$token"
PLANT
planted="$(joined_scan "$WORK/planted.sh" | grep -cE "${UNBOUNDED}${INTERVENING}${EARLY_EXIT}")"
[ "$planted" -eq 1 ] \
  && pass "the sweep finds a planted offender, continuation line and all" \
  || fail "the sweep found $planted offenders in the planted fixture, expected 1"

# The other historical shape: three physical lines, two stages between the
# writer and the early exit. This is the one a naive sweep misses.
cat >"$WORK/planted-multistage.sh" <<'PLANT'
#!/usr/bin/env bash
major=$(fetch_release_feed "https://nodejs.org/dist/index.json" \
  | tr '{' '\n' | grep '"lts":"' | head -n1 \
  | sed -n 's/.*"version":"v\([0-9][0-9]*\)\..*/\1/p') || true
echo "$major"
PLANT
planted_multi="$(joined_scan "$WORK/planted-multistage.sh" | grep -cE "${UNBOUNDED}${INTERVENING}${EARLY_EXIT}")"
[ "$planted_multi" -eq 1 ] \
  && pass "and finds one with two stages between the writer and the early exit" \
  || fail "the sweep found $planted_multi offenders in the multi-stage fixture, expected 1"

# And does not flag the shape that is safe: a 35-byte network response, whose
# writer is finished before the reader leaves.
cat >"$WORK/safe.sh" <<'PLANT'
#!/usr/bin/env bash
GO_VERSION=$(curl -sL 'https://go.dev/VERSION?m=text' | head -n1)
echo "$GO_VERSION"
PLANT
safe="$(joined_scan "$WORK/safe.sh" | grep -cE "${UNBOUNDED}${INTERVENING}${EARLY_EXIT}")"
[ "$safe" -eq 0 ] \
  && pass "and leaves 'curl | head -n1' over a 35-byte body alone" \
  || fail "the sweep flagged the safe curl shape"

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
