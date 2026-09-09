#!/usr/bin/env bash
# test-issue123-log-command-injection.sh
#
# Issue #123: "Check for all false positives, false negatives, warnings and
# errors in CI/CD and fix them all."
#
# The false positive this suite pins is one annotation on a green job. Release
# run 34366976358, job "Apply Changesets", conclusion `success`, carrying a
# `failure` annotation whose text is the middle of a commit message:
#
#   14:57:10.9574854Z Committing version bump...
#   14:57:11.2322895Z ##[error]` while explaining a fix. `docker/setup-buildx-...
#   14:57:11.2380481Z  2 files changed, 1 insertion(+), 40 deletions(-)
#
# Between "Committing version bump..." and the diffstat there is exactly one
# command: `git commit -m "$NEW_VERSION: $DESCRIPTIONS"`, which echoes the new
# commit's subject line. `$DESCRIPTIONS` is the changeset bodies a pull request
# added, joined onto one line - and release 2.9.0's notes were about issue
# #121's log injection, so they quoted `##[error]`. git printed the subject,
# the runner read it, and a job that did nothing wrong was annotated as having
# failed.
#
# Issue #121 fixed the long path for the same text (commit message -> push
# payload -> buildx provenance -> metadata dump -> log). This is the short one,
# and no amount of buildx configuration reaches it.
#
# What it asserts:
#   Part 1  the runner's parser and its stop-commands state machine, modelled
#           from the source, checked against the line the run actually printed
#   Part 2  a real `git commit` reproduces it: one annotation from a subject
#   Part 3  the guard contains it: same commit, no annotation, same text
#   Part 4  the guard's own properties - unpredictable token, always resumed,
#           exit status and output preserved, not defeatable by guessing
#   Part 5  every place in the repository that can echo a commit subject is
#           routed through the guard
#
# Usage: bash experiments/test-issue123-log-command-injection.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

GUARD="scripts/ci/run-with-commands-stopped.sh"

PASS=0
FAIL=0

pass() {
  echo "PASS: $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "FAIL: $1"
  FAIL=$((FAIL + 1))
  [ $# -gt 1 ] && printf '      %s\n' "${@:2}" >&2
  return 0
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# The runner, in as much detail as this question needs.
#
# src/Runner.Worker/ActionCommandManager.cs
#   :34    `stop-commands` is registered like any other command
#   :70-71 TryParseV2 first, then TryParse - a line only has to satisfy one
#   :86-96 while stopped, the only line that is read is the resume token
#   :108-116 the stop token joins the registered set until it is seen again
# src/Runner.Common/ActionCommand.cs
#   :129   TryParse: IndexOf("##[") - anywhere in the line
#   :62-64 TryParseV2: TrimStart, then StartsWith("::") - the start only
# ---------------------------------------------------------------------------

REGISTERED='set-env set-output save-state add-mask add-path add-matcher remove-matcher debug warning error notice group endgroup echo stop-commands internal-set-repo-path'

# Prints the command name a line would be read as, or nothing. STOP_TOKEN, when
# set, is registered too - that is what makes the resume line a command.
parse_command() {
  local line="$1" registered="$REGISTERED${STOP_TOKEN:+ $STOP_TOKEN}"
  local trimmed rest name after cmdinfo

  # TryParseV2: `::name[ properties]::data`, at the start of the line.
  trimmed="${line#"${line%%[![:space:]]*}"}"
  case "$trimmed" in
    '::'*)
      rest="${trimmed#::}"
      case "$rest" in
        *'::'*)
          name="${rest%%::*}"
          name="${name%% *}"
          case " $registered " in
            *" $name "*)
              printf '%s' "$name"
              return 0
              ;;
          esac
          ;;
      esac
      ;;
  esac

  # TryParse: `##[name[ properties]]data`, anywhere in the line.
  case "$line" in
    *'##['*) after="${line#*##[}" ;;
    *) return 1 ;;
  esac
  case "$after" in
    *']'*) cmdinfo="${after%%]*}" ;;
    *) return 1 ;;
  esac
  name="${cmdinfo%% *}"
  case " $registered " in
    *" $name "*)
      printf '%s' "$name"
      return 0
      ;;
  esac
  return 1
}

