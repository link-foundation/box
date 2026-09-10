`validate-changeset.mjs` falls back to a diff that is always empty in CI, so when `origin/<base>` is missing the check passes without validating anything

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
