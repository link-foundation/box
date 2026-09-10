
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

- `scripts/validate-changeset.mjs:166` — ``console.log(`  OK: ${result.type} - ${result.description.slice(0, 50)}...`)``, run by `release.yml:214` on **every pull request**. The 50-character slice is not a mitigation: `##[error]` is nine characters, and the runner needs nothing more.

Two further prints of contributor text — `scripts/merge-changesets.mjs:221` and `scripts/collect-changelog.mjs:200` — are **not** reachable from CI, because both are inside `if (dryRun)` and `release.yml:262`/`:322` run those scripts without `--dry-run`. They are worth bracketing anyway, since the guard would then hold for anyone who does pass the flag, but the live site is the validator above.

There is a second, unrelated defect in the same file, reported separately: when `origin/<base>` is not a resolvable ref, `getChangedFiles()` falls back to `git diff --name-only HEAD`, which lists uncommitted changes and therefore nothing at all in CI, and the validator reports success without validating anything.

### Reproduction

No CI and no network: the fixture puts `##[error]…` where a contributor's text goes, and runs this template's own scripts against it. `experiments/issue-123/repro-log-injection-changeset.sh` (attached below):

```bash
cat > .changeset/injected.md <<'EOF'
---
'<the package name the script insists on>': patch
---

##[error]Injected by a changeset body injected through the changeset description a pull request wrote.
EOF

node scripts/validate-changeset.mjs     # the pull-request path
node scripts/merge-changesets.mjs       # the release path
```

Measured against `java` at `450a10ec1f22a7c1c99e4828ad83cfde3b9a0311`:

```
### java template: scripts/merge-changesets.mjs (release.yml runs it before the version bump)
  package name in the front matter: my-package
  exit=0
  NOT REACHABLE: java merge-changesets.mjs did not print the payload -- the print is inside the --dry-run branch, and release.yml:262/:322 run the script without --dry-run
  unguarded: java merge-changesets.mjs emitted no stop-commands token, so the payload is a live log command

### java template: scripts/validate-changeset.mjs (release.yml runs it on every pull request)
  exit=0
  REPRODUCED: java validate-changeset.mjs printed the payload verbatim
  unguarded: java validate-changeset.mjs emitted no stop-commands token, so the payload is a live log command
    7:  OK: patch - ##[error]Injected by a changeset body injected thr...
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

```js
import { randomBytes } from 'node:crypto';

// The resume token is added to the runner's registered command set while
// processing is stopped, and is matched by the same lenient `##[<token>]` rule,
// so text that can guess it can resume command processing and inject anyway.
// 128 bits, fresh per call. Hex also satisfies ValidateStopToken, which rejects
// an empty token, a registered command name, and `pause-logging`.
function printUntrusted(text) {
  if (!process.env.GITHUB_ACTIONS) {
    console.log(text);
    return;
  }
  const token = randomBytes(16).toString('hex');
  console.log(`::stop-commands::${token}`);
  console.log(text);
  console.log(`::${token}::`);
}
```

and at each site above, `console.log(...)` of contributor text becomes `printUntrusted(...)` — with the fixed prefix kept outside the bracket, so `   Description:` still reads as the script's own output:

```diff
-  console.log(`   Description: ${validation.description}`);
+  console.log('   Description:');
+  printUntrusted(validation.description);
```

Rewriting the text — stripping `##[`, say — is the tempting alternative and it is worse: the log then disagrees with the changeset, and it has to be done to every stream of every command that might echo contributor text, including `git commit`'s own subject-line echo.

