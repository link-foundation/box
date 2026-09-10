#!/usr/bin/env bash
# test-issue123-apt-retry-defaults.sh
#
# Issue #123. This suite exists to retire a "hardening" item by measuring it,
# and to keep it retired.
#
# `apt_update_with_retry` (ubuntu/24.04/common.sh, and a second copy in
# scripts/measure-disk-space.sh) refreshes apt metadata with three options:
#
#   -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30
#
# and none of the ~40 `apt-get install` lines in this repository passes any of
# them. That asymmetry reads like a defect - "the refresh is hardened and the
# installs are not" - and the obvious fix is to restate the flags at every
# install site, or to drop them into /etc/apt/apt.conf.d so every apt process
# inherits them.
#
# Measured, on Ubuntu 24.04 with apt 2.8.3 all three options are already apt's
# own defaults - *in the environments the images are built in*:
#
#   Retries, counted as TCP connections apt opens to a server that accepts and
#   immediately resets (the transient failure Acquire::Retries covers):
#
#     Retries=0    2 connections     (2 index items, one attempt each)
#     Retries=1    4
#     Retries=2    6
#     Retries=3    8
#     Retries=5   12
#     default      8                 <- identical to an explicit 3
#
#   Idle-connection timeout, against a server that accepts and never answers,
#   with Retries=0 so each item is attempted once (measured separately, see
#   APT_MEASURE_TIMEOUTS below):
#
#     Acquire::http::Timeout=5     10s   (2 items x 5s)
#     Acquire::http::Timeout=30    60s
#     apt default                  60s   <- identical to an explicit 30
#
# The explicit legs are a property of apt and hold everywhere this has been
# run. The last line of the retries table is not: it is a property of the
# machine. The same fixture measures 8 here and inside `ubuntu:24.04` - the
# image every Dockerfile in this repository builds from - and **4** on the
# ubuntu-24.04 GitHub runner, on the same apt 2.8.3, with every explicit leg
# exact to the connection. So the runner's apt defaults to one retry and the
# image's to three.
#
# This suite used to assert the 8. That is the defect issue #123 is about,
# committed by one of its own tests: an assertion that pins the spelling of a
# constant it happens to have observed, and then reports a verdict about this
# repository ("the install sites now need the flag") on the strength of a number
# that says nothing about this repository. What is asserted now is the property
# that can hurt - apt_update_with_retry *passes* `-o Acquire::Retries=3`, so a
# lower default makes the refresh stronger and only a higher one makes the
# option a downgrade - and the measured default is derived, reported, and
# printed beside the config that produced it.
#
# So in the image the install sites are not weaker than the refresh site, and on
# the runner the refresh site is the stronger of the two - never the reverse,
# which is the only ordering that would make the install sites need the flags.
#
# What apt_update_with_retry adds over plain apt is its *outer* loop - up to 5
# attempts with exponential backoff, clearing /var/lib/apt/lists between them -
# which apt's internal retries do not do, and which is what the mirror-sync
# mismatch it documents (apt exit 100) actually needs. The invariant worth
# holding, then, is not "every install repeats the flags" but "every install is
# preceded by that outer loop", which part 3 checks per Dockerfile RUN block.
#
# This suite fails if a future apt - or a future runner image - raises the
# default above what this repository pins, because that is when the pin starts
# taking patience away rather than adding it. Part 4 holds the other half: no
# refresh here may inherit a default at all, since the default is a machine's
# property and not a script's.
#
# Usage: bash experiments/test-issue123-apt-retry-defaults.sh
#
# Environment:
#   APT_MEASURE_TIMEOUTS=1  also measure the idle-connection timeout. Off by
#                           default because it costs ~130s: the default and the
#                           explicit 30 both take 60s by construction. The
#                           recorded output is in
#                           dev/log/issues/123/pulls/124/apt/.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

PASSED=0
FAILED=0

