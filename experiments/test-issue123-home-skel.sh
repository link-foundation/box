#!/usr/bin/env bash
# test-issue123-home-skel.sh
#
# Issue #123. The warning both JS build jobs printed, and the thing it was
# telling us about.
#
# The census of run 34366976358 (dev/log/issues/123/pulls/124/analysis/
# warnings-errors.census.md) has, twice, once per architecture:
#
#   useradd: warning: the home directory /home/box already exists.
#   useradd: Not copying any file from skel directory into it.
#
# The directory already existed because `WORKDIR /home/box` stood near the top
# of ubuntu/24.04/js/Dockerfile and Docker creates a WORKDIR that is not there.
# `useradd -m` populates a home from /etc/skel only when it creates the
# directory itself, so the box user got an empty home - and the file it was
# missing is ~/.profile, which is what sources ~/.bashrc for an interactive
# *login* shell. Every image in this repository descends from the JS box, so
# every one of them shipped a box user for whom `docker run -it box bash -l`,
# `su - box` and every ssh session saw none of the PATH the install scripts
# append to ~/.bashrc. Measured both ways, by building the image with the
# WORKDIR in each position, in experiments/issue-123/repro-workdir-skips-skel.sh
# and dev/log/issues/123/pulls/124/useradd/workdir-skel-measurement.txt.
#
# The fix restores the two skel files explicitly and deliberately leaves the
# third alone: Ubuntu's skel .bashrc opens with
#
#   case $- in *i*) ;; *) return;; esac
#
# and scripts/entrypoint.sh sources ~/.bashrc from a non-interactive shell, so
# adopting skel's copy would silently drop everything the install scripts
# appended below it - trading one silent environment loss for another. Part 3
# executes that, so the exclusion is a measurement rather than an opinion.
#
# Every assertion is offline: no docker, no network, no useradd. The shell
# behaviour is exercised by running real `bash -l` against fixture HOMEs, and
# the restore loop is executed as the text ubuntu/24.04/common.sh actually
# ships, with only its two absolute path prefixes remapped into the fixture.
#
# Usage: bash experiments/test-issue123-home-skel.sh

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

DOCKERFILE="$ROOT/ubuntu/24.04/js/Dockerfile"

echo "== Part 1: the JS Dockerfile owns the ordering it created =="

# The WORKDIR is not the defect and removing it is not the fix - the image is
# supposed to start in /home/box. What was wrong is that `useradd -m` was asked
# to populate a directory Docker had already made.
workdir_line="$(command grep -n '^WORKDIR /home/box' "$DOCKERFILE" | head -n1 | cut -d: -f1)"
useradd_line="$(command grep -n 'useradd .*-d /home/box' "$DOCKERFILE" | head -n1 | cut -d: -f1)"

if [ -n "$workdir_line" ] && [ -n "$useradd_line" ] && [ "$workdir_line" -lt "$useradd_line" ]; then
  pass "WORKDIR /home/box (line $workdir_line) still precedes the useradd (line $useradd_line)"
else
  fail "expected WORKDIR /home/box before the useradd" \
    "workdir=$workdir_line useradd=$useradd_line"
fi

if command grep -qE 'useradd +-M +' "$DOCKERFILE"; then
  pass "the box user is created with -M, so useradd is not asked to populate a directory it did not make"
else
  fail "ubuntu/24.04/js/Dockerfile does not create the box user with useradd -M" \
    "$(command grep -n 'useradd' "$DOCKERFILE" | head -n3)"
fi

if command grep -qE 'useradd +-m ' "$DOCKERFILE"; then
  fail "ubuntu/24.04/js/Dockerfile still uses useradd -m, which prints the warning and copies nothing"
else
  pass "no useradd -m left in the JS Dockerfile"
fi

if command grep -q 'cp -a /etc/skel/\.profile /etc/skel/\.bash_logout /home/box/' "$DOCKERFILE"; then
  pass "the two skel files useradd would have copied are copied explicitly"
else
  fail "the JS Dockerfile does not restore /etc/skel/.profile and /etc/skel/.bash_logout"
