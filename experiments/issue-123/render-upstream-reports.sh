#!/usr/bin/env bash
# Render the per-repository bodies of the four upstream reports from the
# templates in dev/log/issues/123/pulls/124/upstream/ plus the measured
# evidence beside them, so every line number and every quoted transcript in a
# filed issue comes out of a checkout rather than out of a note.
#
# Usage:
#   TEMPLATES_DIR=/tmp/templates bash experiments/issue-123/render-upstream-reports.sh
#
# Writes dev/log/issues/123/pulls/124/upstream/filed/<letter>-<repo>.md, whose
# first line is the issue title and whose remainder is the issue body.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATES_DIR="${TEMPLATES_DIR:-/tmp/templates}"
OUT_DIR="${REPO_ROOT}/dev/log/issues/123/pulls/124/upstream/filed"
UP_DIR="${REPO_ROOT}/dev/log/issues/123/pulls/124/upstream"
EVIDENCE="${UP_DIR}/evidence"

mkdir -p "$OUT_DIR"

sha_of() { git -C "${TEMPLATES_DIR}/$1" rev-parse HEAD; }

# The section of an evidence transcript that belongs to one repository: from its
# `=== <repo>: <sha> ===` header to the next header or end of file.
section() {
  local file="$1" repo="$2"
  awk -v repo="$repo" '
    /^=== / { inside = ($0 ~ "^=== " repo "[:@ ]") ; next }
    inside { print }
  ' "$file" | sed -e :a -e '/^\s*$/{$d;N;ba' -e '}'
}

# Substitute __NAME__ placeholders from a name=value list on stdin.
render() {
  local template="$1"
  shift
  python3 - "$template" "$@" <<'PY'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    text = handle.read()
for pair in sys.argv[2:]:
    name, _, value = pair.partition("=")
    text = text.replace("__%s__" % name, value)
missing = [w for w in ("__REPO__", "__SHA__") if w in text]
if missing:
    sys.exit("unsubstituted placeholder(s) left: %s" % ", ".join(missing))
# An empty optional section leaves a run of blank lines behind.
import re
text = re.sub(r"\n{3,}", "\n\n", text)
sys.stdout.write(text)
PY
}

# ---------------------------------------------------------------- report A ---
declare -A A_SUPERSEDE_LINE=([js]=14 [python]=36 [rust]=36 [php]=47)
declare -A A_DECISION=([js]=59:66 [python]=69:78 [rust]=69:78 [php]=80:89)
declare -A A_PRIOR=(
  [js]='[js#167](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/167)'
  [python]='[python#69](https://github.com/link-foundation/python-ai-driven-development-pipeline-template/issues/69)'
  [rust]='[rust#156](https://github.com/link-foundation/rust-ai-driven-development-pipeline-template/issues/156)'
  [php]='[php#9](https://github.com/link-foundation/php-ai-driven-development-pipeline-template/issues/9)'
)

# The one-line withdrawal of the excuse, in each script's own shape.
A_WORKAROUND_JS='-  if [ "$IS_MAIN" = "true" ] && ! run_is_superseded; then
+  if [ "$IS_MAIN" = "true" ]; then'
A_WORKAROUND_BASHISM='   if [[ "$IS_MAIN" != "true" ]]; then
     echo "::warning::Cancelled jobs: ${cancelled}. On a non-default ref this is usually a superseded run …"
-  elif run_is_superseded; then
-    echo "::warning::Cancelled jobs: ${cancelled}. This run is no longer the head of ${BRANCH_REF}: a newer commit superseded it, so the cancellation is expected churn."
   else'
declare -A A_WORKAROUND=(
  [js]="$A_WORKAROUND_JS"
  [python]="$A_WORKAROUND_BASHISM"
  [rust]="$A_WORKAROUND_BASHISM"
  [php]="$A_WORKAROUND_BASHISM"
)

