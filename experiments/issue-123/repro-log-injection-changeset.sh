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
