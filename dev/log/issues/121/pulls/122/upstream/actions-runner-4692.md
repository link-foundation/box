### Describe the bug

The legacy workflow-command parser matches `##[` **anywhere** in a line, while the modern parser requires `::` at the start of the line. Any step that prints text it did not author — a commit message, a PR body, a JSON blob from a tool — can therefore raise annotations, including `failure` annotations on a job that succeeded.

`ActionCommand.TryParseV2` (modern `::command::`) anchors:

```csharp
// the message needs to start with the keyword after trim leading space.
message = message.TrimStart();
if (!message.StartsWith(_commandKey))
{
    return false;
}
```

`ActionCommand.TryParse` (legacy `##[command]`) does not:

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

— [`src/Runner.Common/ActionCommand.cs`](https://github.com/actions/runner/blob/main/src/Runner.Common/ActionCommand.cs)

and `ActionCommandManager.TryProcessCommand` falls through from one to the other, so the weaker rule is always available:

```csharp
if (!ActionCommand.TryParseV2(input, _registeredCommands, out actionCommand) &&
    !ActionCommand.TryParse(input, _registeredCommands, out actionCommand))
{
    return false;
}
```

— [`src/Runner.Worker/ActionCommandManager.cs#L69-L73`](https://github.com/actions/runner/blob/main/src/Runner.Worker/ActionCommandManager.cs#L69-L73)

The registered set is every command extension (`set-env`, `set-output`, `save-state`, `add-mask`, `add-path`, `add-matcher`, `remove-matcher`, `debug`, `warning`, `error`, `notice`, `group`, `endgroup`, `echo`) plus `stop-commands`.

I don't think this is only a display problem, for two reasons.

**`stop-commands` is in that set.** A line containing `##[stop-commands]sometoken` mid-line pauses command processing for the rest of the step, so every real annotation and every `set-output`/`add-mask` after it is silently ignored. `ValidateStopToken` rejects an empty token and `pause-logging`, but it accepts an arbitrary non-empty one — and the rejection path is `throw`, not "ignore the line", which I read as failing the step outright. I have not run that variant, so treat the `throw` half as a code reading rather than a measurement; the annotation half below is measured.

**`OutputManager` already does this defensively for two other markers**, which suggests the exposure is recognised — the same protection just isn't applied to the registered command set:

```csharp
// Strip runner-controlled markers from user output to prevent injection
if (!String.IsNullOrEmpty(line) &&
    (line.Contains("##[start-action") || line.Contains("##[end-action")))
{
    line = line.Replace("##[start-action", @"##[\start-action")
               .Replace("##[end-action", @"##[\end-action");
}
```

— [`src/Runner.Worker/Handlers/OutputManager.cs#L93-L99`](https://github.com/actions/runner/blob/main/src/Runner.Worker/Handlers/OutputManager.cs#L93-L99)

Escaping does not help the author of the printing step either. `JSON.stringify` renders newlines as `\n` escapes, so a whole multi-line document arrives as one physical line with `##[error]` in the middle — precisely the shape `TryParse` accepts and `TryParseV2` would refuse.

### What happened to us

A release run ([link-foundation/box run 34293699247](https://github.com/link-foundation/box/actions/runs/34293699247)) finished with **every job green** and **56 annotations at level `failure`** attached to those same green jobs, path `.github`, at line numbers that correspond to nothing. Their text was the body of one of our own commits, which quoted a runner message while explaining a fix for jobs that had genuinely been killed earlier:

```
##[error]Process completed with exit code 143.
```

The route: `docker/setup-buildx-action` creates a `docker-container` builder, buildx ≥ v0.30.0 bakes `GITHUB_EVENT_PATH` into it and writes it into `--metadata-file` under the default provenance mode, and `docker/build-push-action` prints that file with `core.info`. So the push event's commit messages became job log lines, and this parser turned them into failure annotations. (Filed on those two as [docker/buildx#4066](https://github.com/docker/buildx/issues/4066) and [docker/build-push-action#1612](https://github.com/docker/build-push-action/issues/1612).) That path is incidental, though — any step that prints third-party text is exposed, and on a public repository "third-party text" includes the PR title and body of whoever opened the pull request.

We spent real time treating a green release as broken because the annotations claimed 56 failures.

### Reproduction

No Docker, no third-party actions:

```yaml
name: repro
on: workflow_dispatch
jobs:
  repro:
    runs-on: ubuntu-24.04
    steps:
      - name: legacy prefix is honoured mid-line
        run: echo 'some tool output that mentions ##[error]this is not a real error'
      - name: modern prefix is not
        run: echo 'some tool output that mentions ::error::this is not a real error'
```

Step 1 succeeds and produces a `failure` annotation reading `this is not a real error`. Step 2 succeeds and produces nothing — which is the behaviour I'd expect from both.

Single-line variant of the real case, showing the `\n`-escaped form:

```yaml
      - run: node -e 'console.log(JSON.stringify({m: "title\n##[error]boom"}, null, 2))'
```

### Expected behaviour

`##[command]` should be recognised only at the start of a line, as `::command::` already is. A line that merely *mentions* a command should be log text.

### Workarounds available today

None that a workflow author can apply generally. `ACTIONS_ALLOW_UNSECURE_COMMANDS` governs `set-env`/`add-path`, not parsing position. Wrapping every print of foreign text in `stop-commands` works but requires knowing in advance which steps print foreign text — and `docker/build-push-action`, `actions/github-script` and anything echoing `${{ github.event.* }}` all qualify. Our own fix had to go one layer up: stop buildx putting the payload in the file at all (`BUILDX_METADATA_PROVENANCE: disabled`).

### Suggested fix

Anchor `TryParse` the same way `TryParseV2` is anchored:

```diff
--- a/src/Runner.Common/ActionCommand.cs
+++ b/src/Runner.Common/ActionCommand.cs
@@ public static bool TryParse(string message, HashSet<string> registeredCommands, out ActionCommand command)
             try
             {
-                // Get the index of the prefix.
-                int prefixIndex = message.IndexOf(Prefix);
-                if (prefixIndex < 0)
+                // The message needs to start with the prefix after trimming leading
+                // whitespace, matching TryParseV2. Accepting the prefix anywhere in
+                // the line lets any step that prints text it did not author raise
+                // annotations and stop command processing.
+                message = message.TrimStart();
+                int prefixIndex = message.StartsWith(Prefix, StringComparison.Ordinal) ? 0 : -1;
+                if (prefixIndex < 0)
                 {
                     return false;
                 }
```

The rest of the method already works from `prefixIndex`, so nothing else moves.

On compatibility: I could not construct a case where a *deliberate* legacy command is emitted mid-line — the documented form has always been one command per line, and every first-party action emits at line start. If that's judged too sharp a change, the same relief comes from either of:

- gating the mid-line fallback behind an opt-in variable (`ACTIONS_ALLOW_UNSECURE_COMMANDS`-style), defaulting to anchored; or
- keeping the parse but refusing `stop-commands` and the annotation commands (`error`, `warning`, `notice`) unless anchored, which removes the two consequences that matter while leaving the rest untouched.

Failing all of that: the asymmetry is worth documenting. The workflow-commands docs describe `##[…]` as the deprecated spelling of the same thing, and nothing says one is positional and the other is not.

I'm happy to open a PR for whichever shape you'd prefer.

### Runner version

Observed on GitHub-hosted `ubuntu-24.04` and `ubuntu-24.04-arm`, `Current runner version: '2.337.0'` (image `ubuntu24/20260831.293`). Code quoted from `main` as of 2026-09-09.
