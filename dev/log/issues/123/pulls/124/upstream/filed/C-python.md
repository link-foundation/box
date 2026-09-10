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

- `scripts/create_github_release.py:176` — `print(f"\nRelease notes:\n{release_notes}\n")`, run by `release.yml:684` and `release.yml:824`. `release_notes` is the section `extract_release_notes()` reads out of `CHANGELOG.md`, which is assembled from the changelog fragments pull requests write.

The exposure is the ordinary contribution path: a pull request adds a changelog fragment, the fragment becomes a section of `CHANGELOG.md`, and the release job prints that section as its release notes. The same text is then passed to `gh release create --notes`, so it is printed twice in the transcript below.

### Reproduction

No CI and no network: the fixture puts `##[error]…` where a contributor's text goes, and runs this template's own scripts against it. `experiments/issue-123/repro-log-injection-changeset.sh` (attached below):

```bash
cat > CHANGELOG.md <<'EOF'
# Changelog

## 9.9.9

- Fix the CI gate. Quoting `##[error]Injected by a changeset body` in a changelog fragment used to annotate the run.
EOF

python3 scripts/create_github_release.py --version 9.9.9 --repository owner/repo
```

Measured against `python` at `470e17605fc37b33fd7ea4e8aa8d16eaab1d9253`:

```
### python template: scripts/create_github_release.py (release.yml runs it in both release jobs)
  exit=0
  REPRODUCED: python create_github_release.py printed the payload verbatim
  unguarded: python create_github_release.py emitted no stop-commands token, so the payload is a live log command
    11:- Fix the CI gate. Quoting `##[error]Injected by a changeset body` in a changelog fragment used to annotate the run.
    15:Running: gh release create v9.9.9 --repo owner/repo --title my-package 9.9.9 --notes - Fix the CI gate. Quoting `##[error]Injected by a changeset body` in a changelog fragment used to annotate the run.
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

```python
import os
import secrets

def print_untrusted(text: str) -> None:
    """Print text this repository did not write, with workflow commands off.

    The resume token is added to the runner's registered command set while
    processing is stopped, and is matched by the same lenient `##[<token>]`
    rule, so text that can guess it can resume command processing and inject
    anyway: 128 bits, fresh per call. Hex also satisfies ValidateStopToken,
    which rejects an empty token, a registered command name and
    `pause-logging`.
    """
    if not os.environ.get("GITHUB_ACTIONS"):
        print(text, flush=True)
        return
    token = secrets.token_hex(16)
    print(f"::stop-commands::{token}", flush=True)
    print(text, flush=True)
    print(f"::{token}::", flush=True)
```

and the site becomes:

```diff
-    print(f"\nRelease notes:\n{release_notes}\n")
+    print("\nRelease notes:")
+    print_untrusted(release_notes)
```

`gh release create --notes` is a separate matter: it takes the text as an argument, so it is not a log-command question, but note that `subprocess` invocations should keep passing it as an argv element rather than through a shell.

Rewriting the text — stripping `##[`, say — is the tempting alternative and it is worse: the log then disagrees with the changeset, and it has to be done to every stream of every command that might echo contributor text, including `git commit`'s own subject-line echo.

We ship this as [`scripts/ci/run-with-commands-stopped.sh`](https://github.com/link-foundation/box/blob/main/scripts/ci/run-with-commands-stopped.sh), usable as a command (`bash scripts/ci/run-with-commands-stopped.sh git commit -m "$MESSAGE"`) or sourced for callers that cannot express the untrusted part as one command. Three properties of the runner's implementation shaped it, and are worth knowing before writing your own:

- **Prefer the command form to the bracket form.** An `exit` or a `set -e` abort between a stop and its resume leaves the rest of that step unable to annotate at all. The wrapper always resumes, including when the command fails or dies on a signal.
- **The state is per step, and shared between the streams.** A step's handler creates its own command manager (`Handler.cs:172`) and gives stdout and stderr `OutputManager`s that share it (`ScriptHandler.cs:331-336`), so a token left unresumed cannot leak into a later step, and markers written to one stream do govern the other.
- **Ordering between the two streams is not guaranteed.** A caller whose untrusted text goes to stderr should send the markers there too.

### Relation to earlier work

Found while auditing every CI/CD false positive and false negative in `link-foundation/box` ([box#123](https://github.com/link-foundation/box/issues/123)), which compares this template's full workflow and script tree against ours; the runner-side half was reported during its predecessor, [box#121](https://github.com/link-foundation/box/issues/121), as [actions/runner#4692](https://github.com/actions/runner/issues/4692) with [docker/buildx#4066](https://github.com/docker/buildx/issues/4066) and [docker/build-push-action#1612](https://github.com/docker/build-push-action/issues/1612) for the path that carried it there.

The same defect is present in the js, python, rust, csharp, go and java templates — ten printers measured across the six, all of them unbracketed — and is reported in each. The php template is clean: `validate-changeset.php:42` and `create-github-release.php:48`/`:59` print fixed strings.