# Reads a captured step log on stdin and prints one line per workflow command
# the runner would have acted on. Everything the stop token covers is silent,
# which is the whole point of the guard.
simulate_runner() {
  local line name
  STOP_TOKEN=''
  local stopped=0
  while IFS= read -r line; do
    name="$(parse_command "$line")" || continue
    if [ "$stopped" = "1" ]; then
      if [ -n "$STOP_TOKEN" ] && [ "$name" = "$STOP_TOKEN" ]; then
        stopped=0
        STOP_TOKEN=''
      fi
      continue
    fi
    if [ "$name" = "stop-commands" ]; then
      STOP_TOKEN="${line##*::stop-commands::}"
      STOP_TOKEN="${STOP_TOKEN%%[[:space:]]*}"
      stopped=1
      continue
    fi
    printf '%s\n' "$name"
  done
  STOP_TOKEN=''
}

commands_in() { simulate_runner <"$1"; }
count_commands() { commands_in "$1" | grep -c . || true; }

echo "=== Part 1: the parser, against the line run 34366976358 printed ==="

# Copied from dev/log/issues/123/pulls/124/logs/release-34366976358/
# 102518168976-Apply_Changesets_.log, truncated at a width that keeps the shape.
OBSERVED='[main 1e202f5] 2.9.0: Make every CI annotation mean what it says, and give every check a way to fail (issue #121). ... which quotes `##[error]` while explaining a fix.'

if [ "$(parse_command "$OBSERVED")" = "error" ]; then
  pass "the commit subject the release printed is read as an error command"
else
  fail "the commit subject the release printed is read as an error command"
fi

if [ -z "$(parse_command '[main 1e202f5] 2.9.0: which quotes ::error:: while explaining a fix.')" ]; then
  pass "the same subject in the ::error:: form is not a command mid-line"
else
  fail "the same subject in the ::error:: form is not a command mid-line"
fi

if [ "$(parse_command '[main abc1234] release: ##[stop-commands]guessed')" = "stop-commands" ]; then
  pass "a subject can also stop command processing, not only annotate"
else
  fail "a subject can also stop command processing, not only annotate"
fi

printf '%s\n' \
  '::stop-commands::tok1' \
  '[main abc1234] a subject quoting ##[error]still inside the guard' \
  '::tok1::' \
  '::error::a real annotation, after the guard' >"$TMP/machine.log"
if [ "$(commands_in "$TMP/machine.log" | tr '\n' ' ')" = "error " ]; then
  pass "the state machine silences what the token covers and nothing else"
else
  fail "the state machine silences what the token covers and nothing else" \
    "got: $(commands_in "$TMP/machine.log" | tr '\n' ' ')"
fi

echo
echo "=== Part 2: a real git commit reproduces the annotation ==="

REPO="$TMP/repo"
git init -q "$REPO" 2>/dev/null
git -C "$REPO" config user.name "test"
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config commit.gpgsign false
echo "2.9.0" >"$REPO/VERSION"
git -C "$REPO" add -A

# The shape of scripts/release/apply-changesets.sh's message: version, colon,
# the changeset bodies joined onto one line.
MESSAGE='2.9.0: Make every CI annotation mean what it says. The release quotes `##[error]` while explaining the fix.'

(cd "$REPO" && git commit -m "$MESSAGE") >"$TMP/unguarded.log" 2>&1
UNGUARDED_STATUS=$?

if [ "$UNGUARDED_STATUS" -eq 0 ]; then
  pass "the reproduction's commit succeeded (so the annotation is on a green step)"
else
  fail "the reproduction's commit succeeded (so the annotation is on a green step)" \
    "$(cat "$TMP/unguarded.log")"
fi

if grep -q '##\[error\]' "$TMP/unguarded.log"; then
  pass "git echoes the subject, quoting and all"
else
  fail "git echoes the subject, quoting and all" "$(cat "$TMP/unguarded.log")"
fi

if [ "$(count_commands "$TMP/unguarded.log")" -eq 1 ] && [ "$(commands_in "$TMP/unguarded.log")" = "error" ]; then
  pass "the runner would raise exactly one error annotation from that output"
else
  fail "the runner would raise exactly one error annotation from that output" \
    "commands: $(commands_in "$TMP/unguarded.log" | tr '\n' ' ')"
fi

echo
echo "=== Part 3: the guard contains it ==="

echo "2.9.1" >"$REPO/VERSION"
git -C "$REPO" add -A
(cd "$REPO" && bash "$OLDPWD/$GUARD" git commit -m "$MESSAGE") >"$TMP/guarded.log" 2>&1
GUARDED_STATUS=$?

if [ "$GUARDED_STATUS" -eq 0 ]; then
  pass "the guard passes the command's success through"
