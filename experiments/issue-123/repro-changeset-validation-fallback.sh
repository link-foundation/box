#!/usr/bin/env bash
# Reproduce: a changeset/changelog check reports success when it could not
# determine what the pull request changed.
#
# Two templates, two shapes, one class:
#   java  validate-changeset.mjs falls back to `git diff --name-only HEAD`,
#         which lists *uncommitted* changes -- always none in CI.
#   rust  check-changelog-fragment.rs has no fallback: its exec() helper returns
#         an empty string when the command fails, and an empty changed-file list
#         is read as "No changed files found" -> exit 0.
#
# The java case in detail:
#
# scripts/validate-changeset.mjs:23-41 asks git which files the pull request
# changed, and falls back to the working tree when that fails:
#
#   const output = execSync(`git diff --name-only origin/${baseBranch}...HEAD`)
#   ... catch { return execSync('git diff --name-only HEAD') ... }
#
# When `origin/<base>` is not a resolvable ref the first command exits 128, so
# the fallback runs -- and the fallback asks a question that is always answered
# "nothing" in CI: `git diff --name-only HEAD` lists *uncommitted* changes, and
# a fresh checkout has none. So `getChangedFiles()` answers `[]`,
# `hasSourceChanges([])` is false, and main() prints
#   "No source code changes detected. Changeset not required."
# and exits 0 -- on a pull request that did change source and did carry a
# malformed changeset.
#
# Latent in the shipped workflow: release.yml's `changeset-check` job checks out
# with `fetch-depth: 0`, which does create `refs/remotes/origin/*`. It bites any
# copy of the template that reduces the fetch depth, and the fallback is dead
# code that reports success either way.
#
# The rust case in detail: scripts/check-changelog-fragment.rs:28-45 defines
#
#   fn exec(command, args) -> String { ... else { eprintln!("Error executing ...");
#                                                 String::new() } }
#
# and :64-78 calls it for `git diff --name-only origin/<base>...HEAD`, treating
# an empty result as "no files changed". main() at :110-113 then prints
# "No changed files found" and exits 0. So a git failure -- a missing
# `origin/<base>`, a shallow clone, no network -- is reported as a clean pull
# request, with the error text on stderr and the job green.
#
# Latent in both shipped workflows: java's `changeset-check` and rust's
# `changelog-check` (release.yml:173-176) check out with `fetch-depth: 0`, which
# does create `refs/remotes/origin/*`. Both bite any copy that reduces the fetch
# depth, and in both the degraded path can only report success.
#
# Usage:
#   bash experiments/issue-123/repro-changeset-validation-fallback.sh [JAVA_DIR] [RUST_DIR]
set -uo pipefail

template="${1:-/tmp/templates/java}"
rust_template="${2:-/tmp/templates/rust}"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

echo "### git's own answer when origin/<base> does not resolve"
(
  mkdir -p "${work}/plain" && cd "${work}/plain" || exit 1
  git init -q . && git config user.email ci@example.invalid && git config user.name CI
  echo base >file.txt && git add -A && git commit -qm baseline
  echo changed >>file.txt && git add -A && git commit -qm change
  echo "  git diff --name-only HEAD~1...HEAD -> $(git diff --name-only HEAD~1...HEAD | tr '\n' ' ')(exit $?)"
  out="$(git diff --name-only origin/main...HEAD 2>&1)"
  echo "  git diff --name-only origin/main...HEAD -> '${out}' (exit $?)"
)

echo
echo "### java: the validator itself, on a pull request with a broken changeset"
[ -d "${template}" ] || {
  echo "  ${template} is not a directory, skipped"
  exit 0
}
cp -r "${template}" "${work}/java"
(
  cd "${work}/java" || exit 1
  rm -rf .git
  find .changeset -maxdepth 1 -name '*.md' ! -name 'README.md' -delete 2>/dev/null
  git init -q . && git config user.email ci@example.invalid && git config user.name CI
  git add -A -f >/dev/null 2>&1 && git commit -qm baseline >/dev/null 2>&1
  git branch -qM main >/dev/null 2>&1
  # A changeset with no front matter at all: the validator's own error case.
  printf 'no front matter, no bump type, not a valid changeset\n' >.changeset/broken.md
  echo fixture >scripts/.injection-fixture.txt
  git add -A -f >/dev/null 2>&1 && git commit -qm "the pull request" >/dev/null 2>&1
)

