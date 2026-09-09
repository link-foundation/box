The post step's builder removal inherits buildx's 20s status timeout, so a green job collects an unactionable "failed to remove one or more builders" warning

### Contributing guidelines

- [X] I've read the [contributing guidelines](https://github.com/docker/setup-buildx-action/blob/master/.github/CONTRIBUTING.md) and wholeheartedly agree

### I've found a bug, and:

- [X] The documentation does not mention anything about my problem
- [X] There are no open or closed issues that are related to my problem

### Description

The post step removes the builder with

```ts
// src/main.ts:245-252
          const rmCmd = await buildx.getCommand(['rm', stateHelper.builderName, ...(stateHelper.keepState ? ['--keep-state'] : [])]);
          await Exec.getExecOutput(rmCmd.command, rmCmd.args, {
            ignoreReturnCode: true
          }).then(res => {
            if (res.stderr.length > 0 && res.exitCode != 0) {
              core.warning(res.stderr.match(/(.*)\s*$/)?.[0]?.trim() ?? 'unknown error');
```

no `--timeout` among the arguments. Since buildx v0.36.0, `buildx rm` applies
its `--timeout` — default 20s, documented as "the default timeout for loading
builder status" — to the removal itself, which includes deleting the BuildKit
state volume ([docker/buildx#4067](https://github.com/docker/buildx/issues/4067),
with a standalone reproduction). Deleting that volume takes time proportional
to the build cache in it, so on a job that built something large the delete is
still in flight at 20s, `buildx rm` exits 1, and this step turns its stderr
into a warning annotation on a job that succeeded.

The annotation asks the reader for something they cannot do — the builder is
already gone from buildx's store, and on a GitHub-hosted runner the whole
machine is destroyed seconds later. The bigger and slower the build, the more
likely it appears, which is the wrong way round.

### Expected behaviour

The post-job cleanup either completes, or does not warn about a cleanup whose
only purpose was to release resources that are about to be released anyway.
Concretely: pass a timeout that fits a volume delete, e.g.

```diff
-          const rmCmd = await buildx.getCommand(['rm', stateHelper.builderName, ...(stateHelper.keepState ? ['--keep-state'] : [])]);
+          // `buildx rm` bounds the whole removal - state volume delete
+          // included - with the builder-status timeout (20s by default), so a
+          // large build cache reliably exceeds it. Removal here is
+          // best-effort cleanup, not a status query: don't inherit that bound.
+          //   https://github.com/docker/buildx/issues/4067
+          const rmCmd = await buildx.getCommand(['rm', stateHelper.builderName, '--timeout', '0', ...(stateHelper.keepState ? ['--keep-state'] : [])]);
```

`--timeout 0` disables the deadline (`runRm` installs it only `if in.timeout >
0`), which is exactly the pre-v0.36.0 behaviour; a generous fixed value such as
`--timeout 10m` would work as well. It needs a guard for older buildx versions
— `rm` grew the flag in v0.32.0, and v0.31.0 hard-coded the same 20s around
`LoadNodes` only — which `Buildx.versionSatisfies` already makes easy.

Reducing the annotation to `core.info` when the failure is a
`context deadline exceeded` would also remove the false alarm, but it hides a
real leak on self-hosted runners, so the timeout is the better lever.

### Actual behaviour

The job is green and carries

```
##[warning]ERROR: failed to remove one or more builders
```

The state volume is left behind, and the builder entry is dropped from buildx's
store regardless, so nothing can name the volume afterwards.

### Repository URL

https://github.com/link-foundation/box

### Workflow run URL

https://github.com/link-foundation/box/actions/runs/34293699247/job/102294023714

### YAML workflow

```yaml
      # .github/workflows/release-full.yml (the job builds a large multi-stage
      # image and pushes it; the action is reached through a thin composite
      # that pre-pulls the BuildKit image and otherwise just calls it).
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v4
        with:
          driver-opts: image=moby/buildkit:buildx-stable-1

      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: .
          platforms: linux/amd64
          push: true
```

### Workflow logs

```text
2026-09-09T01:04:55.8350062Z Post job cleanup.
2026-09-09T01:04:56.0231001Z ##[group]Removing builder
2026-09-09T01:04:56.1340264Z [command]/usr/bin/docker buildx rm builder-1e6b2f9a-bd2b-4665-9226-1218fa1d3e6b
2026-09-09T01:05:16.1874216Z failed to remove builder-1e6b2f9a-...: failed to remove node builder-1e6b2f9a-...0: Delete "http://%2Fvar%2Frun%2Fdocker.sock/v1.48/volumes/buildx_buildkit_builder-1e6b2f9a-...0_state": context deadline exceeded
2026-09-09T01:05:16.1876662Z ERROR: failed to remove one or more builders
2026-09-09T01:05:16.1921240Z ##[warning]ERROR: failed to remove one or more builders
2026-09-09T01:05:16.1923398Z ##[endgroup]
```

20.053s between the command and the error. `ubuntu-24.04` runner, buildx
v0.36.1, dockerd API v1.48. The job itself succeeded, built and pushed.

### Additional info

**Workaround we are using**: `cleanup: false`, decided from the runner —

```yaml
        with:
          cleanup: ${{ runner.environment != 'github-hosted' }}
```

An ephemeral GitHub-hosted runner is destroyed with its volumes seconds after
the post step, so there is nothing there for the removal to reclaim and the
warning is pure noise; a persistent self-hosted runner is the case the cleanup
exists for and keeps it. That works for us, but it trades the warning for the
leak on exactly the machines that cannot afford one, which is why the timeout
belongs in the argv.

**Standalone reproduction** (no CI, no large cache — a socket proxy stalls the
volume DELETE and nothing else) is in
[docker/buildx#4067](https://github.com/docker/buildx/issues/4067); it shows
v0.36.1 failing at 20s and leaking the volume, v0.35.0 waiting and succeeding,
and both `--timeout 0` and `--timeout 60s` fixing it on v0.36.1.

Found while removing every warning annotation from a repository's CI
(link-foundation/box#121).
