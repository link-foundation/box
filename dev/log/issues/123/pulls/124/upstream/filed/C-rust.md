Text a pull request wrote is printed to the CI log unbracketed, so a changeset quoting `##[error]` annotates the run — and can also switch off command processing or mask arbitrary text

### Summary

The release scripts print contributor-authored text — a changeset description, a changelog fragment, a merged changeset body — straight to stdout. The runner reads every printed line for workflow commands, and its legacy parser accepts `##[` **anywhere** in a physical line. So a changeset body that mentions `##[error]` becomes an error annotation on a run in which nothing failed.

Annotations are the mild case. `stop-commands` and `add-mask` are in the same registered command set, so the same text can switch command processing off for the rest of the step, or replace an arbitrary substring of every later line with `***`.

Nothing in this repository emits a `::stop-commands::` bracket: `grep -r stop-commands` matches **0 files** in the tree.

### The mechanism

From the runner's own source (actions/runner):

- `src/Runner.Common/ActionCommand.cs` — `TryParse` locates the prefix with `message.IndexOf("##[")`, so the legacy form is a command *anywhere* in a line. `TryParseV2` requires the line to start with `::`; `ActionCommandManager.cs:70-71` tries both, V2 first, legacy second.
- `ActionCommandManager.cs:34` — the registered set includes `stop-commands` and `add-mask` alongside `error`, `warning` and `notice`.