We ship this as [`scripts/ci/run-with-commands-stopped.sh`](https://github.com/link-foundation/box/blob/main/scripts/ci/run-with-commands-stopped.sh), usable as a command (`bash scripts/ci/run-with-commands-stopped.sh git commit -m "$MESSAGE"`) or sourced for callers that cannot express the untrusted part as one command. Three properties of the runner's implementation shaped it, and are worth knowing before writing your own:

- **Prefer the command form to the bracket form.** An `exit` or a `set -e` abort between a stop and its resume leaves the rest of that step unable to annotate at all. The wrapper always resumes, including when the command fails or dies on a signal.
- **The state is per step, and shared between the streams.** A step's handler creates its own command manager (`Handler.cs:172`) and gives stdout and stderr `OutputManager`s that share it (`ScriptHandler.cs:331-336`), so a token left unresumed cannot leak into a later step, and markers written to one stream do govern the other.
- **Ordering between the two streams is not guaranteed.** A caller whose untrusted text goes to stderr should send the markers there too.

### Relation to earlier work

Found while auditing every CI/CD false positive and false negative in `link-foundation/box` ([box#123](https://github.com/link-foundation/box/issues/123)), which compares this template's full workflow and script tree against ours; the runner-side half was reported during its predecessor, [box#121](https://github.com/link-foundation/box/issues/121), as [actions/runner#4692](https://github.com/actions/runner/issues/4692) with [docker/buildx#4066](https://github.com/docker/buildx/issues/4066) and [docker/build-push-action#1612](https://github.com/docker/build-push-action/issues/1612) for the path that carried it there.

The same defect is present in the js, python, rust, csharp, go and java templates — ten printers measured across the six, all of them unbracketed — and is reported in each. The php template is clean: `validate-changeset.php:42` and `create-github-release.php:48`/`:59` print fixed strings.

### The fixtures, so this is runnable without cloning `box`

<details>
<summary><code>experiments/issue-123/repro-log-injection-changeset.sh</code></summary>

```bash
#!/usr/bin/env bash
# Reproduce: a changeset/changelog body written by a pull request becomes a CI
# annotation, because the release scripts print it verbatim and nothing brackets
# the print in `::stop-commands::`.
#
# The runner's ActionCommand.TryParse accepts `##[` *anywhere* in a physical
# line (unlike TryParseV2, which requires the line to start with it), so any
# printed line quoting `##[error]` is turned into an error annotation on the
# run. That is the mechanism behind link-foundation/box#121, where a single
# commit message produced 56 `failure` annotations on a fully green release,
# and it was reported upstream as actions/runner#4692.
#
# This script drives the templates' own scripts with a fixture body and shows
#   1. the body reaches stdout on a physical line, and
#   2. no `::stop-commands::` token is emitted anywhere around it,
# which together are the whole defect. The fix is to bracket the print with a
# fresh random `::stop-commands::<token>` / `::<token>::` pair.
#
# Usage:
#   bash experiments/issue-123/repro-log-injection-changeset.sh LABEL=DIR [LABEL=DIR ...]
#
# LABEL selects the driver: `js`, `csharp`, `go` and `java` are driven through
# their own scripts/merge-changesets.mjs and scripts/validate-changeset.mjs,
# `python` through scripts/create_github_release.py, `rust` through
# scripts/create-changelog-fragment.rs. DIR is a checkout of the template.
set -uo pipefail

payload='##[error]Injected by a changeset body'

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
failures=0
checked=0

# A stub `gh`: the python script probes `gh --version` and would then create the
# release. Nothing here talks to GitHub.
mkdir -p "${work}/bin"
cat >"${work}/bin/gh" <<'STUB'
#!/bin/sh
[ "$1" = "--version" ] && echo "gh version 0.0.0 (stub)"
exit 0
STUB
chmod +x "${work}/bin/gh"

check() {
  local name="$1" file="$2" unreachable="${3:-}"
  checked=$((checked + 1))
  if grep -qF "${payload}" "${file}"; then
    if [ -n "${unreachable}" ]; then
      echo "  UNEXPECTED: ${name} printed the payload, but it was recorded as unreachable (${unreachable})"
      failures=$((failures + 1))
    else
      echo "  REPRODUCED: ${name} printed the payload verbatim"
    fi
  elif [ -n "${unreachable}" ]; then
    echo "  NOT REACHABLE: ${name} did not print the payload -- ${unreachable}"
  else
    echo "  NOT REPRODUCED: ${name} did not print the payload"
    failures=$((failures + 1))
  fi
  if grep -q 'stop-commands' "${file}"; then
    echo "  guarded: ${name} emitted a stop-commands bracket"
  else
    echo "  unguarded: ${name} emitted no stop-commands token, so the payload is a live log command"
  fi
}

# The package name each merge script insists on in the changeset front matter:
# the templates that ship no package.json hard-code it in the script itself.
package_name_of() {
  local dir="$1"
  if [ -f "${dir}/package.json" ]; then
    node -e "process.stdout.write(require('${dir}/package.json').name)"
    return
  fi
  sed -n "s/^const PACKAGE_NAME = ['\"]\\([^'\"]*\\)['\"].*/\\1/p" \
    "${dir}/scripts/merge-changesets.mjs" | head -n 1
}

drive_mjs() {
  local label="$1" dir="$2" unreachable="${3:-}"
  echo "### ${label} template: scripts/merge-changesets.mjs (release.yml runs it before the version bump)"
  cp -r "${dir}" "${work}/${label}"
  local package
  package="$(package_name_of "${work}/${label}")"
  echo "  package name in the front matter: ${package}"
  mkdir -p "${work}/${label}/.changeset"
  local name bump
  for name in injected-one injected-two; do
    bump='patch'
    [ "${name}" = injected-two ] && bump='minor'
    cat >"${work}/${label}/.changeset/${name}.md" <<EOF
---
'${package}': ${bump}
---

Fix the CI gate. Quoting \`${payload}\` in a changeset used to annotate the run.
EOF
  done
  (cd "${work}/${label}" && node scripts/merge-changesets.mjs) >"${work}/${label}.out" 2>&1
  echo "  exit=$?"
  check "${label} merge-changesets.mjs" "${work}/${label}.out" "${unreachable}"
  grep -nF "${payload}" "${work}/${label}.out" | sed 's/^/    /'
}

drive_validate() {
  local label="$1" dir="$2"
  echo "### ${label} template: scripts/validate-changeset.mjs (release.yml runs it on every pull request)"
  local root="${work}/${label}-validate"
  cp -r "${dir}" "${root}"
  local package
  package="$(package_name_of "${root}")"
  (
    cd "${root}" || exit 1
    # A baseline commit, so what follows is a diff against something: java's
    # validator asks git which files changed and skips everything when the
    # answer contains no source file.
    rm -rf .git
    # Exactly one changeset, so the validator reaches the validation branch
    # rather than its "no changeset" or "multiple changesets" branch. This has
    # to happen before the baseline commit: java's validator iterates over the
    # changed files git reports, so a changeset *deleted* by the fixture would
    # be validated too, and read as a missing file.
    find .changeset -maxdepth 1 -name '*.md' ! -name 'README.md' -delete 2>/dev/null
    git init -q . >/dev/null 2>&1
    git config user.email ci@example.invalid
    git config user.name CI
    git add -A -f >/dev/null 2>&1
    git commit -qm baseline >/dev/null 2>&1
    # The base the pull request would be opened against. Without a real
    # `origin/<base>` ref, `git diff origin/main...HEAD` answers "nothing
    # changed" and java's validator skips itself.
    git branch -qM main >/dev/null 2>&1
    git update-ref refs/remotes/origin/main HEAD

    cat >.changeset/injected.md <<EOF
---
'${package}': patch
---

${payload} injected through the changeset description a pull request wrote.
EOF
    # A source change beside it: every template treats scripts/ as source.
    echo "fixture" >scripts/.injection-fixture.txt
    git add -A -f >/dev/null 2>&1
    git commit -qm "the pull request" >/dev/null 2>&1
  )
  (cd "${root}" && GITHUB_BASE_REF=main node scripts/validate-changeset.mjs) \
    >"${work}/${label}-validate.out" 2>&1
  echo "  exit=$?"
  check "${label} validate-changeset.mjs" "${work}/${label}-validate.out"
  grep -nF "${payload}" "${work}/${label}-validate.out" | sed 's/^/    /'
}

# The rust template prints no pull-request-authored file body: its release
# scripts print fragment *names*. What it does print verbatim is the changelog
# fragment it builds from the `workflow_dispatch` description an operator typed,
# which is the same defect with a smaller blast radius.
drive_rust() {
  local label="$1" dir="$2"
  echo "### ${label} template: scripts/create-changelog-fragment.rs (release.yml:1167 runs it in the manual-release job)"
  if ! command -v rust-script >/dev/null 2>&1; then
    echo "  SKIPPED: rust-script is not on PATH (install it with ${dir}/scripts/install-rust-script.sh)"
    return 0
  fi
  cp -r "${dir}" "${work}/${label}"
  (cd "${work}/${label}" && rust-script scripts/create-changelog-fragment.rs \
    --bump-type patch --description "${payload}") >"${work}/${label}.out" 2>&1
  echo "  exit=$?"
  check "${label} create-changelog-fragment.rs" "${work}/${label}.out"
  grep -nF "${payload}" "${work}/${label}.out" | sed 's/^/    /'
}

drive_python() {
  local label="$1" dir="$2"
  echo "### ${label} template: scripts/create_github_release.py (release.yml runs it in both release jobs)"
  cp -r "${dir}" "${work}/${label}"
  cat >"${work}/${label}/CHANGELOG.md" <<EOF
# Changelog

## 9.9.9

- Fix the CI gate. Quoting \`${payload}\` in a changelog fragment used to annotate the run.
EOF
  (cd "${work}/${label}" && PATH="${work}/bin:${PATH}" GH_TOKEN=stub \
    python3 scripts/create_github_release.py --version 9.9.9 --repository owner/repo) \
    >"${work}/${label}.out" 2>&1
  echo "  exit=$?"
  check "${label} create_github_release.py" "${work}/${label}.out"
  grep -nF "${payload}" "${work}/${label}.out" | sed 's/^/    /'
}

first=true
for pair in "$@"; do
  label="${pair%%=*}"
  dir="${pair#*=}"
  [ -d "${dir}" ] || {
    echo "### ${label}: ${dir} is not a directory, skipped"
    continue
  }
  [ "${first}" = true ] || echo
  first=false
  case "${label}" in
    python) drive_python "${label}" "${dir}" ;;
    rust) drive_rust "${label}" "${dir}" ;;
    java)
      # `console.log(mergedContent)` at scripts/merge-changesets.mjs:221 and
      # `console.log(combinedContent)` at scripts/collect-changelog.mjs:200 are
      # both inside `if (dryRun)`, and release.yml:262/:322 run the script with
      # no `--dry-run`, so neither print is reachable from CI.
      drive_mjs "${label}" "${dir}" \
        "the print is inside the --dry-run branch, and release.yml:262/:322 run the script without --dry-run"
      echo
      drive_validate "${label}" "${dir}"
      ;;
    *)
      drive_mjs "${label}" "${dir}"
      echo
      drive_validate "${label}" "${dir}"
      ;;
  esac
done

echo
echo "${checked} printer(s) checked, ${failures} did not reproduce."
exit "${failures}"
```

</details>

