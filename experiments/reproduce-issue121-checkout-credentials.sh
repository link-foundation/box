#!/usr/bin/env bash
# reproduce-issue121-checkout-credentials.sh
#
# Issue #121. `actions/checkout` writes the job's token into the repository's
# git configuration so the clone can authenticate, and by default it leaves it
# there for the rest of the job. `persist-credentials: false` makes it take the
# credential back out at the end of its own step. Thirty of this repository's
# fifty-five checkouts never said either way, so thirty jobs ran with a
# repository-scoped write token sitting in git's configuration - including the
# two longest-running jobs in the pipeline, which is where it matters most.
#
# Two things this measures, both from evidence already in the repository:
#
#   1. what the credential actually is, reproduced locally with the same three
#      git commands the runner logs show `actions/checkout` issuing;
#   2. how long each job in the downloaded run logs held it, and whether it was
#      handed back at the end of the checkout step or left for `Post job
#      cleanup` - which is the observable difference between the two settings.
#
# And one claim it falsifies: scripts/ci/simulate-fresh-merge.sh states that
# "every checkout in this repository sets persist-credentials: false". That is
# a comment, so nothing checked it, and it is wrong about thirty of them.
#
# Usage: bash experiments/reproduce-issue121-checkout-credentials.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
ROOT="$PWD"

echo "== 1. What actions/checkout leaves behind =="
echo
# The three commands below are transcribed from a real job log in
# dev/log/issues/121/pulls/122/ci-logs/: the runner writes the header into a
# file under RUNNER_TEMP and points the repository at it with an includeIf, so
# `git config --local --list` in the workspace does not show the token but
# every git command in the job still sends it.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# In a subshell with HOME redirected and the system file switched off, because
# this reads back an AUTHORIZATION header under the exact name a real one is
# stored under and the machine running it may well have one. Nothing recovered
# is printed, only compared.
(
  export HOME="$WORK"
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL="$WORK/empty-global"
  : >"$GIT_CONFIG_GLOBAL"
  # And the environment, which is a configuration source of its own - the same
  # one this branch uses to give checkout an init.defaultBranch. A development
  # container may well authenticate git through exactly these three variables,
  # in which case leaving them set would have this section read a real
  # credential instead of its fixture.
  while IFS='=' read -r name _; do
    case "$name" in
      GIT_CONFIG_COUNT | GIT_CONFIG_KEY_* | GIT_CONFIG_VALUE_*) unset "$name" ;;
    esac
  done < <(env)

  FAKE_TOKEN='ghs_ThisIsNotARealTokenItIsAFixture'
  git init --quiet "$WORK/repo"
  git -C "$WORK/repo" remote add origin https://github.com/link-foundation/box

  # Transcribed from a real job log: the header goes into a file under
  # RUNNER_TEMP and the repository is pointed at it with an includeIf, so
  # `git config --local --list` in the workspace never shows the token while
  # every git command in the job still sends it.
  git config --file "$WORK/credentials.config" \
    'http.https://github.com/.extraheader' \
    "AUTHORIZATION: basic $(printf 'x-access-token:%s' "$FAKE_TOKEN" | base64 -w0)"
  git -C "$WORK/repo" config --local \
    "includeIf.gitdir:$WORK/repo/.git.path" "$WORK/credentials.config"

  printf '  the workspace .git/config names only a path:\n'
  grep -E 'includeIf|path =' "$WORK/repo/.git/config" | sed 's/^/    /'

  recover() {
    git -C "$WORK/repo" config --get 'http.https://github.com/.extraheader' 2>/dev/null \
      | sed 's/^[Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]: [Bb]asic //' \
      | base64 -d 2>/dev/null | sed 's/^x-access-token://'
  }

  printf '\n  ...and any later step in the job reads the token back through it:\n'
  if [ "$(recover)" = "$FAKE_TOKEN" ]; then
    printf '    git config --get http.https://github.com/.extraheader | base64 -d  ->  the token\n'
  else
    printf '    could not recover the token; the mechanism above may have changed\n'
  fi

  # What persist-credentials: false does at the end of the checkout step.
  git -C "$WORK/repo" config --local --unset-all "includeIf.gitdir:$WORK/repo/.git.path"
  if [ -z "$(recover)" ]; then
    printf '\n  after the unset persist-credentials: false performs, the same read returns nothing.\n'
  else
    printf '\n  after the unset, the read still returns something; the removal did not take.\n'
  fi
)

echo
echo "== 2. What this repository's workflows declare =="
echo
TOTAL=0
DROPS=0
SILENT=0
SILENT_LIST=()
while IFS= read -r wf; do
  # Each checkout step and the `with:` block that follows it.
  while IFS= read -r line_no; do
    TOTAL=$((TOTAL + 1))
    block="$(sed -n "${line_no},$((line_no + 8))p" "$wf")"
    if printf '%s\n' "$block" | grep -q 'persist-credentials:[[:space:]]*false'; then
      DROPS=$((DROPS + 1))
    else
      SILENT=$((SILENT + 1))
      SILENT_LIST+=("$wf:$line_no")
    fi
  done < <(grep -nE 'uses:[[:space:]]*actions/checkout' "$wf" | cut -d: -f1)
