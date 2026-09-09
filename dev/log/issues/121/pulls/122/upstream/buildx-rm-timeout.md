`buildx rm` applies the builder-status `--timeout` to the removal itself, aborting an in-flight volume delete at 20s and leaking the state volume

### Contributing guidelines

- [X] I've read the [contributing guidelines](https://github.com/docker/buildx/blob/master/.github/CONTRIBUTING.md) and wholeheartedly agree

### I've found a bug and checked that ...

- [X] ... the documentation does not mention anything about my problem
- [X] ... there are no open or closed issues that are related to my problem

### Description

`docker buildx rm` gives the *whole* removal — stopping the container and
deleting the BuildKit state volume — the budget of `--timeout`, which is
documented as being for loading builder status:

```go
// commands/root.go:153-155 (v0.36.1, unchanged on master)
func setBuilderStatusTimeoutFlag(flags *pflag.FlagSet, target *time.Duration) {
	flags.DurationVar(target, "timeout", 20*time.Second, "Override the default timeout for loading builder status")
}
```

```go
// commands/rm.go:86-97 (v0.36.1)
				nodes, err := b.LoadNodes(timeoutCtx, builder.WithSkippedImageOpt())
				...
				err1 := rm(timeoutCtx, nodes, in)
				if err := txn.Remove(b.Name); err != nil {
					return err
				}
```

Deleting a state volume is not a status query, and how long it takes is
proportional to how much build cache the builder accumulated — not to anything
20 seconds bounds. When the delete is still in flight at the deadline the
command fails, and since `txn.Remove(b.Name)` runs regardless of `err1`, the
builder disappears from the store while its volume stays on disk, now with no
name left to identify it by.

This is a regression in v0.36.0; v0.35.0 waits for the removal.

### Expected behaviour

`docker buildx rm` waits for the removal it asked the daemon to perform — or,
if it is to be bounded, bounds it with a budget of its own rather than with the
status-loading timeout — and does not drop the builder from the store while the
volume it names is still there.

### Actual behaviour

The command exits 1 after exactly the status timeout with
`ERROR: failed to remove one or more builders`, leaves the state volume behind,
and drops the builder entry anyway. The delete itself succeeds moments later.

### Buildx version

github.com/docker/buildx v0.36.1 1d8dde89b8aba914e05e45366770736fea1fd690

(also reproduced on v0.37.0; v0.35.0 is unaffected)

### Docker info

```text
Client: Docker Engine - Community
 Version:    29.6.0
 Context:    default
Server:
 Server Version: 29.6.0
 Storage Driver: fuse-overlayfs
 Cgroup Driver: cgroupfs
 Cgroup Version: 2
 Plugins:
  Volume: local
 containerd version: e53c7c1516c3b2bff98eb76f1f4117477e6f4e66
 runc version: v1.3.6-0-g491b69ba
 Kernel Version: 6.8.0-139-generic
 Operating System: Ubuntu 24.04.4 LTS
 OSType: linux
 Architecture: x86_64
 CPUs: 6
 Total Memory: 11.68GiB
```

The CI job in "Additional info" hit it on `ubuntu-24.04` with the runner
image's own dockerd (API v1.48).

### Builders list

Taken during the reproduction below, just before the `rm` (two unrelated
builders from another experiment trimmed):

```text
NAME/NODE               DRIVER/ENDPOINT                   STATUS    BUILDKIT   PLATFORMS
rmtimeout-531610        docker-container
 \_ rmtimeout-5316100    \_ stalled-531610                running   v0.32.2    linux/amd64 (+3), linux/386
default                 docker
 \_ default              \_ default                       running   v0.31.0    linux/amd64 (+3), linux/386
stalled-531610          docker
 \_ stalled-531610       \_ stalled-531610                running   v0.31.0    linux/amd64 (+3), linux/386
```

### Configuration

The point is only that the daemon has not answered the volume delete *yet*, so
the script below simulates the slow daemon rather than building a cache large
enough to take 20 seconds to unlink: a proxy in front of the Docker socket
forwards every byte unchanged and holds back only `DELETE /<api>/volumes/...`.
The inspection has to be chunk-level rather than request-level, because the
Docker client reuses one keep-alive connection for many requests.

Needs `docker`, `python3` and a buildx binary. Takes about 30 seconds.

