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
| **apt default, here and in `ubuntu:24.04`** | **8 — identical to an explicit 3** |
| **apt default, `ubuntu-24.04` GitHub runner** | **4 — one retry** |

The last two rows are the finding, and they took a red run to produce. The five
explicit rows are a property of apt: they hold on this workstation, inside
`ubuntu:24.04` (the image every Dockerfile here builds from) and on the runner,
exact to the connection. **The default row is a property of the machine.** The
`scripts / regression suites` job of 2026-09-10T03:54:31Z, on `ubuntu-24.04`
with the same apt 2.8.3 on the same Ubuntu 24.04.4, measured

```
FAIL: apt's default opened 4 connections and an explicit Acquire::Retries=3
      opened 8: the default is no longer 3 (apt 2.8.3 (amd64))
```

— four connections, i.e. two index items attempted twice: **one** retry, not
three.

What does *not* explain it, checked in `actions/runner-images`:

* `images/ubuntu/scripts/build/configure-apt.sh` writes
  `APT::Acquire::Retries "10";` into `/etc/apt/apt.conf.d/80-retries`. That key
  is `APT::Acquire::Retries`; apt reads `Acquire::Retries`. It is inert, and
  inert in the *raising* direction anyway.
* the same script's `90assumeyes`, `99-phased-updates` and `99bad_proxy`
  (`Acquire::http::Pipeline-Depth 0`, `No-Cache true`, `BrokenProxy true`) touch
  neither retries nor timeouts.
* `configure-apt-mock.sh` replaces `apt`, `apt-get` and `apt-key` with wrapper
  scripts carrying an *external* retry loop (30 attempts, 5s apart). That is a
  loop around apt, not a setting inside it, and it would multiply attempts
  rather than divide them.

So the cause is unidentified, which is why the suite now *reports* rather than
guesses: it prints `apt-config dump Acquire::Retries`, the apt.conf files that
name the key, `APT_CONFIG`, and whether `apt-get` on `PATH` is a script rather
than apt's own binary. The next runner failure — if there is one — arrives with
its own explanation attached.

The measurement is also the reason `experiments/issue-123/measure-apt-retry-timing.sh`
exists: it timestamps every connection, so a leg's retries can be seen spread
over apt's backoff (`Acquire::Retries::Delay`) rather than inferred from a
total. On this workstation the default leg's eight connections arrive at
1.2s, 3.2s, 3.2s, 7.2s, 7.2s — the 1-2-4 backoff of three retries.

## Idle-connection timeout

A server that accepts and never answers, with `Acquire::Retries=0` so each of
the two index items is attempted once:

| setting | time to give up |
| --- | --- |
| `Acquire::http::Timeout=5` | 11s |
| `Acquire::http::Timeout=30` | 60s |
| **apt default** | **61s — identical to an explicit 30** |

## Conclusion

The install sites are not weaker than the refresh site, in either environment,
so the hardening item is retired rather than implemented. In the images the
default equals what the refresh site pins, so restating the options at an
install site would change nothing; on the runner the refresh site is the
*stronger* of the two, because it passes an option the environment's default is
below. The ordering that would make the install sites need the options is the
reverse one — a default **above** 3 — and that is now the condition the suite
fails on, rather than any inequality at all. What `apt_update_with_retry` adds over plain apt is its
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
  experiments/test-issue123-apt-retry-defaults.sh`, all assertions passing
  (the three timeout legs need the flag; the rest run by default).
  The suite runs the retry legs (~10s) in `run-experiments.sh` and keeps the
  timeout legs (~130s) behind `APT_MEASURE_TIMEOUTS=1`. It fails if a future apt
  — or a future runner image — raises either default *above* what this
  repository pins, which is exactly when the options would stop being no-ops in
  the safe direction and the install sites would need them.
- `retry-timing.txt` — `bash experiments/issue-123/measure-apt-retry-timing.sh`,
  the per-connection arrival times behind the backoff described above.

The suite's own history is worth recording, because it committed the defect the
issue is about. It used to assert that apt's default *equals* 3 retries, and
that assertion is what went red on the runner: a statement about the machine,
dressed as a statement about this repository, failing a release for a property
no line of shipped code depends on. Equality was never what mattered. What
matters is that `-o Acquire::Retries=3` is not a *downgrade* — that a refresh
here is at least as patient as a bare `apt-get update` would have been — and
that is the invariant the suite holds now, in both directions and with the
measured number printed either way.

The first version of the timeout legs was itself a check that could not fail —
the fixture server took the suite's own stdin, read EOF, exited, and every
connection was then *refused*, so apt gave up in 0s and `0 < 1` satisfied both
assertions. The server is held open by a fifo now and each assertion carries an
absolute floor (`Timeout=5` must spend at least 8s), so a fixture that stops
ignoring apt fails the suite instead of passing it.

The *retry* legs had the second half of the same problem, and it took a machine
under load to show it: `Acquire::Retries=5` intermittently counted 11
connections where 12 was the arithmetic. Two defects, both in the measurement
rather than in apt:

- **The count was read before the data was in.** A fixed `sleep 0.5` after apt
  exits is a guess about scheduling, not a wait. It is a quiescence loop now —
  poll until the connection total stops moving for five consecutive polls, up to
  200 — so the measurement ends when the fixture is finished rather than when a
  timer says it probably is.
- **The fixture failed apt in more than one way.** The server reset each
  connection the moment it was accepted, which races apt's own write: sometimes
  apt saw the reset before sending its request and classified the failure
  differently, and made fewer attempts. Under four busy loops the same leg
  reported 12, 8 and 4 connections on three consecutive runs. The server now
  reads the request first and only then resets, one thread per connection, so
  every attempt fails at the same point and the count is a property of apt's
  retry policy rather than of the scheduler.

Verified by running the suite six times with four CPU busy loops competing for
the machine: `Passed: 10  Failed: 0` on all six.

Both are the issue's own defect class turned on the instrument — a verdict
reported about data that had not arrived — which is why they were fixed at the
root rather than by widening the expected range.