fi

# `cp -a` keeps root's ownership, and `useradd -m` would have made these files
# the user's, so the chown that follows has to be recursive.
if command grep -q 'chown -R box:box /home/box' "$DOCKERFILE"; then
  pass "and chowns them to box - cp -a would otherwise leave root's ownership on them"
else
  fail "the JS Dockerfile does not chown /home/box recursively" \
    "$(command grep -n 'chown' "$DOCKERFILE" | head -n3)"
fi

# The third skel file is the one that must not be adopted; Part 3 measures why.
if command grep -q '/etc/skel/\.bashrc' "$DOCKERFILE"; then
  fail "the JS Dockerfile copies skel's .bashrc into the image"
else
  pass "skel's .bashrc is not copied - the image's ~/.bashrc stays install-script-authored"
fi

echo
echo "== Part 2: what ~/.profile is for, executed =="

# Ubuntu ships a skel .profile whose whole job, for this repository, is the
# three lines that source ~/.bashrc. Read it from the running system when the
# running system has one, so the assertion is about the real file.
if [ -f /etc/skel/.profile ] \
  && command grep -qE '(\.|source) +"?\$HOME/\.bashrc"?' /etc/skel/.profile; then
  pass "this machine's /etc/skel/.profile sources ~/.bashrc (that is the file the box user was missing)"
elif [ -f /etc/skel/.profile ]; then
  fail "/etc/skel/.profile exists but does not source ~/.bashrc" "$(cat /etc/skel/.profile)"
else
  # Not Ubuntu. The evidence file recorded from ubuntu:24.04 stands in.
  ev="$ROOT/dev/log/issues/123/pulls/124/useradd/skel-repro.txt"
  if [ -f "$ev" ] && command grep -q '\.bashrc' "$ev"; then
    pass "no /etc/skel here; the recorded ubuntu:24.04 repro shows skel .profile sourcing ~/.bashrc"
  else
    fail "no /etc/skel/.profile and no recorded repro to stand in for it"
  fi
fi

# Two fixture homes differing only in whether ~/.profile is present, each read
# by a real login shell. This is the consequence of the warning, reproduced
# without docker.
mk_home() {
  local home="$1" with_profile="$2"
  mkdir -p "$home"
  # What the install scripts append to ~/.bashrc, in miniature.
  printf 'export BOX_MARKER=from-bashrc\n' >"$home/.bashrc"
  if [ "$with_profile" = "yes" ]; then
    printf '%s\n' \
      'if [ -n "$BASH_VERSION" ]; then' \
      '  if [ -f "$HOME/.bashrc" ]; then' \
      '    . "$HOME/.bashrc"' \
      '  fi' \
      'fi' >"$home/.profile"
  fi
}

login_marker() {
  # -l so it is a login shell, -i so it is interactive: together this is what a
  # `su - box`, an ssh session and `docker run -it box bash -l` all are, and it
  # is the only combination that reaches ~/.bashrc through ~/.profile.
  # </dev/null matters: bash sources ~/.bashrc for a non-interactive shell
  # whose stdin is a socket (its "run by rshd" heuristic), and with HOME cleared
  # by `env -i` the ~ it expands comes from /etc/passwd - so a CI runner with a
  # socket on stdin would drop the invoking user's real .bashrc into the middle
  # of the measurement.
  env -i HOME="$1" TERM=dumb BOX_MARKER=UNSET \
    bash -lic 'printf "%s\n" "${BOX_MARKER:-UNSET}"' </dev/null 2>/dev/null | tail -n1
}

mk_home "$WORK/home-with" yes
mk_home "$WORK/home-without" no

got_with="$(login_marker "$WORK/home-with")"
got_without="$(login_marker "$WORK/home-without")"

[ "$got_with" = "from-bashrc" ] \
  && pass "with ~/.profile, an interactive login shell reaches ~/.bashrc (BOX_MARKER=$got_with)" \
  || fail "expected BOX_MARKER=from-bashrc with ~/.profile, got '$got_with'"