else
  fail "the guard passes the command's success through" "$(cat "$TMP/guarded.log")"
fi

if [ "$(count_commands "$TMP/guarded.log")" -eq 0 ]; then
  pass "the runner would raise no annotation from the guarded output"
else
  fail "the runner would raise no annotation from the guarded output" \
    "commands: $(commands_in "$TMP/guarded.log" | tr '\n' ' ')"
fi

if grep -q '##\[error\]' "$TMP/guarded.log"; then
  pass "the guard hides nothing: the subject is still in the log verbatim"
else
  fail "the guard hides nothing: the subject is still in the log verbatim" \
    "$(cat "$TMP/guarded.log")"
fi

printf '%s\n' '::error::an annotation a later step means' >>"$TMP/guarded.log"
if [ "$(commands_in "$TMP/guarded.log" | tr '\n' ' ')" = "error " ]; then
  pass "command processing is resumed, so a later annotation still lands"
else
  fail "command processing is resumed, so a later annotation still lands" \
    "commands: $(commands_in "$TMP/guarded.log" | tr '\n' ' ')"
fi

echo
echo "=== Part 4: the guard's own properties ==="

bash "$GUARD" false >"$TMP/failing.log" 2>&1
if [ "$?" -eq 1 ]; then
  pass "the guard returns the command's exit status"
else
  fail "the guard returns the command's exit status"
fi

TOKEN_LINE="$(head -n1 "$TMP/failing.log")"
TOKEN="${TOKEN_LINE##*::stop-commands::}"
if [ -n "$TOKEN" ] && [ "$(tail -n1 "$TMP/failing.log")" = "::${TOKEN}::" ]; then
  pass "a command that fails is still followed by the resume marker"
else
  fail "a command that fails is still followed by the resume marker" \
    "$(cat "$TMP/failing.log")"
fi

bash "$GUARD" bash -c 'kill -TERM $$' >"$TMP/signalled.log" 2>&1
TOKEN_LINE="$(head -n1 "$TMP/signalled.log")"
TOKEN="${TOKEN_LINE##*::stop-commands::}"
if [ "$(tail -n1 "$TMP/signalled.log")" = "::${TOKEN}::" ]; then
  pass "a command killed by a signal is still followed by the resume marker"
else
  fail "a command killed by a signal is still followed by the resume marker" \
    "$(cat "$TMP/signalled.log")"
fi

TOKENS="$TMP/tokens"
: >"$TOKENS"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  bash "$GUARD" true | head -n1 | sed 's/.*::stop-commands:://' >>"$TOKENS"
done
if [ "$(sort -u "$TOKENS" | grep -c .)" -eq 10 ]; then
  pass "every call uses a fresh token (10 of 10 distinct)"
else
  fail "every call uses a fresh token (10 of 10 distinct)" "$(cat "$TOKENS")"
fi

if [ "$(grep -cE '^[0-9a-f]{32}$' "$TOKENS")" -eq 10 ]; then
  pass "the token is 128 bits of hex, so it is neither empty, nor a registered command, nor 'pause-logging'"
else
  fail "the token is 128 bits of hex, so it is neither empty, nor a registered command, nor 'pause-logging'" \
    "$(cat "$TOKENS")"
fi

# ValidateStopToken throws on any of those three, which fails the step. Model
# the check rather than trust the shape.
INVALID=0
while IFS= read -r t; do
  [ -n "$t" ] || INVALID=1
  [ "$t" = "pause-logging" ] && INVALID=1
  case " $REGISTERED " in *" $t "*) INVALID=1 ;; esac
done <"$TOKENS"
if [ "$INVALID" -eq 0 ]; then
  pass "no token would be rejected by ActionCommandManager.ValidateStopToken"
else
  fail "no token would be rejected by ActionCommandManager.ValidateStopToken"
fi

bash "$GUARD" bash -c 'printf "a subject naming ##[deadbeefdeadbeefdeadbeefdeadbeef] and then ##[error]after it\n"' >"$TMP/guessed.log" 2>&1
if [ "$(count_commands "$TMP/guessed.log")" -eq 0 ]; then
  pass "text naming some other token cannot resume processing early"
else
  fail "text naming some other token cannot resume processing early" \
    "commands: $(commands_in "$TMP/guessed.log" | tr '\n' ' ')"
fi