done < <(git ls-files -- '.github/workflows/*.yml' '.github/actions/*/action.yml')

printf '  %d checkout step(s): %d drop the credential, %d keep it by saying nothing.\n' \
  "$TOTAL" "$DROPS" "$SILENT"
printf '\n  The silent ones, by workflow:\n'
printf '%s\n' "${SILENT_LIST[@]}" | cut -d: -f1 | sort | uniq -c | sed 's/^/   /'

echo
CLAIM='Every checkout in this repository sets `persist-credentials: false`'
if grep -qF "$CLAIM" scripts/ci/simulate-fresh-merge.sh; then
  printf '  scripts/ci/simulate-fresh-merge.sh says, in a comment nothing validates:\n'
  printf '    "%s"\n' "$CLAIM"
  printf '  ...which is false for %d of the %d.\n' "$SILENT" "$TOTAL"
else
  printf '  scripts/ci/simulate-fresh-merge.sh no longer carries the claim this measured.\n'
fi

echo
echo "== 3. How long each job in the downloaded logs held it =="
echo
# `Removing HTTP extra header` before `Post job cleanup.` is checkout taking the
# credential back at the end of its own step - persist-credentials: false. The
# same line after it is the runner's post-job hook, which runs whatever the
# setting was: the credential was on disk for everything in between.
python3 - <<'PY'
import datetime
import glob
import gzip
import os
import re

rows = []
for path in sorted(glob.glob('dev/log/issues/121/pulls/122/ci-logs/*.log.gz')):
    jobs = {}
    with gzip.open(path, 'rt', errors='replace') as handle:
        for line in handle:
            match = re.match(r'^(.*?)\t.*?\t(\S+Z) (.*)$', line.rstrip('\n'))
            if not match:
                continue
            job, stamp, body = match.groups()
            jobs.setdefault(job, []).append((stamp, body))

    for job, events in jobs.items():
        written = None
        post = None
        for stamp, body in events:
            if '--file' in body and 'git-credentials-' in body and 'extraheader' in body:
                written = stamp
            elif body.startswith('Post job cleanup'):
                post = stamp
            elif 'Removing HTTP extra header' in body and written:
                seconds = (
                    datetime.datetime.fromisoformat(stamp.replace('Z', '+00:00'))
                    - datetime.datetime.fromisoformat(written.replace('Z', '+00:00'))
                ).total_seconds()
                persisted = bool(post and post > written)
                rows.append((os.path.basename(path), job, seconds, persisted))
                written = None

kept = [row for row in rows if row[3]]
dropped = [row for row in rows if not row[3]]

for name, job, seconds, persisted in rows:
    marker = 'KEPT ' if persisted else '  -  '
    where = 'post-job cleanup' if persisted else 'end of the checkout step'
    print(f'  {marker} {job:44s} {seconds:8.1f}s  handed back at {where}')

print()
print(f'  {len(dropped)} job(s) with persist-credentials: false held it '
      f'{min(r[2] for r in dropped):.1f}-{max(r[2] for r in dropped):.1f}s.')
if kept:
    print(f'  {len(kept)} job(s) without it held it '
          f'{min(r[2] for r in kept):.1f}-{max(r[2] for r in kept):.1f}s:')
    for name, job, seconds, _ in kept:
        print(f'    {job} - {seconds:.0f}s, which is that job from checkout to its last step')
PY

echo
echo "== 4. Why no check reported any of it =="
echo
# zizmor has an audit for exactly this - `artipacked` - and this repository runs
# zizmor on every workflow change. The finding is Low severity, and the gate
# floors at medium, so the audit ran thirty times and was filtered out thirty
# times: a check that cannot fail, in the shape the rest of this issue is about.
GATE="$(grep -A8 'name: zizmor' .github/workflows/workflows.yml \
  | grep -oE -- '--min-(severity|confidence) [a-z]+' | paste -sd', ' -)"
printf '  workflows.yml runs zizmor with: %s\n' "${GATE:-<not found>}"
printf '  artipacked reports at severity Low, confidence Low, so that floor hides all %d.\n' "$SILENT"

if command -v docker >/dev/null 2>&1; then
  echo
  echo '  measured, with the gate settings and then with the severity floor lowered:'
  for floor in medium low; do
    count="$(
      docker run --rm -v "$ROOT:/repo" -w /repo ghcr.io/zizmorcore/zizmor:1.30.0 \
        --min-confidence low --min-severity "$floor" --no-progress --format plain \
        --config .github/zizmor.yml .github/workflows .github/actions 2>&1 \
        | grep -c 'help\[artipacked\]' || true
    )"
    printf '    --min-severity %-6s -> %s artipacked finding(s)\n' "$floor" "$count"
  done
else
  echo '  (docker not available here; skipping the measured zizmor comparison)'
fi

echo
if [ "$SILENT" -gt 0 ]; then
  printf 'Open: %d of %d checkouts leave the job token in git configuration.\n' "$SILENT" "$TOTAL"
else
  printf 'Closed: all %d checkouts state what happens to the job token.\n' "$TOTAL"
fi