[ "$got_without" = "UNSET" ] \
  && pass "without ~/.profile it does not - which is the state useradd left every box image in" \
  || fail "expected BOX_MARKER=UNSET without ~/.profile, got '$got_without'"

echo
echo "== Part 3: why skel's .bashrc is not copied back =="

if [ -f /etc/skel/.bashrc ] && command grep -q 'case \$- in' /etc/skel/.bashrc; then
  pass "this machine's /etc/skel/.bashrc opens with the non-interactive early return"
else
  ev="$ROOT/dev/log/issues/123/pulls/124/useradd/workdir-skel-measurement.txt"
  if [ -f "$ev" ] && command grep -q 'interactive guard found' "$ev"; then
    pass "no Ubuntu /etc/skel/.bashrc here; the recorded build found the interactive guard in it"
  else
    fail "cannot establish that skel's .bashrc carries the non-interactive guard"
  fi
fi

# The guard, sourced the way scripts/entrypoint.sh sources ~/.bashrc.
cat >"$WORK/guarded.bashrc" <<'RC'
case $- in
  *i*) ;;
  *) return ;;
esac
export BOX_MARKER=below-the-guard
RC
cat >"$WORK/plain.bashrc" <<'RC'
export BOX_MARKER=below-the-guard
RC

source_noninteractive() {
  env -i BOX_MARKER=UNSET RC="$1" \
    bash -c 'set -u; . "$RC"; printf "%s\n" "${BOX_MARKER:-UNSET}"' </dev/null 2>/dev/null | tail -n1
}

got_guarded="$(source_noninteractive "$WORK/guarded.bashrc")"
got_plain="$(source_noninteractive "$WORK/plain.bashrc")"

[ "$got_guarded" = "UNSET" ] \
  && pass "a non-interactive \`. ~/.bashrc\` returns at the guard, losing everything below it" \
  || fail "expected the guard to swallow the export, got '$got_guarded'"

[ "$got_plain" = "below-the-guard" ] \
  && pass "the same source without the guard keeps it - which is why the images' own .bashrc must stay unguarded" \
  || fail "expected BOX_MARKER=below-the-guard without a guard, got '$got_plain'"

# That loss would be live, not hypothetical: this is the line that would take it.
if command grep -qE '^[[:space:]]*(source|\.) +"\$HOME/\.bashrc"' "$ROOT/scripts/entrypoint.sh"; then
  pass "scripts/entrypoint.sh sources \$HOME/.bashrc, and its shell is non-interactive"
else
  fail "scripts/entrypoint.sh no longer sources \$HOME/.bashrc" \
    "if that changed, revisit the .bashrc exclusion in Part 1"
fi

# And nothing anywhere may put skel's .bashrc into the box home.
offenders=""
while read -r f; do
  [ -f "$ROOT/$f" ] || continue
  case "$f" in experiments/test-issue123-home-skel.sh) continue ;; esac
  hits="$(command grep -nE '(cp|install|ln)[^|;&]*/etc/skel/\.bashrc' "$ROOT/$f" 2>/dev/null)" || true
  [ -n "$hits" ] && offenders="$offenders$f: $hits"$'\n'
done < <(git -C "$ROOT" ls-files -- ubuntu scripts .github experiments)

[ -z "$offenders" ] \
  && pass "no tracked file copies /etc/skel/.bashrc into an image" \
  || fail "skel's .bashrc is being copied somewhere" "$offenders"

echo
echo "== Part 4: every place that creates the box user restores skel =="

# The Dockerfile is one site; four shell scripts create the same user, and any
# of them can meet a /home/box that already exists - after a `userdel` without
# -r, on a re-run, or on a host that provisioned the directory first.
sites=0
missing=""
while read -r f; do
  command grep -qE 'useradd[^|;&]*-d /home/box' "$ROOT/$f" 2>/dev/null || continue
  sites=$((sites + 1))
  command grep -q 'for skel_file in .profile .bash_logout' "$ROOT/$f" \
    || missing="$missing$f"$'\n'
done < <(git -C "$ROOT" ls-files -- 'ubuntu/**/*.sh' 'scripts/*.sh')

