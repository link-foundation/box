### Contributing guidelines

- [X] I've read the contributing guidelines and wholeheartedly agree

### I've found a bug and checked that ...

- [X] ... the documentation does not mention anything about my problem
- [X] ... there are no open or closed issues that are related to my problem

### Description

The `Metadata` group prints the buildx metadata file to the job log at info level:

```ts
if (metadata) {
  await core.group(`Metadata`, async () => {
    const metadatadt = JSON.stringify(metadata, null, 2);
    core.info(metadatadt);
    core.setOutput('metadata', metadatadt);
  });
}
```

— [`src/main.ts#L137-L142`](https://github.com/docker/build-push-action/blob/master/src/main.ts#L137-L142)

Since buildx v0.30.0 that metadata file can contain the **entire GitHub event payload**. The `docker-container` driver writes `GITHUB_EVENT_PATH` into the builder at create time ([`util/ghutil/ghutil.go`](https://github.com/docker/buildx/blob/master/util/ghutil/ghutil.go): `m["github_event_payload"] = evt`) and the default metadata-provenance mode `min` keeps it under `buildx.build.provenance.invocation.environment.github_event_payload`. `--provenance=false` does not remove it — that flag only drops the image attestation. I've filed that half separately as docker/buildx#4066.

So `core.info` is handed unbounded, third-party-controlled text: commit messages on `push`, PR title and body on `pull_request`. And the runner parses workflow commands out of every line it is given.

### What actually happened

A release run of ours ([link-foundation/box run 34293699247](https://github.com/link-foundation/box/actions/runs/34293699247)) finished with every build job **green** and **56 annotations at level `failure`** attached to those same green jobs — path `.github`, line numbers pointing at nothing. The annotation text was the body of one of our own commits, which quoted a runner message while explaining a fix:

```
##[error]Process completed with exit code 143.
```

That commit body reached the log because it was in the push payload, in the provenance, in the metadata file, printed by this step. The runner's legacy command parser (`ActionCommand.TryParse`) searches for `##[` **anywhere** in a line rather than only at the start, so each occurrence became a failure annotation.

Escaping does not save it: `JSON.stringify` turns the newlines into `\n` escapes, so the whole multi-line commit body arrives as a single physical log line containing `##[error]` mid-line — exactly the shape the legacy parser accepts.

The severity is not limited to noisy annotations. `stop-commands` is a registered command as well, so a commit message or PR body containing the right text can silence command processing for the remainder of the step. On a public repository that input comes from whoever opened the pull request.

### Reproduction

Minimal, no buildx build needed — this reproduces the runner half in isolation:

```yaml
jobs:
  demo:
    runs-on: ubuntu-24.04
    steps:
      - run: |
          node -e 'console.log(JSON.stringify({m: "hello\n##[error]not a real error"}, null, 2))'
```

The job succeeds and carries a `failure` annotation reading `not a real error`.

End to end, with buildx: push a commit whose message body contains `##[error]something`, then run `docker/build-push-action` with a `docker-container` builder created by `docker/setup-buildx-action` in the same job. The `Metadata` group prints the commit message and the annotation appears on the successful job. Recorded artefacts (metadata files with and without the GitHub env, the printed output, the disabled-mode control): <https://github.com/link-foundation/box/tree/main/dev/log/issues/121/pulls/122/probes/provenance-injection>

### Workaround

Set the buildx env var at workflow or job scope, which stops buildx writing provenance to the metadata file at all:

```yaml
env:
  BUILDX_METADATA_PROVENANCE: disabled
```

This is what we shipped ([link-foundation/box#122](https://github.com/link-foundation/box/pull/122)). `docker/setup-buildx-action` with `driver-opts: provenance-add-gha=false` also works and keeps the rest of the provenance, but an unrecognised `--driver-opt` is a hard error on buildx before v0.30.0.

Neither is a fix for this repository's part: any metadata content that happens to contain `##[` or a leading `::` is still printed unescaped.

### Suggested fixes

The output (`core.setOutput('metadata', …)`) is the part consumers depend on and it is not affected — this is only about the human-readable print.

**Option A — wrap the print in `stop-commands` (smallest change, fixes it completely).** The runner stops parsing commands until the token is echoed back:

```ts
import {issueCommand} from '@actions/core/lib/command';
import * as crypto from 'crypto';

if (metadata) {
  await core.group(`Metadata`, async () => {
    const metadatadt = JSON.stringify(metadata, null, 2);
    const token = crypto.randomUUID();
    issueCommand('stop-commands', {}, token);
    core.info(metadatadt);
    issueCommand(token, {}, '');
    core.setOutput('metadata', metadatadt);
  });
}
```

**Option B — neutralise the two command prefixes before printing:**

```ts
const safe = metadatadt
  .replace(/##\[/g, '#\u200b#[')
  .replace(/^\s*::/gm, m => m.replace('::', ':\u200b:'));
core.info(safe);
```

Less invasive, but it mutates displayed content by inserting zero-width characters, and it has to track whatever prefixes the runner accepts.

**Option C — print only when `core.isDebug()`.** The metadata file is rarely read by a human in a green run, and `${{ steps.build.outputs.metadata }}` remains available. This also happens to cut a lot of log volume now that provenance is in there by default.

I'd suggest A: it is exactly what `stop-commands` exists for, and it is correct regardless of what buildx decides to put in the file.

### Same code in `docker/bake-action`

[`src/main.ts#L178-L179`](https://github.com/docker/bake-action/blob/master/src/main.ts#L178-L179) prints the metadata the same way and is exposed identically. Happy to open a separate issue there if you'd prefer.

### Version

`docker/build-push-action@v7`, `docker/setup-buildx-action@v3`, buildx v0.34.1, `ubuntu-24.04` and `ubuntu-24.04-arm` GitHub-hosted runners.
