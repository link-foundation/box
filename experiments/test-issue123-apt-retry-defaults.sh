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
# Measured, both of those change nothing: on Ubuntu 24.04 with apt 2.8.3 all
# three options are already apt's own defaults.
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
# So the install sites are not weaker than the refresh site. What
# apt_update_with_retry adds over plain apt is its *outer* loop - up to 5
# attempts with exponential backoff, clearing /var/lib/apt/lists between them -
# which apt's internal retries do not do, and which is what the mirror-sync
# mismatch it documents (apt exit 100) actually needs. The invariant worth
# holding, then, is not "every install repeats the flags" but "every install is
# preceded by that outer loop", which part 3 checks per Dockerfile RUN block.
#
# This suite is written so that it fails if a future apt changes those
# defaults: then, and only then, the flags stop being a no-op and the install
# sites do need them.
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


def serve():
    global count
    while True:
        conn, _ = srv.accept()
        with lock:
            count += 1
        # SO_LINGER with a zero timeout makes close() send RST rather than FIN,
        # so apt sees a reset connection instead of a clean end of stream.
        conn.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        conn.close()


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
  # apt's methods exit after the parent does; without a settle the last
  # connection can land after the count is read.
  sleep 0.5
}

connections_since_last_read() {
  local answer
  echo x >&4
  read -r answer <&3
  printf '%s' "$answer"
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

if [ "$DEFAULT_CONNECTIONS" = "${OBSERVED[3]}" ]; then
  pass "apt's default retry count is 3: the default opens $DEFAULT_CONNECTIONS connections, the same as an explicit Acquire::Retries=3"
else
  fail "apt's default opened $DEFAULT_CONNECTIONS connections and an explicit Acquire::Retries=3 opened ${OBSERVED[3]}: the default is no longer 3, so -o Acquire::Retries=3 has stopped being a no-op and the install sites in this repository now need it ($APT_VERSION)"
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

  if [ "$DEFAULT_TIMEOUT" -ge $((EXPLICIT - 5)) ] && [ "$DEFAULT_TIMEOUT" -le $((EXPLICIT + 5)) ]; then
    pass "apt's default idle timeout is 30s: the default gave up after ${DEFAULT_TIMEOUT}s against ${EXPLICIT}s for an explicit 30"
  else
    fail "apt's default gave up after ${DEFAULT_TIMEOUT}s and an explicit 30 after ${EXPLICIT}s: the default is no longer 30, so -o Acquire::http::Timeout=30 has stopped being a no-op"
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

echo
echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
