# Probe: how a commit message became 56 failure annotations

Release run [34293699247](https://github.com/link-foundation/box/actions/runs/34293699247)
finished with every build job green and 58 annotations at level `failure`
against those same green jobs, path `.github`, line numbers that point at
nothing. 56 of them read:

```
Process completed with exit code 143.\n ##[error]The runner has received a shutdown signal.\n\n11 MB of disk consumed across the whole 4.5-minute export with 88 …
```

That is the body of commit
[a2e6420](https://github.com/link-foundation/box/commit/a2e6420), which explains
a fix for jobs that had been killed with exit code 143 and quotes the runner's
own messages while doing so. Nothing failed in run 34293699247. The commit
message was read as if it were the build's own output.

## The chain

**1. The event payload is baked into the builder.** `docker/setup-buildx-action`
creates a `docker-container` builder. Since buildx v0.30.0 that driver writes
the GitHub event payload into the container so provenance can record it —
[`driver/docker-container/driver.go`](https://github.com/docker/buildx/blob/364fbb16a1dfe785b58ae1b49d5ff4af7b2aae55/driver/docker-container/driver.go),
`d.Files["provenance.d/github_actions_context.json"]`, filled by
[`util/ghutil/ghutil.go`](https://github.com/docker/buildx/blob/364fbb16a1dfe785b58ae1b49d5ff4af7b2aae55/util/ghutil/ghutil.go)
which reads `GITHUB_EVENT_PATH` whole:

```go
m["github_event_payload"] = evt
```

It is read at builder **create** time, not at build time — which is why a local
reproduction that exports `GITHUB_EVENT_PATH` only for the build produces
nothing.

**2. `provenance: false` does not stop it.** That flag drops the attestation
attached to the *image*. buildx still resolves provenance for `--metadata-file`,
and the default mode `min` strips `BuildConfig` and `Metadata` only —
[`util/confutil/metadata.go`](https://github.com/docker/buildx/blob/364fbb16a1dfe785b58ae1b49d5ff4af7b2aae55/util/confutil/metadata.go) —
so `invocation.environment.github_event_payload` survives. `build2.log` here is
a build run with `--provenance=false` and it still prints:

```
#5 resolving provenance for metadata file
#5 DONE 0.0s
```

**3. The action prints the file.** `docker/build-push-action`
[`src/main.ts`](https://github.com/docker/build-push-action/blob/2ca78c6bec76527009825f31aae0532b4d40d820/src/main.ts):
`core.info(JSON.stringify(metadata, null, 2))`. A JSON string value is one
physical line, so the whole commit message — `\n` escapes and all — arrives as
one line of log.

**4. The runner reads `##[` from anywhere in a line.** `ActionCommand.TryParseV2`
handles the modern `::command::` form and requires it at the start:

```csharp
// the message needs to start with the keyword after trim leading space.
message = message.TrimStart();
if (!message.StartsWith(_commandKey))
{
    return false;
}
```

`ActionCommand.TryParse` handles the legacy `##[command]` form and does not:

```csharp
// Get the index of the prefix.
int prefixIndex = message.IndexOf(Prefix);
if (prefixIndex < 0)
{
    return false;
}
…
command.Data = Unescape(message.Substring(rbIndex + 1));
```

— [`src/Runner.Worker/ActionCommand.cs`](https://github.com/actions/runner/blob/602c0085328df8cb595fc2641d69f640a11377a4/src/Runner.Worker/ActionCommand.cs).
`ActionCommandManager.TryProcessCommand` tries V2 first and falls through to V1:

```csharp
if (!ActionCommand.TryParseV2(input, _registeredCommands, out actionCommand) &&
    !ActionCommand.TryParse(input, _registeredCommands, out actionCommand))
```

— [`src/Runner.Worker/ActionCommandManager.cs`](https://github.com/actions/runner/blob/602c0085328df8cb595fc2641d69f640a11377a4/src/Runner.Worker/ActionCommandManager.cs).
The registered names come from the command extensions (`set-env`, `set-output`,
`save-state`, `add-mask`, `add-path`, `add-matcher`, `remove-matcher`, `debug`,
`warning`, `error`, `notice`, `group`, `endgroup`, `echo`) plus `stop-commands`,
added directly in the manager's constructor; `internal-set-repo-path` is
registered only for the duration of the checkout action.

So `error` is not the only exposure: `##[stop-commands]` is registered too, and
a line the runner accepts can switch command processing off for the rest of the
step.

## Artefacts

Recorded locally against buildx v0.34.1, driver `docker-container`, with
`GITHUB_ACTIONS=true GITHUB_EVENT_NAME=push GITHUB_EVENT_PATH=event.json` set
when the builder was created.

| File | What it is |
| --- | --- |
| `Dockerfile`, `hello.txt` | the two-line build context; the image is irrelevant, the metadata file is the subject |
| `event.json` | the push event, reduced to the one commit whose body quotes `##[error]` |
| `build1.log`, `md-default.json`, `printed-default.txt` | builder created **without** the GitHub env: provenance present, payload absent. This is the first attempt, and it is kept because it is the trap — a local reproduction that exports `GITHUB_EVENT_PATH` only for the build looks like the defect does not exist |
| `build2.log`, `md-gha.json`, `printed-gha.txt` | the reproduction. Same `--provenance=false` build, builder recreated **with** `GITHUB_ACTIONS`/`GITHUB_EVENT_NAME`/`GITHUB_EVENT_PATH`. `printed-gha.txt:31` is the injected line |
| `build3.log`, `md-disabled.json` | `BUILDX_METADATA_PROVENANCE=disabled`: the build log has no `resolving provenance for metadata file` step at all, and the metadata file is `{"buildx.build.ref": …}` and nothing else |
| `build4.log`, `md-nogha.json` | `--driver-opt provenance-add-gha=false` on a second builder: provenance still resolved and written, `github_event_payload` gone (buildx ≥ v0.30.0 only) |

## The fix, and why this one

`BUILDX_METADATA_PROVENANCE: disabled` at workflow scope in every workflow that
builds. buildx then writes no provenance to the metadata file, so there is
nothing to print and nothing to misread.

`min` — the default — is not enough: it is exactly the mode that produced the
annotations. `--driver-opt provenance-add-gha=false` also works and keeps the
provenance, but an unrecognised driver option is a hard error on buildx before
v0.30.0, and this repository publishes no provenance anyway (`provenance: false`
on every build step), so there is nothing to keep.

`provenance: false` stays. The two settings govern different things — the
attestation on the published image, and the contents of the metadata file — and
dropping the first would put `unknown/unknown` platforms back into every
published index, which is issue #119 arriving through a different door.

## Reported upstream

Each link of the chain is a separate defect and each was filed with this
reproduction attached:

- [docker/buildx#4066](https://github.com/docker/buildx/issues/4066) — the payload in the metadata file, and `--provenance=false` not covering it
- [docker/build-push-action#1612](https://github.com/docker/build-push-action/issues/1612) — printing that file to the log unescaped
- [actions/runner#4692](https://github.com/actions/runner/issues/4692) — `##[` matched mid-line while `::` is anchored

Bodies as filed: `../../upstream/`.

Held in place by `experiments/test-issue121-log-injection.sh` (offline) and
`experiments/test-issue121-provenance-metadata-leak.sh` (needs Docker).
