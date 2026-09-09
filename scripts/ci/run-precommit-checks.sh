#!/usr/bin/env bash
#
# run-precommit-checks.sh — run this repository's own gates over the content a
# commit is about to record.
#
# Issue #121, hive-mind best practice #8 ("local quality gates prevent broken
# commits from reaching CI": format, lint, file size, secrets). The reference
# templates get this from husky + lint-staged, which is a package.json
# lifecycle this repository does not have — it is Dockerfiles and shell, with
# no npm project at its root. So the same guarantee is built from git alone.
#
# WHAT IT CHECKS, AND WHY THE INDEX AND NOT THE WORKING TREE
#   `git commit` records the index, not the working tree, and the two differ
#   more often than it feels like they do: `git add -p`, a fix made after
#   staging, a file edited while the editor waits. A hook that reads the
#   working tree therefore answers a question nobody asked — it can pass on a
#   commit that breaks CI (the fix is unstaged) and fail on a commit that is
#   fine (the breakage is unstaged). Both are false results, which is the
#   defect class issue #121 is about, so this builds a throwaway mirror of the
#   index with `git checkout-index` and runs the gates inside it. Measured on
#   this repository: 1.4 s for 658 files.
#
#   lint-staged solves the same problem by stashing unstaged changes in the
#   real worktree. A mirror was chosen instead because a crash mid-run leaves
#   nothing to recover: the developer's tree is never touched.
#
#   The mirror is a full copy of the index, including dev/log/. That directory
#   is where downloaded CI logs land, which is exactly where a token pasted by
#   accident would land, so the secret scan must be able to see it.
#
#   Gates are scoped by what is staged — shellcheck runs when a shell script is
#   staged, and a commit touching only markdown does not pay for it — with two
#   exceptions that run whenever anything is staged, because both answer a
#   question about the whole tree rather than about one file: the file-size
#   limit and, for the staged paths, the secret scan.
#
# WHAT IT DOES NOT DO
#   It does not rewrite files. lint-staged runs `prettier --write` and re-adds
#   the result; a hook that edits the content of a commit after the author has
#   read it is a surprise, and `git commit` would then record something nobody
#   reviewed. Formatting failures print the command that fixes them.
#
#   It does not run the slow gates: actionlint, zizmor, hadolint, the link
#   check, the experiment suites and the image builds all stay in CI. This is
#   an accelerator, not the authority.
#
#   A gate that cannot run here — no docker, no node, no network for `npx` —
#   is reported as `could not run` and does not block the commit. Every gate
#   this script runs is also run by a workflow on the same content
#   (experiments/test-issue121-git-hooks.sh asserts that pairing, so the hook
#   can never become the only place a check exists), and blocking somebody's
#   commit because their docker daemon is down would be a false positive with
#   no defect behind it. A gate that runs and fails does block.
#
# USAGE
#   bash scripts/ci/run-precommit-checks.sh              # the staged content
#   bash scripts/ci/run-precommit-checks.sh --worktree   # the tree as it is
#   bash scripts/ci/run-precommit-checks.sh --verbose    # show every gate's output
#
#   Installed as a hook by scripts/install-git-hooks.sh; see docs/LOCAL-CHECKS.md.
#   Bypass once with `git commit --no-verify`, or for a session with
#   BOX_SKIP_HOOKS=1.
#
# EXIT CODES
#   0  every gate that could run passed
#   1  a gate reported a violation in the staged content
#   2  could not run at all (not a git repository, misuse)

set -uo pipefail

VERBOSE="${BOX_VERBOSE:-0}"
SOURCE=index

while [ $# -gt 0 ]; do
  case "$1" in
    --verbose | -v)
      VERBOSE=1
      shift
      ;;
    --worktree)
      SOURCE=worktree
      shift
      ;;
    --index | --staged)
      SOURCE=index
      shift
      ;;
    -h | --help)
      sed -n '2,70p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "::error title=run-precommit-checks::unknown option '$1' (try --help)" >&2
      exit 2
      ;;
  esac
done

if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "::error title=run-precommit-checks::not inside a git repository" >&2
  exit 2
fi

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || exit 2

# --- what is staged -----------------------------------------------------------
#
# --diff-filter=ACMR: added, copied, modified, renamed — the paths that will
# exist in the commit. A deletion has no content to lint, and the checks that
# care about a deletion (a docs/ file removed while a script still points at
# it) are the repo-wide ones below.
#
# The very first commit of a repository has no HEAD to diff against, which is
# not an error here: compare against the empty tree instead. The fixtures build
# repositories from scratch and would otherwise all start with this failing.
STAGED=()
BASE_TREE=HEAD
if ! git rev-parse --verify --quiet HEAD >/dev/null; then
  BASE_TREE="$(git hash-object -t tree /dev/null)"
