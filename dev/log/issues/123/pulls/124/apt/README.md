# apt's own defaults, measured (issue #123)

`apt_update_with_retry` — `ubuntu/24.04/common.sh`, duplicated in
`scripts/measure-disk-space.sh` — refreshes apt metadata with three options:

```
-o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30
```

and none of the ~40 `apt-get install` lines in this repository passes any of
them. That asymmetry was on this branch's list as a hardening item: restate the
flags at each install site, or drop them into `/etc/apt/apt.conf.d` so every apt
process inherits them.

Measured, both are no-ops. On Ubuntu 24.04 with apt 2.8.3 — the runner, the
images and this container — all three options are already apt's defaults.

## Retries

A server that accepts a connection and resets it (`SO_LINGER` 0, so the peer
sees RST rather than a clean close: the transient failure `Acquire::Retries`
covers — apt treats an HTTP 503 as an answer and does not retry it), counting
the connections one `apt-get update` opens:

| setting | connections |
| --- | --- |
| `Acquire::Retries=0` | 2 (2 index items, one attempt each) |
| `Acquire::Retries=1` | 4 |
| `Acquire::Retries=2` | 6 |
| `Acquire::Retries=3` | 8 |
| `Acquire::Retries=5` | 12 |
| **apt default** | **8 — identical to an explicit 3** |

## Idle-connection timeout

A server that accepts and never answers, with `Acquire::Retries=0` so each of
the two index items is attempted once:

| setting | time to give up |
| --- | --- |
| `Acquire::http::Timeout=5` | 11s |
| `Acquire::http::Timeout=30` | 60s |
| **apt default** | **61s — identical to an explicit 30** |

## Conclusion

The install sites are not weaker than the refresh site; there is nothing for
them to inherit that they do not already have, so the hardening item is retired
rather than implemented. What `apt_update_with_retry` adds over plain apt is its
*outer* loop — up to 5 attempts, exponential backoff, `/var/lib/apt/lists`
cleared between them — because apt's internal retries re-fetch over the same
broken mirror state, and a mirror mid-sync (apt exit 100) is what that loop
exists for. The invariant worth holding for the install sites is therefore that
each one is preceded by that loop in the same shell, which is checked per
Dockerfile `RUN` block.

Note also what none of this covers: a transfer that is alive but slow. The
timeouts above bound an *idle* connection, so the 20 kB/s trickle measured on
the `measure-disk-space` job would not have been ended by any of them.

## Files

- `apt-retry-defaults-full.txt` — `APT_MEASURE_TIMEOUTS=1 bash
  experiments/test-issue123-apt-retry-defaults.sh`, 13 assertions, all passing.
  The suite runs the retry legs (~10s) in `run-experiments.sh` and keeps the
  timeout legs (~130s) behind `APT_MEASURE_TIMEOUTS=1`; it fails if a future apt
  changes either default, which is exactly when the flags would stop being
  no-ops and the install sites would need them.

The first version of the timeout legs was itself a check that could not fail —
the fixture server took the suite's own stdin, read EOF, exited, and every
connection was then *refused*, so apt gave up in 0s and `0 < 1` satisfied both
assertions. The server is held open by a fifo now and each assertion carries an
absolute floor (`Timeout=5` must spend at least 8s), so a fixture that stops
ignoring apt fails the suite instead of passing it.