```bash
#!/usr/bin/env bash
# Usage: BUILDX=/path/to/buildx bash repro.sh
set -euo pipefail
BUILDX="${BUILDX:-docker-buildx}"
DELAY="${DELAY:-25}"
W="$(mktemp -d)"; CTX="stalled-$$"; B="rmtimeout-$$"; PID=""
cleanup() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null || true
  docker volume rm "buildx_buildkit_${B}0_state" >/dev/null 2>&1 || true
  docker rm -f "buildx_buildkit_${B}0" >/dev/null 2>&1 || true
  "$BUILDX" rm "$B" >/dev/null 2>&1 || true
  docker context rm -f "$CTX" >/dev/null 2>&1 || true
  rm -rf "$W"
}
trap cleanup EXIT

cat > "$W/proxy.py" <<'PY'
import os, socket, socketserver, threading, time
UPSTREAM, LISTEN = os.environ.get("UPSTREAM_SOCK", "/var/run/docker.sock"), os.environ["LISTEN_SOCK"]
DELAY = float(os.environ.get("DELAY_SECONDS", "25"))
def pump(src, dst, stall):
    try:
        while True:
            data = src.recv(65536)
            if not data: break
            if stall and b"DELETE /" in data and b"/volumes/" in data:
                print("[proxy] stalling %s for %ss" % (data.split(b"\r\n",1)[0].decode(errors="replace"), DELAY), flush=True)
                time.sleep(DELAY)
            dst.sendall(data)
    except OSError: pass
    finally:
        try: dst.shutdown(socket.SHUT_WR)
        except OSError: pass
class H(socketserver.BaseRequestHandler):
    def handle(self):
        up = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); up.connect(UPSTREAM)
        threading.Thread(target=pump, args=(up, self.request, False), daemon=True).start()
        pump(self.request, up, True)
class S(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True
if os.path.exists(LISTEN): os.unlink(LISTEN)
s = S(LISTEN, H); os.chmod(LISTEN, 0o666); s.serve_forever()
PY

"$BUILDX" version
LISTEN_SOCK="$W/docker.sock" DELAY_SECONDS="$DELAY" python3 "$W/proxy.py" >"$W/proxy.log" 2>&1 &
PID=$!
for _ in $(seq 1 50); do [ -S "$W/docker.sock" ] && break; sleep 0.1; done

docker context create "$CTX" --docker "host=unix://$W/docker.sock" >/dev/null
"$BUILDX" create --name "$B" --driver docker-container "$CTX" >/dev/null
"$BUILDX" inspect --bootstrap "$B" >/dev/null 2>&1

echo "==> $BUILDX rm ${RMARGS:-} $B"
t0=$(date +%s); set +e; out="$("$BUILDX" rm ${RMARGS:-} "$B" 2>&1)"; rc=$?; set -e
echo "$out"
echo "==> exit $rc after $(($(date +%s) - t0))s (the daemon answers after ${DELAY}s)"
docker volume inspect "buildx_buildkit_${B}0_state" >/dev/null 2>&1 \
  && echo "==> state volume LEAKED" || echo "==> state volume removed"
"$BUILDX" inspect "$B" >/dev/null 2>&1 \
  && echo "==> builder still in the store" || echo "==> builder entry dropped from the store"
```

### Build logs

```text
$ BUILDX=./buildx-v0.36.1 bash repro.sh
github.com/docker/buildx v0.36.1 1d8dde89b8aba914e05e45366770736fea1fd690
==> ./buildx-v0.36.1 rm rmtimeout-531610
failed to remove rmtimeout-531610: failed to remove node rmtimeout-5316100: Delete "http://%2Ftmp%2Ftmp.hU31tUGWsv%2Fdocker.sock/v1.55/volumes/buildx_buildkit_rmtimeout-5316100_state": context deadline exceeded
ERROR: failed to remove one or more builders
==> exit 1 after 20s (the daemon answers after 25s)
==> state volume LEAKED
==> builder entry dropped from the store

$ BUILDX=./buildx-v0.35.0 bash repro.sh
github.com/docker/buildx v0.35.0 a319e5b15052cf6557ceb666eb8ff6e32380b782
==> ./buildx-v0.35.0 rm rmtimeout-525504
rmtimeout-525504 removed
==> exit 0 after 25s (the daemon answers after 25s)
==> state volume removed
==> builder entry dropped from the store
```

### Additional info