fi
while IFS= read -r -d '' path; do
  [ -n "$path" ] && STAGED+=("$path")
done < <(git diff --cached --name-only -z --diff-filter=ACMR "$BASE_TREE" 2>/dev/null)

if [ "$SOURCE" = "worktree" ]; then
  # Everything tracked or newly added, which is what the CI gates see.
  STAGED=()
  while IFS= read -r -d '' path; do
    [ -n "$path" ] && STAGED+=("$path")
  done < <(git ls-files -z --cached --others --exclude-standard --deduplicate)
fi

if [ "${#STAGED[@]}" -eq 0 ]; then
  echo "==> Nothing staged; no checks to run"
  exit 0
fi

# --- the tree the gates read --------------------------------------------------
WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

CHECK_ROOT="$ROOT"
if [ "$SOURCE" = "index" ]; then
  WORK="$(mktemp -d)"
  MIRROR="$WORK/index"
  mkdir -p "$MIRROR"

  # checkout-index writes the *index* content of every path in the index, so
  # the mirror is byte-for-byte what `git commit` would record.
  if ! git ls-files -z | git checkout-index -z --stdin --prefix="$MIRROR/" 2>"$WORK/mirror.err"; then
    echo "::error title=run-precommit-checks::could not mirror the index" >&2
    sed 's/^/      /' "$WORK/mirror.err" >&2
    exit 2
  fi

  # The gates discover their inputs with `git ls-files`, so the mirror needs an
  # index of its own. `add -f` because .gitignore excludes `*.log` while the
  # case studies commit CI logs under that name: without the force, ten tracked
  # files would be missing from the mirror's file list and silently unchecked.
  if ! (
    cd "$MIRROR" \
      && git init -q . \
      && git -c core.safecrlf=false add -A -f
  ) >"$WORK/init.err" 2>&1; then
    echo "::error title=run-precommit-checks::could not index the mirror" >&2
    sed 's/^/      /' "$WORK/init.err" >&2
    exit 2
  fi
  CHECK_ROOT="$MIRROR"
fi

# --- scoping ------------------------------------------------------------------
matching() { # matching <glob> ... — staged paths matching any glob
  local path glob
  for path in "${STAGED[@]}"; do
    for glob in "$@"; do
      # shellcheck disable=SC2053  # the right-hand side is a pattern on purpose
      if [[ $path == $glob ]]; then
        printf '%s\n' "$path"
        break
      fi
    done
  done
}

collect() { # collect <variable> <glob> ...
  local -n out="$1"
  shift
  out=()
  local line
  while IFS= read -r line; do
    [ -n "$line" ] && out+=("$line")
  done < <(matching "$@" | grep -v '^dev/log/')
}

# .githooks/* has no extension: git requires a hook to be named exactly
# `pre-commit`, so the shell in it is invisible to every `*.sh` glob in this
# directory. run-shellcheck.sh and run-shfmt.sh were extended to look there.
collect SH_FILES '*.sh' '*.bash' '.githooks/*'
collect JS_FILES '*.mjs' '*.js' '*.cjs'
collect PY_FILES '*.py'
collect WF_FILES '.github/workflows/*.yml' '.github/workflows/*.yaml'
collect TEXT_FILES '*.sh' '*.bash' '*.mjs' '*.js' '*.py' '*.yml' '*.yaml'
collect DOC_FILES '*.md' '*.sh' '.github/*'
collect CI_FILES 'scripts/ci/*'
collect SIZED_FILES '*.sh' '*.md' '*.yml' '*.yaml' '*.mjs' '*.js' '*.cjs' '*.py' '*.rb'

# --- running gates ------------------------------------------------------------
FAILED=()
UNAVAILABLE=()
RAN=0
LOGS="$(mktemp -d)"
trap 'cleanup; rm -rf "$LOGS"' EXIT

gate() { # gate <label> <command...>
  local label="$1"
  shift
  local log="$LOGS/${RAN}.log"
  local start end status ms
  start="$(date +%s%N)"
  (cd "$CHECK_ROOT" && "$@") >"$log" 2>&1
  status=$?
  end="$(date +%s%N)"
  ms=$(((end - start) / 1000000))
  RAN=$((RAN + 1))
  case "$status" in
    0)
      printf '  ok        %-20s %6s ms\n' "$label" "$ms"
      [ "$VERBOSE" = "1" ] && sed 's/^/            /' "$log"
      ;;
    1)
      printf '  FAILED    %-20s %6s ms\n' "$label" "$ms"
      FAILED+=("$label")
      sed 's/^/            /' "$log"
      ;;
    *)
      printf '  could not run: %s (exit %s) — CI will run it\n' "$label" "$status"
      UNAVAILABLE+=("$label")
      sed 's/^/            /' "$log"
      ;;
  esac
  return 0
}

