### Contributing guidelines

- [X] I've read the contributing guidelines and wholeheartedly agree

### I've found a bug and checked that ...

- [X] ... the documentation does not mention anything about my problem
- [X] ... there are no open or closed issues that are related to my problem

### Description

Since v0.30.0 the `docker-container` driver copies the entire GitHub Actions **event payload** into every builder it creates, and the default metadata-provenance mode (`min`) then writes that payload into `--metadata-file`. Anything an untrusted contributor can put into a commit message, PR title or PR body ends up verbatim in the build's metadata file — and, for anyone using `docker/build-push-action`, verbatim in the job log, where the Actions runner parses it.

`driver/docker-container/driver.go` (builder **create** time):

```go
if d.writeProvenanceGHA {
    if ghactx, err := ghutil.GithubActionsContext(); err != nil {
        return err
    } else if ghactx != nil {
        …
        d.Files["provenance.d/github_actions_context.json"] = ghactx
    }
}
```

`util/ghutil/ghutil.go` reads `GITHUB_EVENT_PATH` whole and stores it unfiltered:

```go
dt, err := os.ReadFile(githubEventPath)
…
m["github_event_payload"] = evt
```

Two things follow that I think are worth separating:

**1. `--provenance=false` does not stop it.** That flag drops the attestation attached to the *image*; buildx still runs `resolving provenance for metadata file` and still writes `buildx.build.provenance` to `--metadata-file`. `MetadataProvenanceModeMin` — the default in `util/confutil/metadata.go` — strips `BuildConfig` and `Metadata` only, so `invocation.environment.github_event_payload` survives in the mode nobody opted into. A user who has explicitly said "no provenance" still gets the payload.

**2. The payload is unbounded, attacker-influenced input.** `github_event_payload` is the raw webhook body. On a `pull_request` event it contains the PR title and body; on `push` it contains every commit message in the push. On a public repository those are supplied by whoever opened the PR.

### What went wrong for us