That is a runner behaviour, not a bug in this template, and it is reported as [actions/runner#4692](https://github.com/actions/runner/issues/4692). But it is the reason a script may not print untrusted text bare, and every affected repository has to bracket its own prints.

### The printers here

- `scripts/create-changelog-fragment.rs:118` — `println!("{}", fragment_content)`, run by `release.yml:1167` in the manual-release job.

**This is the weaker variant of the defect.** In this template nothing prints a *pull-request-authored* file: `scripts/collect-changelog.rs` prints fragment names (`Removed {}`, `Updated CHANGELOG.md with version {}`) and not fragment bodies. What is printed verbatim is the fragment built from the `description` an operator types into `workflow_dispatch`, so reaching it needs write access. It is still a repository that cannot print its own release annotations reliably, and the fix is the same three lines.

Worth saying explicitly, because it is the reason this is filed at all: the `env:`-then-`"$DESCRIPTION"` form at `release.yml:1165-1167` is *correct*, and is what the other templates need to adopt. This report is only about the print.

### Reproduction

No CI and no network: the fixture puts `##[error]…` where a contributor's text goes, and runs this template's own scripts against it. `experiments/issue-123/repro-log-injection-changeset.sh` (attached below):

```bash
rust-script scripts/create-changelog-fragment.rs \
  --bump-type patch --description '##[error]Injected by a changeset body'
```

Measured against `rust` at `f63a061fb3e23e647de0455886528a121b997678`:

```
### rust template: scripts/create-changelog-fragment.rs (release.yml:1167 runs it in the manual-release job)
  exit=0
  REPRODUCED: rust create-changelog-fragment.rs printed the payload verbatim
  unguarded: rust create-changelog-fragment.rs emitted no stop-commands token, so the payload is a live log command
    10:- ##[error]Injected by a changeset body
```

Each line marked `REPRODUCED` is a physical log line containing `##[error]…`. Feed that same line to a runner and it is an error annotation; the fixture stops one step short of a live run on purpose, because the runner half is already established by [actions/runner#4692](https://github.com/actions/runner/issues/4692) and by the production evidence below.

### What it looks like in production

Two runs in `link-foundation/box`, both green, both annotated by text a contributor wrote:

- run [34293699247](https://github.com/link-foundation/box/actions/runs/34293699247) — **56 `failure` annotations** on a release where every job succeeded. A commit message quoting `##[error]` while explaining a fix reached the log through `docker/build-push-action`'s metadata print, one physical line at a time.
- run [34366976358](https://github.com/link-foundation/box/actions/runs/34366976358), job `Apply Changesets` — concluded `success`, carried a `failure` annotation. The step ran `git commit -m "$NEW_VERSION: $DESCRIPTIONS"`, where `$DESCRIPTIONS` is the body of the changesets a pull request added, and git echoes the new commit's subject line. The whole annotation — level, title, body — came out of a changeset.

The second one is the shape this template has: the untrusted text is a changeset body, and something prints it.

### Workaround

For a repository that cannot change the scripts yet, wrap the *step* rather than the print. `::stop-commands::<token>` makes every line up to the matching `::<token>::` verbatim:

```yaml
- name: Validate changeset
  run: |
    token="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    echo "::stop-commands::${token}"
    status=0
    node scripts/validate-changeset.mjs || status=$?
    echo "::${token}::"
    exit "$status"
```

Two details decide whether this actually holds:

- **The token has to be unpredictable.** While processing is stopped the resume token is itself added to the registered set and matched by the same lenient rule, so text that can guess the token can resume command processing and inject anyway. 128 bits, fresh per call.
- **The token must be a legal stop token**: non-empty, not a registered command name, and not `pause-logging` — `ActionCommandManager.ValidateStopToken` throws otherwise, which fails the step. Hex digits satisfy all three.

The cost is that the script's *own* `::error::` and `::warning::` lines stop being commands for the duration, which is why the fix below brackets the print instead of the step.

### Suggested fix

Bracket the untrusted print, not the whole step:

```rust
use std::fs::File;
use std::io::Read;

/// Print text this repository did not write, with workflow commands off.
///
/// The resume token is added to the runner's registered command set while
/// processing is stopped and is matched by the same lenient `##[<token>]` rule,
/// so a guessable token can be resumed by the very text it is bracketing.
fn print_untrusted(text: &str) {
    if env::var_os("GITHUB_ACTIONS").is_none() {
        println!("{}", text);
        return;
    }
    let token = stop_token();
    println!("::stop-commands::{}", token);
    println!("{}", text);
    println!("::{}::", token);
}

fn stop_token() -> String {
    let mut bytes = [0u8; 16];
    if let Ok(mut file) = File::open("/dev/urandom") {
        if file.read_exact(&mut bytes).is_ok() {
            return bytes.iter().map(|b| format!("{:02x}", b)).collect();
        }
    }
    // No readable /dev/urandom: say so in the token rather than silently
    // shipping a predictable one.
    format!("fallback{}{}", process::id(), Utc::now().timestamp_nanos_opt().unwrap_or(0))
}
```

and the site becomes:

```diff
     println!("Content:");
-    println!("{}", fragment_content);
+    print_untrusted(&fragment_content);
```

Rewriting the text — stripping `##[`, say — is the tempting alternative and it is worse: the log then disagrees with the changeset, and it has to be done to every stream of every command that might echo contributor text, including `git commit`'s own subject-line echo.

We ship this as [`scripts/ci/run-with-commands-stopped.sh`](https://github.com/link-foundation/box/blob/main/scripts/ci/run-with-commands-stopped.sh), usable as a command (`bash scripts/ci/run-with-commands-stopped.sh git commit -m "$MESSAGE"`) or sourced for callers that cannot express the untrusted part as one command. Three properties of the runner's implementation shaped it, and are worth knowing before writing your own:

- **Prefer the command form to the bracket form.** An `exit` or a `set -e` abort between a stop and its resume leaves the rest of that step unable to annotate at all. The wrapper always resumes, including when the command fails or dies on a signal.
- **The state is per step, and shared between the streams.** A step's handler creates its own command manager (`Handler.cs:172`) and gives stdout and stderr `OutputManager`s that share it (`ScriptHandler.cs:331-336`), so a token left unresumed cannot leak into a later step, and markers written to one stream do govern the other.
- **Ordering between the two streams is not guaranteed.** A caller whose untrusted text goes to stderr should send the markers there too.

### Relation to earlier work

Found while auditing every CI/CD false positive and false negative in `link-foundation/box` ([box#123](https://github.com/link-foundation/box/issues/123)), which compares this template's full workflow and script tree against ours; the runner-side half was reported during its predecessor, [box#121](https://github.com/link-foundation/box/issues/121), as [actions/runner#4692](https://github.com/actions/runner/issues/4692) with [docker/buildx#4066](https://github.com/docker/buildx/issues/4066) and [docker/build-push-action#1612](https://github.com/docker/build-push-action/issues/1612) for the path that carried it there.

The same defect is present in the js, python, rust, csharp, go and java templates — ten printers measured across the six, all of them unbracketed — and is reported in each. The php template is clean: `validate-changeset.php:42` and `create-github-release.php:48`/`:59` print fixed strings.
