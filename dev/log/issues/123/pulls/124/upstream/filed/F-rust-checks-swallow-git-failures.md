Two PR checks read a failed `git diff` as "nothing changed" and exit 0, so a missing base ref turns both into a pass — and one of them says nothing at all

### Summary

`scripts/check-changelog-fragment.rs` and `scripts/check-version-modification.rs` both obtain the pull request's diff through a helper that returns an **empty string** when git fails, and both read an empty diff as a clean pull request.

`check-changelog-fragment.rs:28-45`:

```rust
fn exec(command: &str, args: &[&str]) -> String {
    match Command::new(command).args(args).output() {
        Ok(output) => {
            if output.status.success() {
                String::from_utf8_lossy(&output.stdout).trim().to_string()
            } else {
                eprintln!("Error executing {} {:?}", command, args);
                eprintln!("{}", String::from_utf8_lossy(&output.stderr));
                String::new()          // <- indistinguishable from "no output"
            }
        }
        Err(e) => { eprintln!("Failed to execute {} {:?}: {}", command, args, e); String::new() }
    }
}
```

`:64-78` calls it for the one question the check depends on, and `:110-113` turns the empty answer into a pass:

```rust
let output = exec("git", &["diff", "--name-only", &format!("origin/{}...HEAD", base_ref)]);
if output.is_empty() { return Vec::new(); }
...
if changed_files.is_empty() { println!("No changed files found"); exit(0); }
```

`git diff --name-only origin/<base>...HEAD` exits **128** — not 1, not empty output — when `origin/<base>` is not a resolvable ref. So a shallow or single-branch checkout, a renamed base branch, or no network produces `exit 0` from a check whose entire purpose is to require a changelog fragment.

`check-version-modification.rs` has the same shape and is **worse in two ways** (`:34-40`):

```rust
fn exec(command: &str, args: &[&str]) -> String {
    match Command::new(command).args(args).output() {
        Ok(output) => String::from_utf8_lossy(&output.stdout).trim().to_string(),
        Err(_) => String::new(),
    }
}
```

- `Ok(output)` is returned for **any process that ran**, whatever its exit status — `output.status` is never consulted — so a `fatal:` is captured into `output.stderr` and dropped on the floor. `Err(_)` only fires when the binary cannot be spawned at all.
- `:142-146` then reads that as the *success* message:

  ```rust
  if diff.is_empty() {
      println!("No changes to Cargo.toml detected.");
      println!("Version check passed.");
      exit(0);
  }
  ```

The result is a completely silent false negative: a pull request that hand-edits `version = "..."` in `Cargo.toml` — the single thing this script exists to reject — passes with no error text anywhere in the log.

### Root cause, stated as a rule

`String::new()` is being used for two different answers: "the command ran and found nothing" and "the command could not answer". Once those collapse into the same value, the caller's `is_empty()` check reads a failure as good news, and the direction of the mistake is fixed: always toward passing.

### How latent it is

Both jobs check out with `fetch-depth: 0`, which does create `refs/remotes/origin/*`, so the shipped workflow takes the working path today:

- `release.yml:173-176` — `changelog-check`
- `release.yml:195-207` — `version-check`

`check-version-modification.rs:102` also tries to guarantee the ref from inside the script, and it is worth knowing that this does not work:

```rust
exec_ignore_error("git", &["fetch", "origin", &base_ref, "--depth=1"]);
```

Measured in a shallow single-branch clone — `actions/checkout` sets `remote.origin.fetch` to `+refs/heads/<head>:refs/remotes/origin/<head>`, so that fetch writes `FETCH_HEAD` and creates **no** `refs/remotes/origin/<base>` at all. Adding an explicit refspec gets the ref but not a merge base (`fatal: origin/main...HEAD: no merge base`), and neither does dropping the depth limit, because what is shallow is the local branch. Only `--unshallow` or `fetch-depth: 0` answers the question. Four forms, four different reasons, all exit **128** — which is why the caller-side distinction below is the real fix and the fetch is only hygiene.

It bites any copy of the template that reduces the fetch depth — the obvious CI speed-up — and anyone running either script locally. It is worth fixing where it is latent anyway, because a check whose failure mode is "pass" gives no signal that it has stopped working: neither of these two would ever have told you.