pass() {
  echo "PASS: $1"
  PASSED=$((PASSED + 1))
}
fail() {
  echo "FAIL: $1"
  FAILED=$((FAILED + 1))
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Part 1: what apt really does with Acquire::Retries
# ---------------------------------------------------------------------------

if ! command -v apt-get >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: this suite measures apt itself and needs apt-get and python3; one of them is missing."
  echo "      Nothing was asserted here. Both are present on ubuntu-24.04 runners and in the box images."
  exit 0
fi

APT_VERSION="$(apt-get --version 2>/dev/null | head -1)"
APT_GET_PATH="$(command -v apt-get)"
echo "Measuring: $APT_VERSION on $(sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' /etc/os-release 2>/dev/null || echo 'unknown OS')"

# A server that accepts a connection and resets it. This is the shape of
# failure Acquire::Retries retries: not an HTTP error status (apt treats a 503
# as an answer and gives up), but a connection that dies mid-conversation.
# It counts accepted connections and reports the count on demand, which is what
# turns "apt retried" into a number.
cat >"$TMP/reset-server.py" <<'PY'
import socket, struct, sys, threading

count = 0
lock = threading.Lock()

srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0))
srv.listen(64)
print(srv.getsockname()[1], flush=True)


def handle(conn):
    global count
    with lock:
        count += 1
    # Read the request before resetting. The first draft reset the connection
    # the moment it was accepted, which raced apt's own write: depending on
    # scheduling apt saw the reset either while awaiting the response (a
    # transient failure, retried) or while still sending the request (which it
    # need not classify the same way). Under CPU contention that race decided
    # the measurement - the same leg reported 12, 8 and 4 connections on three
    # consecutive runs with four busy loops on the CPU. Reading the request
    # first makes every attempt fail at the same point for the same reason,
    # which is what a measurement of retry *counts* needs.
    conn.settimeout(5)
    try:
        while True:
            chunk = conn.recv(4096)
            if not chunk or chunk.endswith(b"\r\n\r\n") or b"\r\n\r\n" in chunk:
                break
    except OSError:
        pass
    # SO_LINGER with a zero timeout makes close() send RST rather than FIN,
    # so apt sees a reset connection instead of a clean end of stream.
    try:
        conn.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        conn.close()
    except OSError:
        pass


def serve():
    while True:
        conn, _ = srv.accept()
        # One thread per connection: reading the request means a connection can
        # now take time, and the accept loop must not be the thing that
        # serialises apt's attempts.
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


threading.Thread(target=serve, daemon=True).start()

# One line in, one count out, and the counter resets: the caller reads a count
# per apt invocation rather than a running total.
for _ in sys.stdin:
    with lock:
        print(count, flush=True)
        count = 0
PY

mkdir -p "$TMP/empty" "$TMP/lists/partial" "$TMP/cache/archives/partial"
rm -f "$TMP/ask"
mkfifo "$TMP/ask"
exec 3< <(python3 "$TMP/reset-server.py" <"$TMP/ask")
exec 4>"$TMP/ask"
read -r PORT <&3

echo "deb [trusted=yes] http://127.0.0.1:$PORT/ubuntu noble main" >"$TMP/sources.list"

# `apt-get update` against nothing but the fixture source: every Dir::* option
# points into $TMP so this needs no privileges and touches no real apt state.
apt_update_against_fixture() {
  rm -rf "$TMP/lists"
  mkdir -p "$TMP/lists/partial"
  apt-get update -qq \
    -o Dir::Etc::sourcelist="$TMP/sources.list" \
    -o Dir::Etc::sourceparts="$TMP/empty" \
    -o Dir::Etc::parts="$TMP/empty" \
    -o Dir::Etc::main=/dev/null \
    -o Dir::State::lists="$TMP/lists" \
    -o Dir::Cache="$TMP/cache" \
    -o Debug::NoLocking=1 \
    "$@" >/dev/null 2>&1
}

# apt's fetch methods are separate processes and outlive the apt-get that
# started them, so the last connection of a leg can be accepted after apt-get
# has already exited. The first draft allowed for that with `sleep 0.5` - a
# guess, and one that was wrong under load: in a run of the whole experiments
# directory this suite reported 11 connections for Acquire::Retries=5 where 12
# had been opened, and passed on three quiet runs afterwards. A measurement that
# reports a number before the data is in is the defect this issue is about, so
# this waits for quiescence instead of guessing: keep asking the server until it
# has had nothing new to report for QUIET_POLLS consecutive polls, and sum what
# arrives. The counter resets on every read, so an accumulated total is exact
# whether the stragglers land in the first poll or the last.
QUIET_POLLS=5 # 0.5s of silence, the old settle expressed as a floor not a cap
MAX_POLLS=200 # 20s, after which something is wrong with the fixture itself
connections_since_last_read() {
  local answer total=0 quiet=0 polls=0
  while [ "$quiet" -lt "$QUIET_POLLS" ] && [ "$polls" -lt "$MAX_POLLS" ]; do
    echo x >&4
    read -r answer <&3
    total=$((total + answer))
    if [ "$answer" -eq 0 ]; then quiet=$((quiet + 1)); else quiet=0; fi
    polls=$((polls + 1))
    sleep 0.1
  done
  printf '%s' "$total"
}