echo "  -- with no origin/main ref (a shallow or single-branch checkout):"
(cd "${work}/java" && node scripts/validate-changeset.mjs) 2>&1 | sed 's/^/     /'
echo "     exit=${PIPESTATUS[0]}"

echo "  -- with origin/main present, which is the only difference:"
git -C "${work}/java" update-ref refs/remotes/origin/main HEAD~1
(cd "${work}/java" && node scripts/validate-changeset.mjs) 2>&1 | sed 's/^/     /'
echo "     exit=${PIPESTATUS[0]}"

echo
echo "### rust: check-changelog-fragment.rs, same pull request shape"
if [ ! -d "${rust_template}" ]; then
  echo "  ${rust_template} is not a directory, skipped"
elif ! command -v rust-script >/dev/null 2>&1; then
  echo "  rust-script is not installed, skipped"
else
  cp -r "${rust_template}" "${work}/rust"
  (
    cd "${work}/rust" || exit 1
    rm -rf .git
    find changelog.d -maxdepth 1 -name '*.md' ! -name 'README.md' -delete 2>/dev/null
    git init -q . && git config user.email ci@example.invalid && git config user.name CI
    git add -A -f >/dev/null 2>&1 && git commit -qm baseline >/dev/null 2>&1
    git branch -qM main >/dev/null 2>&1
    # A source change and NO changelog fragment: the checker's own failure case.
    echo fixture >scripts/.injection-fixture.txt
    git add -A -f >/dev/null 2>&1 && git commit -qm "the pull request" >/dev/null 2>&1
  )

  echo "  -- with no origin/main ref (a shallow or single-branch checkout):"
  (cd "${work}/rust" && GITHUB_BASE_REF=main rust-script scripts/check-changelog-fragment.rs) 2>&1 \
    | sed 's/^/     /'
  echo "     exit=${PIPESTATUS[0]}"

  echo "  -- with origin/main present, which is the only difference:"
  git -C "${work}/rust" update-ref refs/remotes/origin/main HEAD~1
  (cd "${work}/rust" && GITHUB_BASE_REF=main rust-script scripts/check-changelog-fragment.rs) 2>&1 \
    | sed 's/^/     /'
  echo "     exit=${PIPESTATUS[0]}"
fi

echo
echo "### rust: check-version-modification.rs, the same swallow in a second script"
if [ ! -d "${work}/rust" ]; then
  echo "  no rust fixture, skipped"
else
  # The fixture above already has origin/main; drop it to ask the failing question.
  git -C "${work}/rust" update-ref -d refs/remotes/origin/main
  # A manual version bump in Cargo.toml, which is exactly what this script exists
  # to reject.
  (
    cd "${work}/rust" || exit 1
    sed -i 's/^version = ".*"/version = "9.9.9"/' Cargo.toml
    git add -A -f >/dev/null 2>&1 && git commit -qm "bump the version by hand" >/dev/null 2>&1
  )
  echo "  -- with no origin/main ref (a shallow or single-branch checkout):"
  (cd "${work}/rust" && GITHUB_EVENT_NAME=pull_request GITHUB_BASE_REF=main \
    rust-script scripts/check-version-modification.rs) 2>&1 | sed 's/^/     /'
  echo "     exit=${PIPESTATUS[0]}"

  echo "  -- with origin/main present, which is the only difference:"
  git -C "${work}/rust" update-ref refs/remotes/origin/main HEAD~1
  (cd "${work}/rust" && GITHUB_EVENT_NAME=pull_request GITHUB_BASE_REF=main \
    rust-script scripts/check-version-modification.rs) 2>&1 | sed 's/^/     /'
  echo "     exit=${PIPESTATUS[0]}"
fi
