`/etc/apt/apt.conf.d/80-retries` sets `APT::Acquire::Retries`, a key apt does not read, so the intended 10-retry hardening has no effect

### Summary

`images/ubuntu/scripts/build/configure-apt.sh` (and the identical
`images/ubuntu-slim/scripts/build/configure-apt.sh`) writes:

```bash
# Enable retry logic for apt up to 10 times
echo "APT::Acquire::Retries \"10\";" > /etc/apt/apt.conf.d/80-retries
```

apt reads the option **`Acquire::Retries`**, not `APT::Acquire::Retries`. The
`APT::`-prefixed name is a *different* configuration key that nothing in apt
consults, so `80-retries` is inert: the comment says "up to 10 times", and the
running default is apt's compiled-in `3` (or whatever another file sets),
never 10.

### Proof, offline

`APT_CONFIG` names an extra file apt reads during `pkgInitConfig`, exactly as it
reads `/etc/apt/apt.conf.d`, so it reproduces the file's effect without touching
the system:

```console
$ printf 'APT::Acquire::Retries "10";\n' > /tmp/80-retries
$ APT_CONFIG=/tmp/80-retries apt-config dump Acquire::Retries
            # <- empty: apt did not read it under this key
$ APT_CONFIG=/tmp/80-retries apt-config dump | grep -i retries
APT::Acquire::Retries "10";
            # <- present in config space, under a name apt never queries

$ printf 'Acquire::Retries "10";\n' > /tmp/80-retries-fixed
$ APT_CONFIG=/tmp/80-retries-fixed apt-config dump Acquire::Retries
Acquire::Retries "10";
            # <- the key apt actually reads
```

apt resolves the option in `apt-pkg/acquire-item.cc`:

```cpp
Retries(_config->FindI("Acquire::Retries", 3))
```

`FindI("Acquire::Retries", 3)` looks up `Acquire::Retries` and falls back to `3`.
`APT::Acquire::Retries` is never on that path.

### Impact

The retry-count hardening the file was added for silently does nothing on every
Ubuntu runner image. This intersects
[#14594](https://github.com/actions/runner-images/issues/14594) (apt stalling on
`azure.archive.ubuntu.com`): a maintainer reading `80-retries` would reasonably
believe apt already retries 10 times, when in fact it does not retry per the file
at all. Note the *direction* matters for that issue — actually applying `10`
would make apt retry the failing Azure mirror **more**, so the fix here is a
decision, not a mechanical rename.

### Suggested fix

Two honest options; the maintainers own which:

1. If 10 retries is wanted, correct the key:
   ```diff
   -echo "APT::Acquire::Retries \"10\";" > /etc/apt/apt.conf.d/80-retries
   +echo "Acquire::Retries \"10\";" > /etc/apt/apt.conf.d/80-retries
   ```
   — but weigh this against #14594, where more retries against a dead mirror is
   the opposite of what is wanted.

2. If the retry count is not actually the lever (the mirror-failover in
   `configure-apt-sources.sh` is), remove the inert file so it stops implying a
   setting that is not in force.

### How this was found

Comparing apt behaviour across environments for
[link-foundation/box#123](https://github.com/link-foundation/box/issues/123): a
test measured apt's default retry count by counting connections to a fixture
mirror, and found the `ubuntu-24.04` runner's effective default is **1**, not the
`3` measured on the same apt 2.8.3 elsewhere. Tracing what could set it led to
`80-retries`, which turned out to name the word without setting the value. The
reproduction is `experiments/issue-123/repro-apt-retries-key.sh` in that repo.
(The runner's default of **1** remains unexplained by this file — it is in the
*raising* direction and inert — so this report is scoped to the inert key, which
is certain, and not to the cause of the 1, which is not.)
