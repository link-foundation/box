
### Summary

`scripts/validate-changeset.mjs:23-41` asks git which files the pull request changed, and falls back to the working tree when that fails:

```js
function getChangedFiles() {
  try {
    const baseBranch = process.env.GITHUB_BASE_REF || 'main';
    const output = execSync(`git diff --name-only origin/${baseBranch}...HEAD`, {
      encoding: 'utf-8',
    });
    return output.trim().split('\n').filter(Boolean);
  } catch {
    // Fallback: get all staged/unstaged changes
    try {
      const output = execSync('git diff --name-only HEAD', { encoding: 'utf-8' });
      return output.trim().split('\n').filter(Boolean);
    } catch {
      return [];
    }
  }
}
```

Two facts meet here:

- `git diff --name-only origin/<base>...HEAD` exits **128** — not 1, not empty output — when `origin/<base>` is not a resolvable ref. So this is a `catch`, not a "no files changed".
- `git diff --name-only HEAD` lists **uncommitted** changes. A CI checkout has none, ever. So the fallback answers `[]` on every run.

`main()` then reads that as "nothing changed":

```js
const changedFiles = getChangedFiles();          // :128
console.log(`Changed files: ${changedFiles.length}`);
if (!hasSourceChanges(changedFiles)) {           // :132
  console.log('\nNo source code changes detected. Changeset not required.');
  process.exit(0);
}
```

The job is green, and no changeset was read. The fallback cannot produce any other outcome in CI: it is a code path whose only reachable result is silent success.

### Root cause, stated as a rule

The fallback answers a different question from the one that failed. "What did this branch change relative to its base" and "what is uncommitted in this working tree" are unrelated, and the second is empty by construction on a fresh checkout — so the error path is indistinguishable from a clean pull request.

### How latent it is

`release.yml`'s `changeset-check` job checks out with `fetch-depth: 0`, which does create `refs/remotes/origin/*`, so the shipped workflow takes the first branch today. It bites:

- any copy of the template that reduces the fetch depth (the obvious CI speed-up), and
- anyone running the validator locally or from another workflow.

And it is worth fixing even where it is latent, because a check whose failure mode is "pass" gives no signal that it stopped working.

### Reproduction

No CI and no network. `experiments/issue-123/repro-changeset-validation-fallback.sh` (attached below) builds a repository with a source change and a deliberately malformed changeset, then runs this template's own validator twice — once without `refs/remotes/origin/main` and once with it, which is the only difference between the two runs:

```bash
printf 'no front matter, no bump type, not a valid changeset\n' > .changeset/broken.md
echo fixture > scripts/.injection-fixture.txt
git add -A && git commit -qm "the pull request"

node scripts/validate-changeset.mjs                       # 1: no origin/main
git update-ref refs/remotes/origin/main HEAD~1
node scripts/validate-changeset.mjs                       # 2: origin/main present
```

Measured against `450a10ec1f22a7c1c99e4828ad83cfde3b9a0311`:

```
### git's own answer when origin/<base> does not resolve
  git diff --name-only HEAD~1...HEAD -> file.txt (exit 0)
  git diff --name-only origin/main...HEAD -> 'fatal: ambiguous argument
  'origin/main...HEAD': unknown revision or path not in the working tree.' (exit 128)

### java: the validator itself, on a pull request with a broken changeset
  -- with no origin/main ref (a shallow or single-branch checkout):
     Validating changesets...
     fatal: ambiguous argument 'origin/main...HEAD': unknown revision or path not in the working tree.
     Changed files: 0
     No source code changes detected. Changeset not required.
     exit=0
  -- with origin/main present, which is the only difference:
     Validating changesets...
     Changed files: 2
     Source code changes detected. Checking for changeset...
     Validating: .changeset/broken.md
       ERROR: Changeset must have frontmatter section (---)
     Some changesets have validation errors.
     exit=1
```

The same tree, the same malformed changeset, `exit=0` and `exit=1` — decided by whether one ref happens to exist. (Blank lines are elided above; the fixture prints two further sections, for the two `rust` scripts named at the end of this report.)

### Workaround

Guarantee the ref rather than the depth. Any job running the validator needs either

```yaml
- uses: actions/checkout@v5
  with:
    fetch-depth: 0
```

or, if the depth has to stay bounded at checkout time, an `--unshallow` fetch of the base branch before the script runs:

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

`--depth=1` would not do it, and this is worth measuring rather than assuming — we did, in a shallow single-branch clone:

