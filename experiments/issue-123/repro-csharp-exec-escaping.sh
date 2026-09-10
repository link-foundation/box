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