### Reproduction

No CI and no network. `experiments/issue-123/repro-changeset-validation-fallback.sh` (attached below) builds a repository with a source change and no changelog fragment, then a hand-written version bump, and runs each script twice — once without `refs/remotes/origin/main` and once with it, which is the only difference between the two runs:

```bash
echo fixture > scripts/.injection-fixture.txt
git add -A && git commit -qm "the pull request"

GITHUB_BASE_REF=main rust-script scripts/check-changelog-fragment.rs        # 1: no origin/main
git update-ref refs/remotes/origin/main HEAD~1
GITHUB_BASE_REF=main rust-script scripts/check-changelog-fragment.rs        # 2: origin/main present

git update-ref -d refs/remotes/origin/main
sed -i 's/^version = ".*"/version = "9.9.9"/' Cargo.toml
git add -A && git commit -qm "bump the version by hand"

GITHUB_EVENT_NAME=pull_request GITHUB_BASE_REF=main \
  rust-script scripts/check-version-modification.rs                        # 3: no origin/main
git update-ref refs/remotes/origin/main HEAD~1
GITHUB_EVENT_NAME=pull_request GITHUB_BASE_REF=main \
  rust-script scripts/check-version-modification.rs                        # 4: origin/main present
```

Measured against `f63a061f`:

```
### rust: check-changelog-fragment.rs, same pull request shape
  -- with no origin/main ref (a shallow or single-branch checkout):
     Checking for changelog fragment in PR diff...
     Comparing against origin/main...HEAD
     Error executing git ["diff", "--name-only", "origin/main...HEAD"]
     fatal: ambiguous argument 'origin/main...HEAD': unknown revision or path not in the working tree.
     No changed files found
     exit=0
  -- with origin/main present, which is the only difference:
     Changed files:
       scripts/.injection-fixture.txt
     Source files changed: 1
     Changelog fragments added: 0
     ::error::No changelog fragment found in this PR. Please add a changelog entry in changelog.d/
     exit=1

### rust: check-version-modification.rs, the same swallow in a second script
  -- with no origin/main ref (a shallow or single-branch checkout):
     Checking for manual version modifications in Cargo.toml...
     No changes to Cargo.toml detected.
     Version check passed.
     exit=0
  -- with origin/main present, which is the only difference:
     Checking for manual version modifications in Cargo.toml...
     Error: Manual version change detected in Cargo.toml!
     Versions are managed automatically by the CI/CD pipeline.
     exit=1
```

Blank lines are elided. Read the second pair closely: between "Checking for manual version modifications" and "Version check passed" there is nothing — no `fatal:`, no warning — over a `Cargo.toml` whose version line the fixture had just rewritten by hand.

### Workaround

Guarantee the ref rather than the depth. Any job running either script needs `fetch-depth: 0`:

```yaml
- uses: actions/checkout@v6
  with:
    persist-credentials: false
    fetch-depth: 0
```

or, if the depth has to stay bounded at checkout time, an `--unshallow` fetch before the script runs. `--depth=1` is not enough and neither is an unlimited fetch of the base alone — both leave `origin/<base>...HEAD` without a merge base:

```yaml
- run: |
    # --unshallow is rejected outright on a complete repository
    # ("fatal: --unshallow on a complete repository does not make sense"),
    # so ask first.
    depth=()
    [ -f "$(git rev-parse --git-dir)/shallow" ] && depth=(--unshallow)
    git fetch --no-tags "${depth[@]}" origin \
      "+refs/heads/$GITHUB_BASE_REF:refs/remotes/origin/$GITHUB_BASE_REF"
```

That keeps the working path alive; it does not make the failure visible, which is the fix below.

### Suggested fix

**1. Let the helper say it failed.** `Option<String>` (or `Result`) distinguishes the two answers that `String::new()` currently merges, and the compiler then finds every caller that has to decide:

