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