for repo in js python rust php; do
  sha="$(sha_of "$repo")"
  range="${A_DECISION[$repo]}"
  from="${range%%:*}"
  to="${range##*:}"
  snippet="$(sed -n "${from},${to}p" "${TEMPLATES_DIR}/${repo}/scripts/check-pipeline-status.sh")"
  render "${UP_DIR}/A-supersede.md" \
    "REPO=${repo}" \
    "SHA=${sha}" \
    "REPO_SCRIPT=\`scripts/check-pipeline-status.sh:${from}-${to}\` @ \`${sha:0:8}\`" \
    "SUPERSEDE_LINE=line ${A_SUPERSEDE_LINE[$repo]}" \
    "SNIPPET=${snippet}" \
    "REPRO_OUTPUT=$(section "${EVIDENCE}/repro-supersede.txt" "$repo")" \
    "WORKAROUND=${A_WORKAROUND[$repo]}" \
    "PRIOR=${A_PRIOR[$repo]}" \
    >"${OUT_DIR}/A-${repo}.md"
done

echo "Rendered:"
ls -1 "$OUT_DIR" | sed 's/^/  /'

# ---------------------------------------------------------------- report B ---
declare -A B_HEADING=(
  [js]='`scripts/run-with-budget-warning.sh:73-99` @ __SHORT__'
  [python]='`scripts/run-with-budget-warning.sh:51-73` @ __SHORT__'
  [rust]='`scripts/run-with-budget-warning.sh:83-106` @ __SHORT__'
  [php]='`scripts/run-with-budget-warning.sh:51-73` @ __SHORT__'
)
declare -A B_SNIPPET_RANGE=([js]=73:99 [python]=51:73 [rust]=83:106 [php]=51:73)
B_NOTE_JS='`command_is_running` returns "not running" as soon as `${status_file}` exists, and the status file is written by the wrapper subshell the moment the **root** of the command returns — so a child that outlives its parent is never asked about. The `kill -0 -- "-${command_pid}"` half is the fallback, and it cannot see a root-owned survivor either: `kill -0` fails with EPERM ("alive, not yours to signal") and with ESRCH ("gone") alike, both exit status 1.'
B_NOTE_DIRECT='`set -m` does give the command its own process group, but liveness is then asked of `$command_pid` alone — the **root** of the command. When the root returns while its workers keep going, `kill -0 "$command_pid"` fails and the loop ends: the group the `set -m` was for is never polled. And `kill -0` could not answer for a root-owned survivor anyway — EPERM ("alive, not yours to signal") and ESRCH ("gone") are both exit status 1.'
declare -A B_NOTE=(
  [js]="$B_NOTE_JS"
  [python]="$B_NOTE_DIRECT"
  [rust]="$B_NOTE_DIRECT"
  [php]="$B_NOTE_DIRECT"
)
declare -A B_PRIOR=(
  [js]='[js#164](https://github.com/link-foundation/js-ai-driven-development-pipeline-template/issues/164)'
  [python]='[python#60](https://github.com/link-foundation/python-ai-driven-development-pipeline-template/issues/60)'
  [rust]='[rust#153](https://github.com/link-foundation/rust-ai-driven-development-pipeline-template/issues/153)'
  [php]='[php#10](https://github.com/link-foundation/php-ai-driven-development-pipeline-template/issues/10), which asked for this wrapper to exist at all'
)

box_output="$(section "${EVIDENCE}/repro-budget-survivor.txt" 'box')"

