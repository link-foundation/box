
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

### The fixtures, so this is runnable without cloning `box`

<details>
<summary><code>experiments/issue-123/repro-changeset-validation-fallback.sh</code></summary>

```bash
#!/usr/bin/env bash
# Reproduce: a changeset/changelog check reports success when it could not
# determine what the pull request changed.
#
# Two templates, two shapes, one class:
#   java  validate-changeset.mjs falls back to `git diff --name-only HEAD`,
#         which lists *uncommitted* changes -- always none in CI.
#   rust  check-changelog-fragment.rs has no fallback: its exec() helper returns
#         an empty string when the command fails, and an empty changed-file list
#         is read as "No changed files found" -> exit 0.
#
# The java case in detail:
#
# scripts/validate-changeset.mjs:23-41 asks git which files the pull request
# changed, and falls back to the working tree when that fails:
#
#   const output = execSync(`git diff --name-only origin/${baseBranch}...HEAD`)
#   ... catch { return execSync('git diff --name-only HEAD') ... }
#
# When `origin/<base>` is not a resolvable ref the first command exits 128, so
# the fallback runs -- and the fallback asks a question that is always answered
# "nothing" in CI: `git diff --name-only HEAD` lists *uncommitted* changes, and
# a fresh checkout has none. So `getChangedFiles()` answers `[]`,
# `hasSourceChanges([])` is false, and main() prints
#   "No source code changes detected. Changeset not required."
# and exits 0 -- on a pull request that did change source and did carry a
# malformed changeset.
#
# Latent in the shipped workflow: release.yml's `changeset-check` job checks out
# with `fetch-depth: 0`, which does create `refs/remotes/origin/*`. It bites any
# copy of the template that reduces the fetch depth, and the fallback is dead
# code that reports success either way.
#
# The rust case in detail: scripts/check-changelog-fragment.rs:28-45 defines
#
#   fn exec(command, args) -> String { ... else { eprintln!("Error executing ...");
#                                                 String::new() } }
#
# and :64-78 calls it for `git diff --name-only origin/<base>...HEAD`, treating
# an empty result as "no files changed". main() at :110-113 then prints
# "No changed files found" and exits 0. So a git failure -- a missing
# `origin/<base>`, a shallow clone, no network -- is reported as a clean pull
# request, with the error text on stderr and the job green.
#
# Latent in both shipped workflows: java's `changeset-check` and rust's
# `changelog-check` (release.yml:173-176) check out with `fetch-depth: 0`, which
# does create `refs/remotes/origin/*`. Both bite any copy that reduces the fetch
# depth, and in both the degraded path can only report success.
#
# Usage:
#   bash experiments/issue-123/repro-changeset-validation-fallback.sh [JAVA_DIR] [RUST_DIR]
set -uo pipefail

template="${1:-/tmp/templates/java}"
rust_template="${2:-/tmp/templates/rust}"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

echo "### git's own answer when origin/<base> does not resolve"
(
  mkdir -p "${work}/plain" && cd "${work}/plain" || exit 1
  git init -q . && git config user.email ci@example.invalid && git config user.name CI
  echo base >file.txt && git add -A && git commit -qm baseline
  echo changed >>file.txt && git add -A && git commit -qm change
  echo "  git diff --name-only HEAD~1...HEAD -> $(git diff --name-only HEAD~1...HEAD | tr '\n' ' ')(exit $?)"
  out="$(git diff --name-only origin/main...HEAD 2>&1)"
  echo "  git diff --name-only origin/main...HEAD -> '${out}' (exit $?)"
)

echo
echo "### java: the validator itself, on a pull request with a broken changeset"
[ -d "${template}" ] || {
  echo "  ${template} is not a directory, skipped"
  exit 0
}
cp -r "${template}" "${work}/java"
(
  cd "${work}/java" || exit 1
  rm -rf .git
  find .changeset -maxdepth 1 -name '*.md' ! -name 'README.md' -delete 2>/dev/null
  git init -q . && git config user.email ci@example.invalid && git config user.name CI
  git add -A -f >/dev/null 2>&1 && git commit -qm baseline >/dev/null 2>&1
  git branch -qM main >/dev/null 2>&1
  # A changeset with no front matter at all: the validator's own error case.
  printf 'no front matter, no bump type, not a valid changeset\n' >.changeset/broken.md
  echo fixture >scripts/.injection-fixture.txt
  git add -A -f >/dev/null 2>&1 && git commit -qm "the pull request" >/dev/null 2>&1
)

echo "  -- with no origin/main ref (a shallow or single-branch checkout):"
(cd "${work}/java" && node scripts/validate-changeset.mjs) 2>&1 | sed 's/^/     /'
echo "     exit=${PIPESTATUS[0]}"

echo "  -- with origin/main present, which is the only difference:"
git -C "${work}/java" update-ref refs/remotes/origin/main HEAD~1
(cd "${work}/java" && node scripts/validate-changeset.mjs) 2>&1 | sed 's/^/     /'
echo "     exit=${PIPESTATUS[0]}"

echo
echo "### rust: check-changelog-fragment.rs, same pull request shape"
if [ ! -d "${rust_template}" ]; then
  echo "  ${rust_template} is not a directory, skipped"
elif ! command -v rust-script >/dev/null 2>&1; then
  echo "  rust-script is not installed, skipped"
else
  cp -r "${rust_template}" "${work}/rust"
  (
    cd "${work}/rust" || exit 1
    rm -rf .git
    find changelog.d -maxdepth 1 -name '*.md' ! -name 'README.md' -delete 2>/dev/null
    git init -q . && git config user.email ci@example.invalid && git config user.name CI
    git add -A -f >/dev/null 2>&1 && git commit -qm baseline >/dev/null 2>&1
    git branch -qM main >/dev/null 2>&1
    # A source change and NO changelog fragment: the checker's own failure case.
    echo fixture >scripts/.injection-fixture.txt
    git add -A -f >/dev/null 2>&1 && git commit -qm "the pull request" >/dev/null 2>&1
  )

  echo "  -- with no origin/main ref (a shallow or single-branch checkout):"
  (cd "${work}/rust" && GITHUB_BASE_REF=main rust-script scripts/check-changelog-fragment.rs) 2>&1 \
    | sed 's/^/     /'
  echo "     exit=${PIPESTATUS[0]}"

  echo "  -- with origin/main present, which is the only difference:"
  git -C "${work}/rust" update-ref refs/remotes/origin/main HEAD~1
  (cd "${work}/rust" && GITHUB_BASE_REF=main rust-script scripts/check-changelog-fragment.rs) 2>&1 \
    | sed 's/^/     /'
  echo "     exit=${PIPESTATUS[0]}"
fi

echo
echo "### rust: check-version-modification.rs, the same swallow in a second script"
if [ ! -d "${work}/rust" ]; then
  echo "  no rust fixture, skipped"
else
  # The fixture above already has origin/main; drop it to ask the failing question.
  git -C "${work}/rust" update-ref -d refs/remotes/origin/main
  # A manual version bump in Cargo.toml, which is exactly what this script exists
  # to reject.
  (
    cd "${work}/rust" || exit 1
    sed -i 's/^version = ".*"/version = "9.9.9"/' Cargo.toml
    git add -A -f >/dev/null 2>&1 && git commit -qm "bump the version by hand" >/dev/null 2>&1
  )
  echo "  -- with no origin/main ref (a shallow or single-branch checkout):"
  (cd "${work}/rust" && GITHUB_EVENT_NAME=pull_request GITHUB_BASE_REF=main \
    rust-script scripts/check-version-modification.rs) 2>&1 | sed 's/^/     /'
  echo "     exit=${PIPESTATUS[0]}"

  echo "  -- with origin/main present, which is the only difference:"
  git -C "${work}/rust" update-ref refs/remotes/origin/main HEAD~1
  (cd "${work}/rust" && GITHUB_EVENT_NAME=pull_request GITHUB_BASE_REF=main \
    rust-script scripts/check-version-modification.rs) 2>&1 | sed 's/^/     /'
  echo "     exit=${PIPESTATUS[0]}"
fi
```

</details>

The probe behind the `fetch before the diff` table: it builds a shallow single-branch clone and asks the same diff after each of the five fetch forms.

<details>
<summary><code>experiments/issue-123/probe-shallow-base-ref.sh</code></summary>

```bash
#!/usr/bin/env bash
# Probe: what it actually takes for `git diff origin/<base>...HEAD` to work in a
# shallow, single-branch checkout -- which is what `actions/checkout` produces
# with any `fetch-depth` other than 0.
#
# This exists because the obvious repair for the checks that swallow a failed
# diff (report F) is "fetch the base branch first", and the obvious fetch is
# `git fetch origin "$GITHUB_BASE_REF" --depth=1` -- which is what the rust
# template's check-version-modification.rs:102 already does. Two separate
# reasons it does not work:
#
#   case A  a single-branch clone's remote.origin.fetch refspec covers only the
#           checked-out branch, so `git fetch origin main` writes FETCH_HEAD and
#           creates no refs/remotes/origin/main at all -> exit 128, "unknown
#           revision".
#   case B  with an explicit refspec the ref does appear, but a depth-1 fetch
#           into a depth-1 checkout leaves the two histories with no common
#           ancestor -> exit 128 again, "no merge base".
#   case C  dropping the depth limit from that fetch is still not enough: what is
#           shallow is the *local* branch, and fetching the base branch in full
#           does not deepen HEAD -> "no merge base" again.
#
# So only `--unshallow` (case D) or `fetch-depth: 0` (case E) answers the
# question, and every failure above is the same exit 128 that a caller must stop
# reading as "no files changed".
#
# Usage: bash experiments/issue-123/probe-shallow-base-ref.sh
set -uo pipefail

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# A remote with a `main` and a `feature` that diverged from it.
git init -q --bare "${work}/remote.git"
(
  cd "${work}" || exit 1
  git clone -q "${work}/remote.git" seed 2>/dev/null
  cd seed || exit 1
  git config user.email ci@example.invalid
  git config user.name CI
  echo a >f.txt && git add -A && git commit -qm c1
  echo b >>f.txt && git add -A && git commit -qm c2
  git branch -M main && git push -q origin main
  git checkout -qb feature && echo d >other.txt && git add -A && git commit -qm feat
  git push -q origin feature
)

report() {
  local label="$1" dir="$2"
  local out status
  out="$(git -C "${dir}" diff --name-only origin/main...HEAD 2>&1)"
  status=$?
  echo "  origin/main present? $(git -C "${dir}" rev-parse --verify -q refs/remotes/origin/main >/dev/null && echo yes || echo no)"
  echo "  git diff --name-only origin/main...HEAD -> exit=${status}"
  echo "${out}" | head -1 | sed 's/^/    /'
  echo "  ${label}"
}

echo "### case A: git fetch origin main --depth=1, the fetch the scripts already do"
git clone -q --depth=1 --branch feature "file://${work}/remote.git" "${work}/A"
echo "  remote.origin.fetch = $(git -C "${work}/A" config --get remote.origin.fetch)"
echo "  shallow? $([ -f "${work}/A/.git/shallow" ] && echo yes || echo no)"
git -C "${work}/A" fetch origin main --depth=1 2>&1 | sed 's/^/  fetch: /'
report "the single-branch refspec means no remote-tracking ref was created" "${work}/A"

echo
echo "### case B: an explicit refspec, still --depth=1"
git clone -q --depth=1 --branch feature "file://${work}/remote.git" "${work}/B"
git -C "${work}/B" fetch --depth=1 origin '+refs/heads/main:refs/remotes/origin/main' 2>&1 | sed 's/^/  fetch: /'
report "the ref exists and the histories still share no commit" "${work}/B"

echo
echo "### case C: an explicit refspec with no depth limit on the fetch"
git clone -q --depth=1 --branch feature "file://${work}/remote.git" "${work}/C"
git -C "${work}/C" fetch --no-tags origin '+refs/heads/main:refs/remotes/origin/main' 2>&1 | sed 's/^/  fetch: /'
report "still no merge base: the *local* branch is what is shallow, and fetching the base in full does not deepen it" "${work}/C"

echo
echo "### case D: --unshallow, which deepens the local history too"
git clone -q --depth=1 --branch feature "file://${work}/remote.git" "${work}/D"
git -C "${work}/D" fetch --no-tags --unshallow origin '+refs/heads/main:refs/remotes/origin/main' 2>&1 | sed 's/^/  fetch: /'
report "this is the one that answers the question" "${work}/D"

echo
echo "### case E: fetch-depth: 0, i.e. a complete clone"
git clone -q --branch feature "file://${work}/remote.git" "${work}/E"
report "the shipped workflows' configuration, which is why all this is latent" "${work}/E"
```

</details>