connections_since_last_read >/dev/null # drain anything from startup

declare -A OBSERVED=()
for retries in 0 1 2 3 5; do
  apt_update_against_fixture -o Acquire::Retries="$retries"
  OBSERVED["$retries"]="$(connections_since_last_read)"
  expected=$((2 * (retries + 1)))
  if [ "${OBSERVED[$retries]}" = "$expected" ]; then
    pass "Acquire::Retries=$retries opens $expected connections (2 index items x $((retries + 1)) attempts)"
  else
    fail "Acquire::Retries=$retries opened ${OBSERVED[$retries]} connections, expected $expected"
  fi
done

apt_update_against_fixture
DEFAULT_CONNECTIONS="$(connections_since_last_read)"

# The default is the one leg whose value is environmental, and this suite used
# to hard-code it. apt reads /etc/apt/apt.conf and /etc/apt/apt.conf.d during
# `pkgInitConfig`, *before* it parses -o, so the Dir::Etc::* overrides above
# cannot un-read them: whatever those files say about Acquire::Retries is in
# force for this leg and for no other, because every other leg overrides it on
# the command line. Printed with the number so the two are read together.
apt_retries_environment_report() {
  local dumped files
  dumped="$(apt-config dump Acquire::Retries 2>/dev/null | head -1)"
  files="$(grep -rlsE '^[[:space:]]*(APT::)?Acquire::Retries' /etc/apt/apt.conf /etc/apt/apt.conf.d 2>/dev/null | tr '\n' ' ')"
  echo "  apt-config dump: ${dumped:-Acquire::Retries is unset, so apt used its compiled-in default}"
  echo "  apt.conf files naming Acquire::Retries: ${files:-none}"
  echo "  APT_CONFIG=${APT_CONFIG:-unset}"
  if [ -n "$APT_GET_PATH" ] && [ "$(head -c2 "$APT_GET_PATH" 2>/dev/null)" = '#!' ]; then
    echo "  $APT_GET_PATH is a script, not apt's own binary: this environment wraps apt-get"
    echo "  (the GitHub runner images do - runner-images images/ubuntu/scripts/build/configure-apt-mock.sh),"
    echo "  so a disagreement between the dump above and the measurement is the wrapper's doing."
  fi
}

# 2 index items x (retries + 1) attempts, so the count answers the question
# directly: d = n/2 - 1. Deriving it is what makes this a measurement rather
# than a comparison against a number somebody typed.
DEFAULT_RETRIES=-1
if [ "$DEFAULT_CONNECTIONS" -ge 2 ] && [ $((DEFAULT_CONNECTIONS % 2)) -eq 0 ]; then
  DEFAULT_RETRIES=$((DEFAULT_CONNECTIONS / 2 - 1))
fi

if [ "$DEFAULT_RETRIES" -ge 0 ]; then
  pass "apt's default retry count here is $DEFAULT_RETRIES: the default leg opened $DEFAULT_CONNECTIONS connections, i.e. 2 index items x $((DEFAULT_RETRIES + 1)) attempts"
else
  fail "the default leg opened $DEFAULT_CONNECTIONS connections, which is not 2 items x a whole number of attempts: this fixture is not measuring retries, so nothing derived from it means anything"
fi

apt_retries_environment_report

# The verdict, stated as the thing that can actually hurt.
#
# It used to be stated as equality - "the default is 3, so -o Acquire::Retries=3
# is a no-op" - and that failed the Scripts run of 2026-09-10 on a runner whose
# default is 1, while every explicit leg was exact to the connection. The
# equality was never the property worth holding: apt_update_with_retry *passes*
# the option, so a default below 3 makes the refresh stronger than a bare
# apt-get, which is the direction this repository wants. Only a default above 3
# turns the option into a downgrade, and that is what fails here. Pinning the
# spelling of an environment's constant instead of the property is this issue's
# own defect class, committed by one of its own tests.
if [ "$DEFAULT_RETRIES" -le 3 ]; then
  if [ "$DEFAULT_RETRIES" -eq 3 ]; then
    pass "  and -o Acquire::Retries=3 is a no-op here: the default already opens $DEFAULT_CONNECTIONS connections, the same as the explicit leg's ${OBSERVED[3]}"
  else
    pass "  and -o Acquire::Retries=3 is a strengthening here, not a downgrade: the default opened $DEFAULT_CONNECTIONS connections against the explicit 3's ${OBSERVED[3]}"
  fi