[ "$sites" -eq 4 ] \
  && pass "found all $sites shell sites that create the box user" \
  || fail "found $sites shell useradd sites, expected 4" \
    "$(git -C "$ROOT" grep -lE 'useradd[^|;&]*-d /home/box' -- 'ubuntu/**/*.sh' 'scripts/*.sh')"

[ -z "$missing" ] \
  && pass "and every one of them restores the skel files useradd may have refused to copy" \
  || fail "a box-user site does not restore skel" "$missing"

# The loop those four sites carry, executed as ubuntu/24.04/common.sh ships it.
# Only the two absolute path prefixes are rewritten, so what runs below is the
# shipped text and not a paraphrase of it.
loop="$(awk '/^ *for skel_file in \.profile \.bash_logout; do$/,/^ *done$/' "$ROOT/ubuntu/24.04/common.sh")"
if [ -z "$loop" ]; then
  fail "could not extract the skel restore loop from ubuntu/24.04/common.sh"
else
  pass "extracted the shipped restore loop ($(printf '%s\n' "$loop" | wc -l) lines) to execute"
fi

run_loop() {
  local skel="$1" home="$2"
  local body
  body="$(printf '%s\n' "$loop" | sed -e "s#/etc/skel#${skel}#g" -e "s#/home/box#${home}#g")"
  # chown box:box cannot run here and is not what is under test.
  env -i PATH="$WORK/bin:/usr/bin:/bin" bash -c "set -euo pipefail
$body" </dev/null 2>&1
}

mkdir -p "$WORK/bin"
printf '#!/bin/sh\nexit 0\n' >"$WORK/bin/chown"
chmod +x "$WORK/bin/chown"

skel="$WORK/skel"
mkdir -p "$skel"
printf 'skel profile\n' >"$skel/.profile"
printf 'skel bash_logout\n' >"$skel/.bash_logout"
printf 'skel bashrc with guard\n' >"$skel/.bashrc"

# 1. An empty home - what `useradd -m` leaves behind when the directory existed.
home="$WORK/empty-home"
mkdir -p "$home"
out="$(run_loop "$skel" "$home")"
status=$?
[ "$status" -eq 0 ] \
  && pass "the loop exits 0 over an empty home" \
  || fail "the loop exited $status" "$out"

[ -f "$home/.profile" ] && [ -f "$home/.bash_logout" ] \
  && pass "and restores .profile and .bash_logout" \
  || fail "the loop did not restore both files" "$(ls -a "$home")"

[ ! -e "$home/.bashrc" ] \
  && pass "and does not bring skel's .bashrc with them" \
  || fail "the loop copied skel's .bashrc"

# 2. A home the install scripts have already written to - a re-run must not
#    overwrite anything, or a second call would revert ~/.profile.
home2="$WORK/populated-home"
mkdir -p "$home2"
printf 'written by the install scripts\n' >"$home2/.profile"
run_loop "$skel" "$home2" >/dev/null
if [ "$(cat "$home2/.profile")" = "written by the install scripts" ]; then
  pass "an existing ~/.profile is never overwritten, so the loop is a re-run no-op"
else
  fail "the loop overwrote an existing ~/.profile" "$(cat "$home2/.profile")"
fi

# 3. No /etc/skel at all - the loop must not fail the build under `set -e`.
home3="$WORK/no-skel-home"
mkdir -p "$home3"
out="$(run_loop "$WORK/nonexistent-skel" "$home3")"
status=$?
[ "$status" -eq 0 ] && [ -z "$out" ] \
  && pass "with no skel directory the loop is silent and exits 0" \
  || fail "the loop failed when /etc/skel was absent (exit $status)" "$out"

# 4. The defect itself: the same fixture without the loop keeps the empty home,
#    so the assertions above are testing the fix and not the fixture.
home4="$WORK/unfixed-home"
mkdir -p "$home4"
[ ! -e "$home4/.profile" ] \
  && pass "and a home nothing restores stays without ~/.profile - the shipped state before this fix" \
  || fail "fixture error: the unfixed home has a .profile"

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
