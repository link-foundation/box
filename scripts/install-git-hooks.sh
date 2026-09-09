#!/usr/bin/env bash
#
# install-git-hooks.sh — point this clone's git hooks at the tracked .githooks/
# directory, and then check that it worked.
#
# Issue #121, hive-mind best practice #8. The js template installs hooks with
# husky from `npm prepare`; this repository has no package.json at its root, so
# the same guarantee is built from `core.hooksPath`, which git has had since
# 2.9 and which needs nothing installed.
#
# WHAT IS PORTED FROM THE TEMPLATE IS THE VERIFICATION, NOT THE TOOL
#   scripts/install-git-hooks.mjs there opens with:
#
#     husky exits 0 for every failure it has, including ".git can't be found",
#     so the exit code proves nothing. Verify the outcome instead: after husky
#     runs, `git config --get core.hooksPath` must name the installed hooks.
#
#   That is the same finding as the rest of issue #121 - a step that reports
#   success without having done anything - and it applies here even though the
#   tool is different: `git config core.hooksPath .githooks` also exits 0 when
#   it writes the value into a config file that this clone does not read (a
#   worktree, a `--git-dir` elsewhere), and git silently ignores a hook that is
#   not executable. So this reads the outcome back out of git and checks the
#   three things that have to be true for a commit to actually be checked:
#   the key resolves to .githooks, the hook file is there, and it is executable.
#
# WHY NO CI GUARD
#   The template skips when $CI is set, because npm runs it on every install,
#   including in CI where hooks are pointless. Nothing runs this automatically
#   here - there is no lifecycle to hook into - so the only thing a CI guard
#   would do is make the fixtures suite silently test nothing when it runs in
#   CI, which is the defect this whole issue is about.
#
# USAGE
#   bash scripts/install-git-hooks.sh              # install and verify
#   bash scripts/install-git-hooks.sh --check      # report, change nothing
#   bash scripts/install-git-hooks.sh --uninstall  # unset core.hooksPath
#   bash scripts/install-git-hooks.sh --verbose    # trace every git command
#
# EXIT CODES
#   0  hooks are installed (or, with --uninstall, removed)
#   1  the install ran but the outcome is wrong
#   2  could not run: not a git repository, or misuse

set -uo pipefail

HOOKS_DIR=".githooks"
HOOK_NAME="pre-commit"
MODE=install

while [ $# -gt 0 ]; do
  case "$1" in
    --check)
      MODE=check
      shift
      ;;
    --uninstall)
      MODE=uninstall
      shift
      ;;
    --verbose | -v)
      set -x
      shift
      ;;
    -h | --help)
      sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "::error title=install-git-hooks::unknown option '$1' (try --help)" >&2
      exit 2
      ;;
  esac
done

if [ "${BOX_VERBOSE:-0}" = "1" ]; then
  set -x
fi

if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "::error title=install-git-hooks::not inside a git repository" >&2
  exit 2
fi

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || exit 2

report_state() {
  local configured
  configured="$(git config --get core.hooksPath 2>/dev/null || true)"
  if [ -z "$configured" ]; then
    echo "core.hooksPath is unset; this clone runs .git/hooks (git's default)"
  else
    echo "core.hooksPath = $configured"
  fi
}

if [ "$MODE" = "uninstall" ]; then
  git config --unset core.hooksPath 2>/dev/null || true
  if [ -n "$(git config --get core.hooksPath 2>/dev/null || true)" ]; then
    echo "::error title=install-git-hooks::core.hooksPath is still set after --uninstall" >&2
    report_state
    exit 1
  fi
  echo "==> Removed: $(report_state)"
  exit 0
fi

if [ "$MODE" = "check" ]; then
  CONFIGURED="$(git config --get core.hooksPath 2>/dev/null || true)"
  if [ "$CONFIGURED" != "$HOOKS_DIR" ]; then
    echo "==> Hooks are NOT installed. $(report_state)"
    echo "    Install them with: bash scripts/install-git-hooks.sh"
    exit 1
  fi
  if [ ! -x "$HOOKS_DIR/$HOOK_NAME" ]; then
    echo "::error title=install-git-hooks::core.hooksPath names $HOOKS_DIR but $HOOKS_DIR/$HOOK_NAME is missing or not executable, so git runs nothing" >&2
    exit 1
  fi
  echo "==> Hooks are installed: $(report_state)"
  exit 0
fi

# --- install ------------------------------------------------------------------

if [ ! -f "$HOOKS_DIR/$HOOK_NAME" ]; then
  echo "::error title=install-git-hooks::$HOOKS_DIR/$HOOK_NAME does not exist; nothing to install" >&2
  exit 2
fi

# Setting core.hooksPath makes git stop reading .git/hooks entirely. A hook
# somebody wrote by hand there would go quiet with no message at all, so say so
# rather than take it away silently. Samples are git's own and are inert.
EXISTING_LOCAL=()
if [ -d .git/hooks ]; then
  while IFS= read -r hook; do
    [ -n "$hook" ] && EXISTING_LOCAL+=("$hook")
    # `-printf` is a GNU extension and this script runs on developers'
    # machines, macOS included; sed off the directory instead.
  done < <(find .git/hooks -maxdepth 1 -type f ! -name '*.sample' 2>/dev/null | sed 's#.*/##' | sort)
fi
if [ "${#EXISTING_LOCAL[@]}" -gt 0 ]; then
  echo "::warning title=install-git-hooks::.git/hooks holds ${EXISTING_LOCAL[*]}; core.hooksPath makes git ignore that directory"
fi

PREVIOUS="$(git config --get core.hooksPath 2>/dev/null || true)"
if [ -n "$PREVIOUS" ] && [ "$PREVIOUS" != "$HOOKS_DIR" ]; then
  echo "==> Replacing core.hooksPath ($PREVIOUS -> $HOOKS_DIR)"
fi

# --local, explicitly: a bare `git config` writes to the local file today, but
# saying which file is being written removes the question entirely, and a
# global write here would install this repository's hooks into every clone on
# the machine.
if ! git config --local core.hooksPath "$HOOKS_DIR"; then
  echo "::error title=install-git-hooks::git config --local core.hooksPath failed" >&2
  exit 1
fi

chmod +x "$HOOKS_DIR/$HOOK_NAME" 2>/dev/null || true

# --- verification: the outcome, not the exit code -----------------------------
#
# `git config --get` exits 1 when the key is unset, which is exactly the case
# this is here to catch, so || true and then compare the value.
CONFIGURED="$(git config --get core.hooksPath 2>/dev/null || true)"

if [ "$CONFIGURED" != "$HOOKS_DIR" ]; then
  echo "::error title=install-git-hooks::git hooks were not installed: core.hooksPath reads '${CONFIGURED:-<unset>}', expected '$HOOKS_DIR'" >&2
  exit 1
fi

if [ ! -x "$HOOKS_DIR/$HOOK_NAME" ]; then
  echo "::error title=install-git-hooks::$HOOKS_DIR/$HOOK_NAME is not executable; git skips a hook it cannot run, without a message" >&2
  exit 1
fi

echo "==> Installed: core.hooksPath = $CONFIGURED ($HOOKS_DIR/$HOOK_NAME is executable)"
echo "    Every commit now runs: bash scripts/ci/run-precommit-checks.sh"
echo "    Bypass once with 'git commit --no-verify', or a session with BOX_SKIP_HOOKS=1."
echo "    Undo with: bash scripts/install-git-hooks.sh --uninstall"