bash "$GUARD" bash -c 'printf "out\n"; printf "err\n" >&2' >"$TMP/streams.out" 2>"$TMP/streams.err"
if [ "$(grep -c '^err$' "$TMP/streams.err")" -eq 1 ] && [ "$(grep -c '^out$' "$TMP/streams.out")" -eq 1 ] \
  && ! grep -q 'stop-commands' "$TMP/streams.err"; then
  pass "the guard leaves the command's streams where they were"
else
  fail "the guard leaves the command's streams where they were" \
    "out: $(cat "$TMP/streams.out")" "err: $(cat "$TMP/streams.err")"
fi

if bash "$GUARD" >"$TMP/noargs.log" 2>&1; then
  fail "the guard refuses to run with no command"
else
  [ "$?" -eq 2 ] && pass "the guard refuses to run with no command" \
    || fail "the guard refuses to run with no command"
fi

echo
echo "=== Part 5: every place that can echo a commit subject is guarded ==="

# `git commit` prints the subject of the commit it just made; `git pull
# --rebase` prints `could not apply <sha>... <subject>` when the rebase stops.
# Both take their text from a commit message, so both are covered. A line is
# guarded when the guard is the command being run on it.
UNGUARDED_SITES="$TMP/unguarded-sites"
: >"$UNGUARDED_SITES"
while IFS= read -r file; do
  case "$file" in
    experiments/* | dev/log/* | docs/*) continue ;;
  esac
  awk -v file="$file" '
    { line = $0 }
    # strip leading whitespace for the comment test
    { probe = line; sub(/^[ \t-]+/, "", probe) }
    probe ~ /^#/ { next }
    line ~ /git[ \t]+commit[ \t]+-m/ || line ~ /git[ \t]+pull[ \t]+--rebase/ {
      if (line ~ /run_with_commands_stopped/ || line ~ /run-with-commands-stopped\.sh/) { next }
      printf "%s:%d:%s\n", file, NR, line
    }
  ' "$file" >>"$UNGUARDED_SITES"
done < <(git ls-files 'scripts/*' '.github/*')

if [ ! -s "$UNGUARDED_SITES" ]; then
  pass "no tracked script or workflow echoes a commit subject unguarded"
else
  fail "no tracked script or workflow echoes a commit subject unguarded" \
    "$(cat "$UNGUARDED_SITES")"
fi

# The scan is only worth anything if it can see a site. Plant one.
PLANT="$TMP/plant.sh"
printf '%s\n' '#!/usr/bin/env bash' 'git commit -m "$MESSAGE"' >"$PLANT"
if awk '
    { probe = $0; sub(/^[ \t-]+/, "", probe) }
    probe ~ /^#/ { next }
    $0 ~ /git[ \t]+commit[ \t]+-m/ {
      if ($0 ~ /run_with_commands_stopped/ || $0 ~ /run-with-commands-stopped\.sh/) { next }
      print
    }
  ' "$PLANT" | grep -q 'git commit'; then
  pass "the scan reports an unguarded site when there is one"
else
  fail "the scan reports an unguarded site when there is one"
fi

if [ -x "$GUARD" ] || [ -r "$GUARD" ]; then
  pass "the guard is tracked at $GUARD"
else
  fail "the guard is tracked at $GUARD"
fi

echo
echo "=== Part 6: apply-changesets.sh end to end, with a hostile changeset ==="

# Everything this script prints about a changeset came from the pull request
# that added it: the file name, and the body it joins into the commit subject.
# Both are exercised against the real script, not a model of it.
REPO_ROOT="$PWD"

make_fixture() {
  local dir="$1" name="$2" body="$3"
  rm -rf "$dir"
  mkdir -p "$dir/.changeset"
  git init -q -b main "$dir"
  git -C "$dir" config user.name "test"
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config commit.gpgsign false
  echo "2.9.0" >"$dir/VERSION"
  printf -- '---\nbump: minor\n---\n\n%s\n' "$body" >"$dir/.changeset/$name"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "fixture"
}

DRY="$TMP/dry"
make_fixture "$DRY" '##[error]hostile.md' 'a plain description'
(cd "$DRY" && DRY_RUN=true bash "$REPO_ROOT/scripts/release/apply-changesets.sh") \
  >"$TMP/dry.log" 2>&1
DRY_STATUS=$?

if [ "$DRY_STATUS" -eq 0 ] && grep -q 'hostile.md' "$TMP/dry.log"; then
  pass "apply-changesets.sh processes a changeset whose file name quotes a command"
else
  fail "apply-changesets.sh processes a changeset whose file name quotes a command" \
    "$(cat "$TMP/dry.log")"
fi

if [ "$(count_commands "$TMP/dry.log")" -eq 0 ]; then
  pass "the run raises no annotation from the hostile file name"
else
  fail "the run raises no annotation from the hostile file name" \
    "commands: $(commands_in "$TMP/dry.log" | tr '\n' ' ')"
fi

# The full path: the file name is printed as the changeset is processed, the
# description becomes the commit subject git echoes, and the push runs against
# a local bare remote so nothing is stubbed. The two carriers quote different
# commands so that the control below can tell them apart - a line carries at
# most one command, because `TryParse` acts on the first `##[` it finds.
FULL="$TMP/full"
HOSTILE_NAME='##[warning]notes.md'
HOSTILE_BODY='Make every CI annotation mean what it says: the notes quote `##[error]` while explaining the fix.'
make_fixture "$FULL" "$HOSTILE_NAME" "$HOSTILE_BODY"
git init -q --bare "$TMP/remote.git"
git -C "$FULL" remote add origin "$TMP/remote.git"
git -C "$FULL" push -q origin main

(cd "$FULL" && GITHUB_OUTPUT="$TMP/full-output" bash "$REPO_ROOT/scripts/release/apply-changesets.sh") \
  >"$TMP/full.log" 2>&1
FULL_STATUS=$?

if [ "$FULL_STATUS" -eq 0 ] && [ "$(cat "$FULL/VERSION")" = "2.10.0" ]; then
  pass "apply-changesets.sh bumps and lands the version with that description"
else
  fail "apply-changesets.sh bumps and lands the version with that description" \
    "status $FULL_STATUS" "$(cat "$TMP/full.log")"
fi

if grep -q '##\[error\]' "$TMP/full.log"; then
  pass "git echoed the hostile subject into the step log, as it always does"
else
  fail "git echoed the hostile subject into the step log, as it always does" \
    "$(cat "$TMP/full.log")"
fi

if [ "$(count_commands "$TMP/full.log")" -eq 0 ]; then
  pass "the release run raises no annotation from that subject"
else
  fail "the release run raises no annotation from that subject" \
    "commands: $(commands_in "$TMP/full.log" | tr '\n' ' ')"
fi

# The control. An assertion that cannot fail is the defect this issue is about,
# so the guard is removed from a copy of the script and the same run is made
# again: it must produce the annotation the release produced.
MUTANT_DIR="$TMP/mutant-scripts"
mkdir -p "$MUTANT_DIR/release" "$MUTANT_DIR/ci"
cp "$REPO_ROOT/scripts/release/"*.sh "$MUTANT_DIR/release/"
cp "$REPO_ROOT/scripts/ci/run-with-commands-stopped.sh" "$MUTANT_DIR/ci/"
sed -i 's/run_with_commands_stopped //g' "$MUTANT_DIR/release/apply-changesets.sh"

MUTANT="$TMP/mutant"
make_fixture "$MUTANT" "$HOSTILE_NAME" "$HOSTILE_BODY"
git init -q --bare "$TMP/mutant-remote.git"
git -C "$MUTANT" remote add origin "$TMP/mutant-remote.git"
git -C "$MUTANT" push -q origin main
(cd "$MUTANT" && GITHUB_OUTPUT="$TMP/mutant-output" bash "$MUTANT_DIR/release/apply-changesets.sh") \
  >"$TMP/mutant.log" 2>&1

MUTANT_COMMANDS="$(commands_in "$TMP/mutant.log" | tr '\n' ' ')"
# The file name reaches the log more than once - the list, "Processing:",
# "Removing:", and git's own `delete mode` line - so the count is a property of
# the git version. What is asserted is that both carriers annotate: the name as
# a `warning`, the subject as the `error` the release actually printed.
case " ${MUTANT_COMMANDS}" in
  *" error "*) MUTANT_HAS_ERROR=yes ;;
  *) MUTANT_HAS_ERROR=no ;;
esac
case " ${MUTANT_COMMANDS}" in
  *" warning "*) MUTANT_HAS_WARNING=yes ;;
  *) MUTANT_HAS_WARNING=no ;;
esac

if [ "$MUTANT_HAS_ERROR" = yes ] && [ "$MUTANT_HAS_WARNING" = yes ]; then
  pass "without the guard the same run reproduces the release's annotations"
else
  fail "without the guard the same run reproduces the release's annotations" \
    "commands: ${MUTANT_COMMANDS}"
fi

echo
echo "================================================================"
echo "PASS: $PASS   FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