A release run of ours ([link-foundation/box run 34293699247](https://github.com/link-foundation/box/actions/runs/34293699247)) finished with every job green and **56 annotations at level `failure`**, pointing at `.github` and at line numbers that correspond to nothing. The annotation text was the body of one of our own commits, which happened to quote a runner message while explaining a fix:

```
##[error]Process completed with exit code 143.
```

The chain: buildx baked the push payload into the builder → wrote it to the metadata file under `min` → `docker/build-push-action` prints the metadata file with `core.info(JSON.stringify(metadata, null, 2))` → the runner's legacy command parser (`ActionCommand.TryParse`) looks for `##[` **anywhere** in a line, not just at the start, and turned each occurrence into a failure annotation on a successful job.

This is not only cosmetic. `##[stop-commands]` is a registered command too, so a line that reaches the log this way can switch off command processing for the rest of the step. The runner side is being reported separately; I am raising it here because buildx is the component that puts untrusted third-party text into that log in the first place, and does so for users who asked for no provenance.

### Reproduction

The event payload is read at builder **create** time, not build time — a reproduction that exports `GITHUB_EVENT_PATH` only for the build shows nothing, which is the trap. Full artefacts: <https://github.com/link-foundation/box/tree/main/dev/log/issues/121/pulls/122/probes/provenance-injection>

```console
$ cat event.json
{"after":"deadbeef","commits":[{"id":"a2e6420","message":"ci: spend the idle disk (issue #119)\n\n##[error]Process completed with exit code 143.\n  ##[error]The runner has received a shutdown signal.\n\nrest of the body"}],"repository":{"full_name":"link-foundation/box"}}

$ printf 'FROM scratch\nCOPY hello.txt /hello.txt\n' > Dockerfile && echo hi > hello.txt

$ GITHUB_ACTIONS=true GITHUB_EVENT_NAME=push GITHUB_EVENT_PATH="$PWD/event.json" \
    docker buildx create --name provrepro --driver docker-container --bootstrap

$ docker buildx build --builder provrepro --provenance=false \
    --metadata-file md-gha.json .

$ jq . md-gha.json
```

```json
{
  "buildx.build.provenance": {
    "buildType": "https://mobyproject.org/buildkit@v1",
    "invocation": {
      "environment": {
        "dockerfileVersion": "1.26.0",
        "github_event_name": "push",
        "github_event_payload": {
          "after": "deadbeef",
          "commits": [
            {
              "id": "a2e6420",
              "message": "ci: spend the idle disk (issue #119)\n\n##[error]Process completed with exit code 143.\n  ##[error]The runner has received a shutdown signal.\n\nrest of the body"
            }
          ],
          "repository": { "full_name": "link-foundation/box" }
        },
        "platform": "linux/amd64"
      }
    }
  },
  "buildx.build.ref": "provrepro/provrepro0/06gawqty97i5gmz6onef8xju9"
}
```

Note `--provenance=false` in that command line. The build log still shows:

```
#5 resolving provenance for metadata file
#5 DONE 0.0s
```

Recreating the builder without the GitHub env vars produces the same provenance **without** `github_event_payload`, which confirms the create-time capture.

### Workarounds

Both verified in the artefacts above.

```yaml
env:
  BUILDX_METADATA_PROVENANCE: disabled   # no provenance in the metadata file at all
```

`build3.log` shows the `resolving provenance for metadata file` step disappears entirely and the file reduces to `{"buildx.build.ref": …}`.

Or, keeping the provenance and dropping only the GitHub context:

```yaml
- uses: docker/setup-buildx-action@v3
  with:
    driver-opts: provenance-add-gha=false
```

`md-nogha.json` shows provenance still resolved and written, `github_event_payload` gone. Caveat: an unrecognised `--driver-opt` is a hard error on buildx before v0.30.0, so this pins the workflow to a buildx floor.

We went with `BUILDX_METADATA_PROVENANCE: disabled` ([link-foundation/box#122](https://github.com/link-foundation/box/pull/122)).

### Suggested fixes

Roughly in order of how much I'd argue for them:

1. **Honour `--provenance=false` for the metadata file.** If the user disabled provenance for the build, resolving and writing provenance for `--metadata-file` is surprising. At minimum this deserves a line in the docs; better, `--provenance=false` should imply `BUILDX_METADATA_PROVENANCE=disabled` unless the env var is set explicitly.

2. **Don't put `github_event_payload` in `min`.** `min` reads as "the small, safe subset". The full webhook body is neither small nor attacker-free. Moving `github_event_payload` (and arguably the whole `github_actions_context`) behind `max` would fix the default without removing the capability:

   ```diff
   --- a/build/provenance.go
   +++ b/build/provenance.go
   @@ func encodeProvenance(dt []byte, predicateType string, mode confutil.MetadataProvenanceMode) (string, error) {
        if mode == confutil.MetadataProvenanceModeMin {
   +        // The GitHub event payload is unbounded, third-party-controlled text
   +        // (commit messages, PR titles and bodies). Keep it out of the mode
   +        // users get without asking.
   +        delete(prv.Invocation.Environment, "github_event_payload")
            prv.Metadata = nil
            prv.BuildConfig = nil
        }
   ```

   (Sketch — the field is a `map[string]any` inside the SLSA struct, so the exact spelling depends on which predicate version is in hand.)

3. **Select the payload fields instead of storing the blob.** `ghutil.GithubActionsContext` is careful and explicit about every other GitHub variable it records — it enumerates them and checks each one. `github_event_payload` is the one place it takes an entire file it does not control. Recording `evt["after"]`, `evt["ref"]`, `evt["repository"]["full_name"]`, `evt["pull_request"]["number"]` etc. would preserve what the field is for (reproducibility: which event produced this build) without carrying free-form text.

### Version

```console
$ docker buildx version
github.com/docker/buildx v0.34.1
```

Introduced by 7652057d ("docker-container: write github actions payload to container for provenance", 2025-10-06); `util/ghutil/ghutil.go` is absent at `v0.29.0` and present at `v0.30.0`.