echo "==> Checking ${#STAGED[@]} staged path(s) from the $SOURCE"

if [ "${#SH_FILES[@]}" -gt 0 ]; then
  gate shfmt bash scripts/ci/run-shfmt.sh "${SH_FILES[@]}"
  gate shellcheck bash scripts/ci/run-shellcheck.sh "${SH_FILES[@]}"
  gate heredoc-vars bash scripts/ci/check-heredoc-vars.sh "${SH_FILES[@]}"
fi

if [ "${#TEXT_FILES[@]}" -gt 0 ]; then
  gate awk-portability bash scripts/ci/check-awk-portability.sh "${TEXT_FILES[@]}"
fi

if [ "${#JS_FILES[@]}" -gt 0 ]; then
  gate mjs-syntax bash scripts/ci/check-mjs-syntax.sh "${JS_FILES[@]}"
fi

if [ "${#PY_FILES[@]}" -gt 0 ]; then
  gate py-syntax bash scripts/ci/check-py-syntax.sh "${PY_FILES[@]}"
fi

if [ "${#WF_FILES[@]}" -gt 0 ]; then
  # Every workflow, not only the staged ones: both checkers derive their
  # requirement from the file they are reading, and CI runs them over the whole
  # directory. Listed from the tree under check so the two agree, and because a
  # glob would expand in this directory rather than in the mirror.
  ALL_WORKFLOWS=()
  while IFS= read -r wf; do
    [ -n "$wf" ] && ALL_WORKFLOWS+=("$wf")
  done < <(cd "$CHECK_ROOT" && git ls-files '.github/workflows/*.yml' '.github/workflows/*.yaml')
  if [ "${#ALL_WORKFLOWS[@]}" -gt 0 ]; then
    gate status-gate node scripts/ci/check-status-gate-covers-all-jobs.mjs "${ALL_WORKFLOWS[@]}"
    gate timeout-budgets node scripts/ci/check-timeout-budgets.mjs "${ALL_WORKFLOWS[@]}"
  fi
fi

# Staged workflows or staged checkers, because the two halves of this gate live
# on opposite sides: a `paths:` filter is edited in .github/workflows, and the
# set of files a gate reads is edited in scripts/ci. Either one alone can make
# a check unreachable. It takes no arguments - like the two above, it derives
# its requirement from the whole directory, and CI runs it the same way.
if [ "${#WF_FILES[@]}" -gt 0 ] || [ "${#CI_FILES[@]}" -gt 0 ]; then
  gate path-coverage node scripts/ci/check-workflow-path-coverage.mjs
fi

# Any staged script, not only a workflow: this gate asks whether each
# checkout's persist-credentials matches what its job does, and "what its job
# does" is derived by following the job's run blocks into the scripts they
# call. Adding a `git push` to scripts/release/*.sh changes the answer for a
# job whose workflow file nobody touched.
if [ "${#WF_FILES[@]}" -gt 0 ] || [ "${#SH_FILES[@]}" -gt 0 ] || [ "${#JS_FILES[@]}" -gt 0 ]; then
  gate checkout-credentials node scripts/ci/check-checkout-credentials.mjs
fi

if [ "${#DOC_FILES[@]}" -gt 0 ]; then
  gate required-docs bash scripts/ci/check-required-docs.sh
fi

if [ "${#SIZED_FILES[@]}" -gt 0 ]; then
  gate file-line-limits bash scripts/ci/check-file-line-limits.sh
fi

# Always, on the staged paths. A credential is the one mistake a later commit
# cannot take back — once it is pushed it has to be rotated, not reverted — so
# this is the gate that most deserves to run before the commit exists rather
# than after it is on a branch.
gate secretlint bash scripts/ci/run-secretlint.sh "${STAGED[@]}"

echo "==> $RAN gate(s) ran, ${#FAILED[@]} failed, ${#UNAVAILABLE[@]} could not run"

if [ "${#UNAVAILABLE[@]}" -gt 0 ]; then
  printf '::warning title=run-precommit-checks::%s\n' \
    "could not run locally: ${UNAVAILABLE[*]} — CI runs these on the same content"
fi

if [ "${#FAILED[@]}" -gt 0 ]; then
  echo "::error title=run-precommit-checks::${#FAILED[@]} gate(s) failed on the staged content: ${FAILED[*]}"
  echo "    Formatting is fixable in place: bash scripts/ci/run-shfmt.sh --fix"
  echo "    Commit anyway (the same checks then run in CI): git commit --no-verify"
  exit 1
fi

exit 0