**Where the regression is.** `rm()` used to receive the caller's context.
Commit
[`8db02212`](https://github.com/docker/buildx/commit/8db022122dfb7315bb553f47265552fbbae05596)
("rm: clean up all nodes before returning errors", 2026-07-06) changed it:

```diff
-				err1 := rm(ctx, nodes, in)
+				err1 := rm(timeoutCtx, nodes, in)
```

The same commit made the identical change in `rmAllInactive`, so
`docker buildx rm --all-inactive` inherits it too. Everything else that commit
does — parallel node cleanup, joined errors — is unrelated to the context it
passes.

**Where it is actually hit.** `docker/setup-buildx-action`'s post step, which
runs on every CI job that sets up a container-driver builder, never passes a
timeout, and discards the exit code:

```ts
// docker/setup-buildx-action src/main.ts:245-252
          const rmCmd = await buildx.getCommand(['rm', stateHelper.builderName, ...(stateHelper.keepState ? ['--keep-state'] : [])]);
          await Exec.getExecOutput(rmCmd.command, rmCmd.args, {
            ignoreReturnCode: true
          }).then(res => {
            if (res.stderr.length > 0 && res.exitCode != 0) {
              core.warning(res.stderr.match(/(.*)\s*$/)?.[0]?.trim() ?? 'unknown error');
```

So the job stays green and collects a warning annotation nobody can act on.
From a run of ours that built a large multi-stage image, succeeded, pushed and
published —
[link-foundation/box job 102294023714](https://github.com/link-foundation/box/actions/runs/34293699247/job/102294023714),
buildx v0.36.1, dockerd API v1.48:

```text
2026-09-09T01:04:56.1340264Z [command]/usr/bin/docker buildx rm builder-1e6b2f9a-bd2b-4665-9226-1218fa1d3e6b
2026-09-09T01:05:16.1874216Z failed to remove builder-1e6b2f9a-...: failed to remove node builder-1e6b2f9a-...0: Delete "http://%2Fvar%2Frun%2Fdocker.sock/v1.48/volumes/buildx_buildkit_builder-1e6b2f9a-...0_state": context deadline exceeded
2026-09-09T01:05:16.1876662Z ERROR: failed to remove one or more builders
2026-09-09T01:05:16.1921240Z ##[warning]ERROR: failed to remove one or more builders
```

20.053 s. The larger the build cache, the likelier the warning — which is the
wrong way round for a message meant to be read.

**Workarounds**, both verified with the script above on v0.36.1:

- `docker buildx rm --timeout 0 <name>` — `runRm` installs the deadline only
  `if in.timeout > 0`, so `0` restores the v0.35.0 behaviour exactly:
  `exit 0 after 26s`, volume removed.
- `docker buildx rm --timeout 60s <name>` — any budget larger than the delete
  needs: `exit 0 after 25s`, volume removed.
- Through `docker/setup-buildx-action` neither is reachable, since the post
  step builds the argv itself. The only lever there is `cleanup: false`, which
  is right on an ephemeral GitHub-hosted runner — the machine and its volumes
  are destroyed seconds later anyway — and wrong on a persistent self-hosted
  one, where it trades the warning for the leak.

**Suggested fix.** Keep the status timeout on the status query:

```diff
--- a/commands/rm.go
+++ b/commands/rm.go
@@
 				nodes, err := b.LoadNodes(timeoutCtx, builder.WithSkippedImageOpt())
 				if err != nil {
 					if err1 := txn.Remove(b.Name); err1 != nil {
 						return err1
 					}
 					return err
 				}
 
-				err1 := rm(timeoutCtx, nodes, in)
+				// Removal is not a status query: it stops a container and
+				// deletes a state volume whose size is the build cache. Bound
+				// it with ctx, not with --timeout, which is documented as
+				// "the default timeout for loading builder status".
+				err1 := rm(ctx, nodes, in)
 				if err := txn.Remove(b.Name); err != nil {
 					return err
 				}
```

and the same one line in `rmAllInactive`. That restores the v0.35.0 behaviour
while leaving intact everything commit `8db02212` was for.

If bounding the removal is wanted, a separate flag — or a `--timeout` whose
help text covers the whole command — would make it a deliberate choice rather
than an inherited one. Either way the store entry should survive a failed
removal, or the leaked volume becomes unnameable.

Found while removing every warning annotation from a repository's CI
(link-foundation/box#121). The reproduction above is the reduced form of
`experiments/issue-121-buildx-rm-timeout/reproduce-rm-timeout.sh` there.