else
  fail "apt's default here is $DEFAULT_RETRIES retries and apt_update_with_retry pins 3: the option has become a downgrade, so every refresh site is now less patient than a bare apt-get would be ($APT_VERSION)"
fi

if [ "$DEFAULT_CONNECTIONS" != "${OBSERVED[0]}" ]; then
  pass "the measurement can tell retries apart: 0 retries opened ${OBSERVED[0]} connections against the default's $DEFAULT_CONNECTIONS"
else
  fail "0 retries and the default opened the same number of connections (${OBSERVED[0]}), so this measurement is not measuring retries at all"
fi

exec 4>&-
exec 3<&-

# ---------------------------------------------------------------------------
# Part 2: the idle-connection timeout (opt-in, ~130s)
# ---------------------------------------------------------------------------

if [ "${APT_MEASURE_TIMEOUTS:-0}" = "1" ]; then
  cat >"$TMP/idle-server.py" <<'PY'
import socket, sys, threading

srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0))
srv.listen(64)
print(srv.getsockname()[1], flush=True)

held = []


def serve():
    while True:
        conn, _ = srv.accept()
        held.append(conn)  # accept, then never answer


threading.Thread(target=serve, daemon=True).start()
sys.stdin.readline()
PY

  # The server has to be held open for as long as the measurement runs, and its
  # stdin is what holds it: given the suite's own stdin it read EOF immediately,
  # exited, and every connection was then *refused* rather than ignored - apt
  # gave up in 0s and the two assertions below passed on 0s against 1s. A check
  # that cannot fail is the subject of this issue, so the fixture keeps a writer
  # on a fifo and the assertions carry absolute floors.
  rm -f "$TMP/idle-ask"
  mkfifo "$TMP/idle-ask"
  exec 5< <(python3 "$TMP/idle-server.py" <"$TMP/idle-ask")
  exec 6>"$TMP/idle-ask"
  read -r IDLE_PORT <&5
  echo "deb [trusted=yes] http://127.0.0.1:$IDLE_PORT/ubuntu noble main" >"$TMP/sources.list"

  seconds_to_give_up() {
    local start end
    start="$(date +%s)"
    apt_update_against_fixture -o Acquire::Retries=0 "$@"
    end="$(date +%s)"
    printf '%s' "$((end - start))"
  }

  SMALL="$(seconds_to_give_up -o Acquire::http::Timeout=5)"
  EXPLICIT="$(seconds_to_give_up -o Acquire::http::Timeout=30)"
  DEFAULT_TIMEOUT="$(seconds_to_give_up)"
  echo "  Timeout=5: ${SMALL}s   Timeout=30: ${EXPLICIT}s   apt default: ${DEFAULT_TIMEOUT}s"

  # Floors first: an unanswered connection cannot be given up on in less than
  # the timeout, so a duration under one says the fixture is not being ignored -
  # refused, unreachable, or answered - and nothing below it means anything.
  if [ "$SMALL" -ge 8 ] && [ "$SMALL" -le 25 ]; then
    pass "the idle fixture is ignoring apt rather than refusing it: Timeout=5 spent ${SMALL}s (2 items x 5s) before giving up"
  else
    fail "Timeout=5 spent ${SMALL}s, and 2 items x 5s is 10s: the fixture server is not holding the connections open, so the two measurements below are meaningless"
  fi

  if [ "$EXPLICIT" -ge 50 ] && [ "$EXPLICIT" -gt "$SMALL" ]; then
    pass "Acquire::http::Timeout is honoured: 5s gave up after ${SMALL}s, 30s after ${EXPLICIT}s (2 items x 30s)"
  else
    fail "Acquire::http::Timeout=5 took ${SMALL}s and =30 took ${EXPLICIT}s, and 2 items x 30s is 60s: the option is not doing what this measurement assumes"
  fi

  # Same shape as the retry verdict above, and for the same reason: the number
  # apt compiles in is not a property of this repository, so what is asserted is
  # the direction that can hurt. apt_update_with_retry pins 30, so a default
  # *below* 30 means the option lengthens apt's patience with a slow mirror,
  # and a default above it means the option shortens it - and shortening is
  # what would make a refresh give up where a bare apt-get would have waited.
  if [ "$DEFAULT_TIMEOUT" -le $((EXPLICIT + 5)) ]; then
    if [ "$DEFAULT_TIMEOUT" -ge $((EXPLICIT - 5)) ]; then
      pass "-o Acquire::http::Timeout=30 is a no-op here: the default gave up after ${DEFAULT_TIMEOUT}s against ${EXPLICIT}s for an explicit 30"
    else
      pass "-o Acquire::http::Timeout=30 is a lengthening here, not a shortening: the default gave up after ${DEFAULT_TIMEOUT}s, the explicit 30 after ${EXPLICIT}s"
    fi
  else
    fail "apt's default waits ${DEFAULT_TIMEOUT}s on an idle connection and apt_update_with_retry pins 30 (${EXPLICIT}s measured): the option has become a shortening, so every refresh site now gives up on a slow mirror sooner than a bare apt-get would"
  fi

  exec 6>&-
  exec 5<&-