for repo in js python rust php; do
  sha="$(sha_of "$repo")"
  range="${B_SNIPPET_RANGE[$repo]}"
  snippet="$(sed -n "${range%%:*},${range##*:}p" "${TEMPLATES_DIR}/${repo}/scripts/run-with-budget-warning.sh")"
  heading="${B_HEADING[$repo]//__SHORT__/\`${sha:0:8}\`}"
  render "${UP_DIR}/B-budget-survivor.md" \
    "REPO=${repo}" \
    "SHA=${sha}" \
    "PROBE_HEADING=${heading}" \
    "PROBE_SNIPPET=${snippet}" \
    "PROBE_NOTE=${B_NOTE[$repo]}" \
    "REPRO_OUTPUT=$(section "${EVIDENCE}/repro-budget-survivor.txt" "$repo")" \
    "BOX_OUTPUT=${box_output}" \
    "PRIOR=${B_PRIOR[$repo]}" \
    >"${OUT_DIR}/B-${repo}.md"
done

echo "Rendered (B):"
ls -1 "$OUT_DIR" | sed 's/^/  /'

# The section of the log-injection transcript that belongs to one template: its
# `### <repo> template:` blocks, which is more than one per repository.
log_section() {
  local file="$1" repo="$2"
  awk -v repo="$repo" '
    /^### / { inside = ($0 ~ "^### " repo " template:") }
    /printer\(s\) checked/ { inside = 0 }
    inside { print }
  ' "$file" | sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}'
}

# ---------------------------------------------------------------- report C ---
C_PRINTERS_JS='- `scripts/validate-changeset.mjs:269` — ``console.log(`   Description: ${validation.description}`)``, run by `release.yml:206` on **every pull request**. This is the important one: it prints on a *valid* changeset, so no failure is needed to reach it.
- `scripts/merge-changesets.mjs:276` — ``console.log(`\nMerged changeset content:\n${mergedContent}`)``, run by `release.yml:573` — every changeset body in the release, concatenated.
- `scripts/validate-changeset.mjs:260` — `console.error(readFileSync(changesetFile, '"'"'utf-8'"'"'))`, the whole file, on the failure path.'
C_PRINTERS_CSHARP='- `scripts/validate-changeset.mjs:270` — ``console.log(`   Description: ${validation.description}`)``, run by `release.yml:145` on **every pull request**. This is the important one: it prints on a *valid* changeset, so no failure is needed to reach it.
- `scripts/merge-changesets.mjs:261` — ``console.log(`\nMerged changeset content:\n${mergedContent}`)``, run by `release.yml:412` — every changeset body in the release, concatenated.
- `scripts/validate-changeset.mjs:261` — `console.error(readFileSync(changesetFile, '"'"'utf-8'"'"'))`, the whole file, on the failure path.'
C_PRINTERS_GO='- `scripts/validate-changeset.mjs:263` — ``console.log(`   Description: ${validation.description}`)``, run by `release.yml:94` on **every pull request**. This is the important one: it prints on a *valid* changeset, so no failure is needed to reach it.
- `scripts/merge-changesets.mjs:260` — ``console.log(`\nMerged changeset content:\n${mergedContent}`)``, run by `release.yml:235` and `release.yml:322`.
- `scripts/validate-changeset.mjs:254` — `console.error(readFileSync(changesetFile, "utf-8"))`, the whole file, on the failure path.'
C_PRINTERS_JAVA='- `scripts/validate-changeset.mjs:166` — ``console.log(`  OK: ${result.type} - ${result.description.slice(0, 50)}...`)``, run by `release.yml:214` on **every pull request**. The 50-character slice is not a mitigation: `##[error]` is nine characters, and the runner needs nothing more.'
C_PRINTERS_PYTHON='- `scripts/create_github_release.py:176` — `print(f"\nRelease notes:\n{release_notes}\n")`, run by `release.yml:684` and `release.yml:824`. `release_notes` is the section `extract_release_notes()` reads out of `CHANGELOG.md`, which is assembled from the changelog fragments pull requests write.'
C_PRINTERS_RUST='- `scripts/create-changelog-fragment.rs:118` — `println!("{}", fragment_content)`, run by `release.yml:1167` in the manual-release job.'

C_NOTE_NONE='The exposure is the ordinary contribution path: open a pull request, add a changeset, and the description you wrote is printed as a physical line in the log of the job that validates it.'
C_NOTE_JAVA='Two further prints of contributor text — `scripts/merge-changesets.mjs:221` and `scripts/collect-changelog.mjs:200` — are **not** reachable from CI, because both are inside `if (dryRun)` and `release.yml:262`/`:322` run those scripts without `--dry-run`. They are worth bracketing anyway, since the guard would then hold for anyone who does pass the flag, but the live site is the validator above.

There is a second, unrelated defect in the same file, reported separately: when `origin/<base>` is not a resolvable ref, `getChangedFiles()` falls back to `git diff --name-only HEAD`, which lists uncommitted changes and therefore nothing at all in CI, and the validator reports success without validating anything.'
C_NOTE_PYTHON='The exposure is the ordinary contribution path: a pull request adds a changelog fragment, the fragment becomes a section of `CHANGELOG.md`, and the release job prints that section as its release notes. The same text is then passed to `gh release create --notes`, so it is printed twice in the transcript below.'
C_NOTE_RUST='**This is the weaker variant of the defect.** In this template nothing prints a *pull-request-authored* file: `scripts/collect-changelog.rs` prints fragment names (`Removed {}`, `Updated CHANGELOG.md with version {}`) and not fragment bodies. What is printed verbatim is the fragment built from the `description` an operator types into `workflow_dispatch`, so reaching it needs write access. It is still a repository that cannot print its own release annotations reliably, and the fix is the same three lines.

Worth saying explicitly, because it is the reason this is filed at all: the `env:`-then-`"$DESCRIPTION"` form at `release.yml:1165-1167` is *correct*, and is what the other templates need to adopt. This report is only about the print.'

C_FIX_JS='```js
import { randomBytes } from '"'"'node:crypto'"'"';

// The resume token is added to the runner'"'"'s registered command set while
// processing is stopped, and is matched by the same lenient `##[<token>]` rule,
// so text that can guess it can resume command processing and inject anyway.
// 128 bits, fresh per call. Hex also satisfies ValidateStopToken, which rejects
// an empty token, a registered command name, and `pause-logging`.
function printUntrusted(text) {
  if (!process.env.GITHUB_ACTIONS) {
    console.log(text);
    return;
  }
  const token = randomBytes(16).toString('"'"'hex'"'"');
  console.log(`::stop-commands::${token}`);
  console.log(text);
  console.log(`::${token}::`);
}
```

and at each site above, `console.log(...)` of contributor text becomes `printUntrusted(...)` — with the fixed prefix kept outside the bracket, so `   Description:` still reads as the script'"'"'s own output:

```diff
-  console.log(`   Description: ${validation.description}`);
+  console.log('"'"'   Description:'"'"');
+  printUntrusted(validation.description);
```'
C_FIX_PYTHON='```python
import os
import secrets


def print_untrusted(text: str) -> None:
    """Print text this repository did not write, with workflow commands off.

    The resume token is added to the runner'"'"'s registered command set while
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

`gh release create --notes` is a separate matter: it takes the text as an argument, so it is not a log-command question, but note that `subprocess` invocations should keep passing it as an argv element rather than through a shell.'
C_FIX_RUST='```rust
use std::fs::File;
use std::io::Read;

/// Print text this repository did not write, with workflow commands off.
///
/// The resume token is added to the runner'"'"'s registered command set while
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
```'

C_MJS_COMMAND=$(
  cat <<'CMD'
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
CMD
)
C_PYTHON_COMMAND=$(
  cat <<'CMD'
```bash
cat > CHANGELOG.md <<'EOF'
# Changelog

## 9.9.9

- Fix the CI gate. Quoting `##[error]Injected by a changeset body` in a changelog fragment used to annotate the run.
EOF

python3 scripts/create_github_release.py --version 9.9.9 --repository owner/repo
```
CMD
)
C_RUST_COMMAND=$(
  cat <<'CMD'
```bash
rust-script scripts/create-changelog-fragment.rs \
  --bump-type patch --description '##[error]Injected by a changeset body'
```
CMD
)
declare -A C_COMMAND=(
  [js]="$C_MJS_COMMAND" [csharp]="$C_MJS_COMMAND" [go]="$C_MJS_COMMAND" [java]="$C_MJS_COMMAND"
  [python]="$C_PYTHON_COMMAND" [rust]="$C_RUST_COMMAND"
)

declare -A C_PRINTERS=(
  [js]="$C_PRINTERS_JS" [csharp]="$C_PRINTERS_CSHARP" [go]="$C_PRINTERS_GO"
  [java]="$C_PRINTERS_JAVA" [python]="$C_PRINTERS_PYTHON" [rust]="$C_PRINTERS_RUST"
)
declare -A C_NOTE=(
  [js]="$C_NOTE_NONE" [csharp]="$C_NOTE_NONE" [go]="$C_NOTE_NONE"
  [java]="$C_NOTE_JAVA" [python]="$C_NOTE_PYTHON" [rust]="$C_NOTE_RUST"
)
declare -A C_FIX=(
  [js]="$C_FIX_JS" [csharp]="$C_FIX_JS" [go]="$C_FIX_JS" [java]="$C_FIX_JS"
  [python]="$C_FIX_PYTHON" [rust]="$C_FIX_RUST"
)
C_PRIOR='The same defect is present in the js, python, rust, csharp, go and java templates — ten printers measured across the six, all of them unbracketed — and is reported in each. The php template is clean: `validate-changeset.php:42` and `create-github-release.php:48`/`:59` print fixed strings.'

for repo in js python rust csharp go java; do
  sha="$(sha_of "$repo")"
  render "${UP_DIR}/C-log-injection.md" \
    "REPO=${repo}" \
    "SHA=${sha}" \
    "PRINTERS=${C_PRINTERS[$repo]}" \
    "REPRO_COMMAND=${C_COMMAND[$repo]}" \
    "SEVERITY_NOTE=${C_NOTE[$repo]}" \
    "LANG_FIX=${C_FIX[$repo]}" \
    "REPRO_OUTPUT=$(log_section "${EVIDENCE}/repro-log-injection-changeset.txt" "$repo")" \
    "PRIOR=${C_PRIOR}" \
    >"${OUT_DIR}/C-${repo}.md"
done

# ---------------------------------------------------------------- report D ---
# The section of the dispatch transcript that belongs to one template: its
# `### <repo> @ <sha> -- ...` block, up to the next `###` header.
dispatch_section() {
  local repo="$1"
  awk -v repo="$repo" '
    /^### / { inside = ($0 ~ "^### " repo " @") }
    inside { print }
  ' "${EVIDENCE}/repro-dispatch-description-injection.txt" \
    | sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}'
}

D_SITES_GO='- `release.yml:281`, job `instant-release` (`Instant Release`), which runs with the workflow-level `contents: write` and `pull-requests: write`:

  ```yaml
  run: bun scripts/version-and-commit.mjs --mode instant --bump-type ${{ github.event.inputs.bump_type }} --description "${{ github.event.inputs.description }}"
  ```

  `--bump-type` is additionally unquoted, and `--description` carries the value GitHub does not validate.'

D_SITES_JAVA='- `release.yml:429-436`, job `changeset-pr` (`Create Changeset PR`), `contents: write` + `pull-requests: write` — this is the live one, because it reads `description`:

  ```yaml
  run: |
    DESCRIPTION="${{ inputs.description }}"
    if [ -z "$DESCRIPTION" ]; then
      DESCRIPTION="Manual release"
    fi
    bun scripts/create-manual-changeset.mjs \
      --bump-type "${{ inputs.bump_type }}" \
      --description "$DESCRIPTION"
  ```

  The `DESCRIPTION="…"` assignment is the whole problem: the value is inside the double quotes of a shell assignment the runner has already written, so `$( )` in it is a command substitution.

- `release.yml:382`, job `manual-release-instant` (`Manual Release (Instant)`), `contents: write`:

  ```yaml
  run: bun scripts/version-and-commit.mjs --mode instant --bump-type ${{ inputs.bump_type }}
  ```

  Only the validated `choice` reaches this one, and the expansion is unquoted. Defence in depth rather than a live hole, and the same fix.'

D_FIX_GO='       - name: Version and release
         id: version
-        run: bun scripts/version-and-commit.mjs --mode instant --bump-type ${{ github.event.inputs.bump_type }} --description "${{ github.event.inputs.description }}"
         env:
           CI: true
+          BUMP_TYPE: ${{ github.event.inputs.bump_type }}
+          DESCRIPTION: ${{ github.event.inputs.description }}
+        run: bun scripts/version-and-commit.mjs --mode instant --bump-type "$BUMP_TYPE" --description "$DESCRIPTION"'

D_FIX_JAVA='       - name: Create changeset file
+        env:
+          BUMP_TYPE: ${{ inputs.bump_type }}
+          DESCRIPTION_INPUT: ${{ inputs.description }}
         run: |
-          DESCRIPTION="${{ inputs.description }}"
+          DESCRIPTION="$DESCRIPTION_INPUT"
           if [ -z "$DESCRIPTION" ]; then
             DESCRIPTION="Manual release"
           fi
           bun scripts/create-manual-changeset.mjs \
-            --bump-type "${{ inputs.bump_type }}" \
+            --bump-type "$BUMP_TYPE" \
             --description "$DESCRIPTION"

       - name: Run version and commit script
         id: release
-        run: bun scripts/version-and-commit.mjs --mode instant --bump-type ${{ inputs.bump_type }}
         env:
           GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
+          BUMP_TYPE: ${{ inputs.bump_type }}
+        run: bun scripts/version-and-commit.mjs --mode instant --bump-type "$BUMP_TYPE"'

D_EXTRA_JAVA='### One note on the transcript

`release.yml:429` reproduces under both payloads and `release.yml:382` under both as well, but for different reasons: the first is a live shell assignment fed by an unvalidated `string`, the second is an unquoted expansion fed by a validated `choice`. The fixture substitutes the payload wherever the expression appears; GitHub is what stops the second one today.'

D_EXTRA_GO=''

declare -A D_SITES=([go]="$D_SITES_GO" [java]="$D_SITES_JAVA")
declare -A D_FIX=([go]="$D_FIX_GO" [java]="$D_FIX_JAVA")
declare -A D_EXTRA=([go]="$D_EXTRA_GO" [java]="$D_EXTRA_JAVA")

D_PRIOR='Reported in the `go` and `java` templates, which are the two that interpolate a dispatch input into a `run:` script and have no open report for it. The `rust` template had the same defect and fixed it in [rust#111](https://github.com/link-foundation/rust-ai-driven-development-pipeline-template/issues/111); in the `csharp` template it is already open as [csharp#53](https://github.com/link-foundation/csharp-ai-driven-development-pipeline-template/issues/53), to which we added the measured transcript rather than filing again.'

for repo in go java; do
  sha="$(sha_of "$repo")"
  render "${UP_DIR}/D-dispatch-injection.md" \
    "REPO=${repo}" \
    "SHA=${sha}" \
    "SITES=${D_SITES[$repo]}" \
    "FIX_DIFF=${D_FIX[$repo]}" \
    "REPRO_OUTPUT=$(dispatch_section "$repo")" \
    "EXTRA=${D_EXTRA[$repo]}" \
    "PRIOR=${D_PRIOR}" \
    >"${OUT_DIR}/D-${repo}.md"
done

echo "Rendered (D):"
ls -1 "$OUT_DIR" | sed 's/^/  /'