| fetch before the diff | result |
| --- | --- |
| `git fetch origin main --depth=1` | no `refs/remotes/origin/main` created at all (the clone's refspec covers only the head branch); exit 128, *unknown revision* |
| `git fetch --depth=1 origin '+refs/heads/main:refs/remotes/origin/main'` | ref present; exit 128, *no merge base* |
| the same with no depth limit | still exit 128, *no merge base* — what is shallow is the local branch |
| `git fetch --no-tags --unshallow origin '+refs/heads/main:…'` | exit 0 |
| `fetch-depth: 0` at checkout | exit 0 |

All four failing forms exit **128**, which is the point: no amount of fetching removes the need for the caller to tell "git could not answer" apart from "nothing changed".

That keeps the first branch alive; it does not make the failure visible, which is the fix below.

### Suggested fix

Two changes, and the template already contains the answer to the first one — the js, go and csharp templates fall back to **validating everything in the changeset directory** instead of validating nothing:

```js
// js/scripts/validate-changeset.mjs:120-130
function getAllChangesets(changesetDir) {
  console.log('Warning: Could not determine PR diff, checking all changesets in directory');
  if (!existsSync(changesetDir)) return [];
  return readdirSync(changesetDir).filter((f) => f.endsWith('.md') && f !== 'README.md');
}
```

That fallback is safe in the right direction: it can only validate more than the pull request touched, never less. (`php` does the same thing — `validate-changeset.php:24` passes `null` for the added count when the diff comes back empty, which makes the validator count the directory — and `python` never asks git at all.)

For java:

```diff
 function getChangedFiles() {
   try {
     const baseBranch = process.env.GITHUB_BASE_REF || 'main';
-    const output = execSync(
-      `git diff --name-only origin/${baseBranch}...HEAD`,
-      { encoding: 'utf-8' }
-    );
+    // Make the base ref resolvable rather than assuming it is. --depth=1 is not
+    // enough: a single-branch clone has no refspec that would create the
+    // remote-tracking ref, and a shallow head leaves the pair without a merge
+    // base either way.
+    try {
+      // --unshallow is rejected outright on a complete repository.
+      const shallow = existsSync(
+        join(execSync('git rev-parse --git-dir', { encoding: 'utf-8' }).trim(), 'shallow')
+      );
+      execSync(
+        `git fetch --no-tags ${shallow ? '--unshallow ' : ''}origin ` +
+          `+refs/heads/${baseBranch}:refs/remotes/origin/${baseBranch}`,
+        { stdio: 'ignore' }
+      );
+    } catch {
+      // Already complete, or no network: the diff below decides.
+    }
+    const output = execSync(
+      `git diff --name-only origin/${baseBranch}...HEAD`,
+      { encoding: 'utf-8' }
+    );
     return output.trim().split('\n').filter(Boolean);
-  } catch {
-    // Fallback: get all staged/unstaged changes
-    try {
-      const output = execSync('git diff --name-only HEAD', { encoding: 'utf-8' });
-      return output.trim().split('\n').filter(Boolean);
-    } catch {
-      return [];
-    }
+  } catch (error) {
+    // `git diff --name-only HEAD` is not a fallback for this question: it lists
+    // uncommitted changes, of which a CI checkout has none, so it would report
+    // "nothing changed" for every pull request. Validate the whole changeset
+    // directory instead -- more than the PR touched, never less.
+    console.warn(`::warning::Could not determine the PR diff (${error.message.split('\n')[0]}); validating every changeset in the directory instead.`);
+    return null;
   }
 }
```

with `main()` reading `null` as "diff unavailable" and validating `.changeset/*.md` wholesale, exactly as `getAllChangesets` does in the other three templates.

Second, and independent of the above: the fallback should announce itself. The `catch` today swallows a `fatal:` that git already printed and then prints `Changed files: 0`, which reads like a clean answer. An `::warning::` costs one line and makes the degraded mode visible in the run summary.

Worth noting while you are in this file: `:147-155` exits 0 when a source-changing pull request has no changeset at all, with a comment saying so deliberately (`Change to process.exit(1) if you want to enforce changesets`). That is a policy choice and this report does not argue with it — but it does mean the only way this check can fail is a *malformed* changeset, which is precisely what the fallback above stops it from ever reading.

### Relation to earlier work

Found while auditing every CI/CD false positive and false negative in `link-foundation/box` ([box#123](https://github.com/link-foundation/box/issues/123)), which compares this template's full workflow and script tree against ours, file by file.

We asked the same question of all seven templates. Five of them err in the safe direction: js (`:120`), go (`:113`) and csharp (`:120`) fall back to validating the whole changeset directory, php passes `null` as the added count so its validator counts the directory, python never consults git, and rust's `detect-code-changes.rs:151-165` falls back to `git ls-tree --name-only -r HEAD`, i.e. every file in the tree. All five can only do *more* work than the pull request needs.

Two do not, and both are in `rust`, in a different code shape but the same class — `exec()` returns `String::new()` when the command fails, and an empty changed-file list is read as a clean pull request:

- `scripts/check-changelog-fragment.rs` — prints `Error executing git [...]`, then `No changed files found`, exit 0.
- `scripts/check-version-modification.rs` — the same `exec()` without the `eprintln!`, and its `Ok(output)` arm ignores `output.status` altogether, so a `fatal:` is captured into `output.stderr` and dropped: the transcript shows `No changes to Cargo.toml detected. / Version check passed.` over a `Cargo.toml` carrying a hand-written `version = "9.9.9"`, with nothing printed in between.

Reported there as a companion to this one, with the same fixture — the third and fourth sections of the transcript above are those two scripts.

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

