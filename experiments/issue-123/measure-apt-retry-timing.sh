#!/usr/bin/env bash
# measure-apt-retry-timing.sh
#
# Why apt's default retry count is not a constant this repository can assert.
#
# test-issue123-apt-retry-defaults.sh measured apt's default as 3 retries on the
# workstation this branch was written on and failed on the GitHub runner, where
# the same apt 2.8.3 on the same Ubuntu 24.04.4 opened 4 connections for the
# default and 8 for an explicit Acquire::Retries=3. This script prints the
# arrival time of every connection of a leg, so the difference can be seen
# rather than guessed: apt delays its retries (Acquire::Retries::Delay, on by
# default), and a leg's connections therefore arrive spread over seconds.
#
# Usage:
#   bash experiments/issue-123/measure-apt-retry-timing.sh [SETTLE_SECONDS]
#
# Offline: the only server involved is the local one this script starts.

set -uo pipefail

SETTLE="${1:-25}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/server.py" <<'PY'
import socket, struct, sys, threading, time

start = time.monotonic()
lock = threading.Lock()

srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 0))
srv.listen(64)
print(srv.getsockname()[1], flush=True)


def handle(conn):
    with lock:
        print("conn %.3f" % (time.monotonic() - start), flush=True)
    conn.settimeout(5)
    try:
        while True:
            chunk = conn.recv(4096)
            if not chunk or b"\r\n\r\n" in chunk:
                break
    except OSError:
        pass
    try:
        conn.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
        conn.close()
    except OSError:
        pass


def serve():
    while True:
        c, _ = srv.accept()
        threading.Thread(target=handle, args=(c,), daemon=True).start()


threading.Thread(target=serve, daemon=True).start()
for line in sys.stdin:
    with lock:
        print("mark %s %.3f" % (line.strip(), time.monotonic() - start), flush=True)
PY

mkdir -p "$TMP/empty" "$TMP/lists/partial" "$TMP/cache/archives/partial"
mkfifo "$TMP/ask"
python3 "$TMP/server.py" <"$TMP/ask" >"$TMP/log" 2>&1 &
exec 4>"$TMP/ask"
PORT=""
for _ in $(seq 1 50); do
  PORT="$(head -1 "$TMP/log" 2>/dev/null)"
  [ -n "$PORT" ] && break
  sleep 0.1
done
echo "server port: $PORT"
echo "deb [trusted=yes] http://127.0.0.1:$PORT/ubuntu noble main" >"$TMP/sources.list"

leg() { # leg LABEL [apt options...]
  local label="$1"
  shift
  echo "begin-$label" >&4
  rm -rf "$TMP/lists"
  mkdir -p "$TMP/lists/partial"
  local t0 t1
  # Nanoseconds and integer arithmetic, not `bc`: bc is not installed in
  # ubuntu:24.04 and its absence would print an empty duration rather than say
  # so - a measurement reported about data never obtained, which is the defect
  # class this whole issue is about.
  t0="$(date +%s%N)"
  apt-get update -qq \
    -o Dir::Etc::sourcelist="$TMP/sources.list" \
    -o Dir::Etc::sourceparts="$TMP/empty" \
    -o Dir::Etc::parts="$TMP/empty" \
    -o Dir::Etc::main=/dev/null \
    -o Dir::State::lists="$TMP/lists" \
    -o Dir::Cache="$TMP/cache" \
    -o Debug::NoLocking=1 \
    "$@" >/dev/null 2>&1
  t1="$(date +%s%N)"
  printf 'apt-get exited after %s.%ss\n' "$(((t1 - t0) / 1000000000))" "$((((t1 - t0) / 100000000) % 10))"
  echo "end-$label" >&4
  sleep "$SETTLE"
  echo "settled-$label" >&4
}

echo "apt: $(apt-get --version | head -1)  os: $(sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' /etc/os-release)"
echo "configured Acquire::Retries: $(apt-config dump Acquire::Retries 2>/dev/null || echo '<unset>')"

leg default
leg explicit-3 -o Acquire::Retries=3
leg explicit-1 -o Acquire::Retries=1

exec 4>&-
sleep 1
echo
echo "=== timeline (seconds since server start) ==="
tail -n +2 "$TMP/log"
echo
echo "=== connections per leg ==="
awk '
  /^mark begin-/ { leg = substr($2, 7); n[leg] = 0; order[++k] = leg; next }
  /^mark settled-/ { next }
  /^mark end-/ { next }
  /^conn / { if (leg != "") n[leg]++ }
  END { for (i = 1; i <= k; i++) printf "  %-12s %d connections\n", order[i], n[order[i]] }
' "$TMP/log"