else
  echo "NOTE: the idle-timeout legs are off (APT_MEASURE_TIMEOUTS=1 turns them on); they cost ~130s and their recorded output is in dev/log/issues/123/pulls/124/apt/."
fi

# ---------------------------------------------------------------------------
# Part 3: the invariant that does matter - every install has the outer loop
# ---------------------------------------------------------------------------

# A Dockerfile RUN that installs without refreshing metadata in the same
# instruction cannot work at all in a base image that ships no lists, and one
# that refreshes with a bare `apt-get update` skips the retry loop. Both are
# checked per RUN block rather than per file, because a file can hold one
# compliant block and one that is not.
runs_missing_retry_refresh() {
  local dockerfile="$1"
  awk '
    /^RUN/ { block = $0; collecting = 1; line_number = FNR; next }
    collecting { block = block "\n" $0 }
    collecting && !/\\[[:space:]]*$/ {
      if (block ~ /apt-get install/ && block !~ /apt_update_with_retry/) {
        printf "%s:%d\n", FILENAME, line_number
      }
      collecting = 0
      block = ""
    }
    END {
      if (collecting && block ~ /apt-get install/ && block !~ /apt_update_with_retry/) {
        printf "%s:%d\n", FILENAME, line_number
      }
    }
  ' "$dockerfile"
}

mapfile -t DOCKERFILES < <(git ls-files | grep -E '(^|/)Dockerfile$' | sort)
if [ "${#DOCKERFILES[@]}" -eq 0 ]; then
  fail "found no tracked Dockerfiles, so part 3 asserted nothing"
else
  OFFENDERS=""
  for dockerfile in "${DOCKERFILES[@]}"; do
    found="$(runs_missing_retry_refresh "$dockerfile")"
    [ -n "$found" ] && OFFENDERS="$OFFENDERS$found"$'\n'
  done
  if [ -z "$OFFENDERS" ]; then
    pass "every apt-get install in all ${#DOCKERFILES[@]} tracked Dockerfiles sits in a RUN that refreshes through apt_update_with_retry"
  else
    fail "these RUN blocks install without apt_update_with_retry in the same instruction:"$'\n'"$OFFENDERS"
  fi
fi

# The mutation control: the same check over a fixture that does what the
# repository does not, so a check that reports nothing cannot be mistaken for a
# check that found nothing.
cat >"$TMP/Dockerfile.bad" <<'FIXTURE'
FROM ubuntu:24.04
RUN . /tmp/common.sh && \
    apt_update_with_retry && \
    apt-get install -y curl
RUN apt-get update -y && \
    apt-get install -y git
FIXTURE

BAD="$(runs_missing_retry_refresh "$TMP/Dockerfile.bad")"
if [ "$(printf '%s\n' "$BAD" | grep -c ':5$')" = "1" ]; then
  pass "the mutation control is reported: the fixture's second RUN (line 5) installs after a bare apt-get update and is named"
else
  fail "the fixture's bare-update RUN was not reported (got: ${BAD:-nothing}), so part 3's silence over the repository proves nothing"
fi