```diff
-fn exec(command: &str, args: &[&str]) -> String {
+fn exec(command: &str, args: &[&str]) -> Option<String> {
     match Command::new(command).args(args).output() {
-        Ok(output) => {
-            if output.status.success() {
-                String::from_utf8_lossy(&output.stdout).trim().to_string()
-            } else {
-                eprintln!("Error executing {} {:?}", command, args);
-                eprintln!("{}", String::from_utf8_lossy(&output.stderr));
-                String::new()
-            }
-        }
-        Err(e) => { eprintln!("Failed to execute {} {:?}: {}", command, args, e); String::new() }
+        Ok(output) if output.status.success() => {
+            Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
+        }
+        Ok(output) => {
+            eprintln!("::error::git {:?} exited {}", args, output.status);
+            eprintln!("{}", String::from_utf8_lossy(&output.stderr));
+            None
+        }
+        Err(e) => { eprintln!("::error::failed to execute {} {:?}: {}", command, args, e); None }
     }
 }
```

Note that `check-version-modification.rs`'s copy needs the `status.success()` arm added regardless of the return type — as written it cannot report a failed git command at all.

**2. Make the base ref resolvable, then fail loudly if it still is not.** A check that cannot determine the diff must not report a pass:

```diff
 fn get_changed_files() -> Vec<String> {
     let base_ref = env::var("GITHUB_BASE_REF").unwrap_or_else(|_| "main".to_string());
     eprintln!("Comparing against origin/{}...HEAD", base_ref);
+    // `git fetch origin <base> --depth=1` is not enough twice over: a
+    // single-branch clone has no refspec that would create the remote-tracking
+    // ref, and a depth-1 fetch into a shallow checkout leaves the two histories
+    // without a merge base. --unshallow with an explicit refspec is what works.
+    let refspec = format!("+refs/heads/{0}:refs/remotes/origin/{0}", base_ref);
+    let mut fetch = vec!["fetch", "--no-tags"];
+    // Rejected outright on a complete repository, so ask git first.
+    let git_dir = exec("git", &["rev-parse", "--git-dir"]).unwrap_or_default();
+    if !git_dir.is_empty() && Path::new(&git_dir).join("shallow").exists() {
+        fetch.push("--unshallow");
+    }
+    fetch.extend_from_slice(&["origin", &refspec]);
+    let _ = exec("git", &fetch);
 
-    let output = exec("git", &["diff", "--name-only", &format!("origin/{}...HEAD", base_ref)]);
+    let output = match exec("git", &["diff", "--name-only", &format!("origin/{}...HEAD", base_ref)]) {
+        Some(output) => output,
+        None => {
+            eprintln!("::error::Could not determine the pull request diff, so this check cannot run.");
+            exit(1);
+        }
+    };
```

and the same at `check-version-modification.rs`'s `get_cargo_toml_diff` call site, whose `if diff.is_empty()` should only be reached for a diff git actually produced.

**3. Or fall back in the safe direction, as the other templates do.** Where failing the run is too strict, the fallback has to do *more* work rather than none:

- `js/scripts/validate-changeset.mjs:120`, `go:113`, `csharp:120` — `getAllChangesets()` validates the whole changeset directory when the diff is unavailable.
- `php/scripts/validate-changeset.php:23-26` — passes `null` as the added count, which makes the validator count the directory.
- **This template already gets it right in a third script**: `detect-code-changes.rs:151-165` treats an empty diff as "list every file in `HEAD`" (`git ls-tree --name-only -r HEAD`), so a git failure there makes the pipeline run more checks, not fewer. That is the pattern the two scripts above need.

For `check-changelog-fragment.rs` the safe fallback is `changelog.d/*.md` — require a fragment, or count what is in the directory — rather than "no changed files, nothing to check".

### Relation to earlier work

Found while auditing every CI/CD false positive and false negative in `link-foundation/box` ([box#123](https://github.com/link-foundation/box/issues/123)), which compares this template's full workflow and script tree against ours, file by file.

We asked the same question of all seven templates. Five err in the safe direction — js, go, csharp, php and python as listed above, plus this template's own `detect-code-changes.rs`. The remaining recipient is `java`, whose `validate-changeset.mjs:23-41` reaches the same place by a different route: it *catches* the failure and falls back to `git diff --name-only HEAD`, which lists uncommitted changes and is therefore empty on every CI checkout. Reported there as a companion to this one, with the same fixture — the first two sections of its transcript are the java half.