if [ "$(printf '%s\n' "$BAD" | grep -c ':2$')" = "0" ]; then
  pass "the compliant RUN in the same fixture is not reported"
else
  fail "the fixture's compliant RUN (line 2) was reported, so the check flags correct blocks"
fi

# ---------------------------------------------------------------------------
# Part 4: no refresh in this repository may rely on apt's default retry count
# ---------------------------------------------------------------------------
#
# Part 1 measures the default rather than asserting it, because the default is
# not one number. It is 3 on this workstation and inside ubuntu:24.04 - the
# image every Dockerfile here builds from - and 1 on the ubuntu-24.04 GitHub
# runner, on the same apt 2.8.3, measured by this same fixture (the recorded
# runs are in dev/log/issues/123/pulls/124/apt/). The runner is where
# scripts/measure-disk-space.sh runs, so both environments are ones this
# repository actually uses.
#
# That is the finding this part turns into a guard: "apt already retries three
# times" is a property of a machine, not of a script, so every refresh this
# repository performs has to say the number out loud rather than inherit it.
# The three real refresh sites already do; this keeps a fourth from appearing
# without one.
#
# Checked over logical lines, not physical ones: all three sites spell the
# option on a continuation line, so a per-line grep would report every one of
# them as an offender.
apt_updates_without_explicit_retries() {
  awk '
    # A file that ends mid-continuation must not leak its tail into the next
    # one: FILENAME changes, FNR restarts, and a carried buffer would report a
    # line number that belongs to a different file.
    FNR == 1 { buffer = "" }
    {
      if (buffer == "") { start = FNR }
      current = $0
      continued = (current ~ /\\[[:space:]]*$/)
      if (continued) { sub(/\\[[:space:]]*$/, "", current) }
      buffer = (buffer == "" ? current : buffer " " current)
      if (continued) { next }
      logical = buffer
      buffer = ""
      sub(/^[[:space:]]*/, "", logical)
      if (logical ~ /^#/) { next }
      if (logical ~ /apt-get[[:space:]]+update/ && logical !~ /Acquire::Retries=/) {
        printf "%s:%d\n", FILENAME, start
      }
    }
  ' "$@"
}

# experiments/ is excluded by name and for a stated reason: this suite's own
# fixture runs `apt-get update` with no retry option on purpose - measuring the
# default is what it is for - so including it would make the check demand the
# opposite of the measurement.
mapfile -t APT_SOURCES < <(git ls-files -- '*.sh' '*.yml' '*.yaml' 'Dockerfile' '*/Dockerfile' \
  | grep -v '^dev/log/' | grep -v '^experiments/' | sort)

if [ "${#APT_SOURCES[@]}" -eq 0 ]; then
  fail "found no tracked shell, workflow or Dockerfile sources, so part 4 asserted nothing"
else
  RELYING="$(apt_updates_without_explicit_retries "${APT_SOURCES[@]}")"
  if [ -z "$RELYING" ]; then
    pass "every apt-get update in the ${#APT_SOURCES[@]} tracked sources outside experiments/ passes Acquire::Retries explicitly, so none of them inherits an environment's default"
  else
    fail "these apt-get update calls take whatever retry count the machine happens to default to (1 on a GitHub runner, 3 in ubuntu:24.04):"$'\n'"$RELYING"
  fi
fi

# The mutation control, for the same reason part 3 has one.
cat >"$TMP/relies.sh" <<'FIXTURE'
#!/bin/bash
# apt-get update in a comment is not a call
maybe_sudo apt-get update -y \
  -o Acquire::Retries=3 \
  -o Acquire::http::Timeout=30
apt-get update -y
FIXTURE

RELIES="$(apt_updates_without_explicit_retries "$TMP/relies.sh")"
if [ "$(printf '%s\n' "$RELIES" | grep -c ':6$')" = "1" ]; then
  pass "the mutation control is reported: the fixture's bare apt-get update (line 6) is named"
else
  fail "the fixture's bare apt-get update was not reported (got: ${RELIES:-nothing}), so part 4's silence over the repository proves nothing"
fi

if [ "$(printf '%s\n' "$RELIES" | grep -cE ':(2|3)$')" = "0" ]; then
  pass "  and neither the commented mention nor the three-line call above it is reported"
else
  fail "the fixture's comment or its compliant continuation-line call was reported (got: $RELIES), so the check cannot read the repository's own spelling"
fi

echo
echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
