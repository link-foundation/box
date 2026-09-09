#!/usr/bin/env bash
#
# reproduce-issue121-actionlint-version-gap.sh — the three checks the pinned
# actionlint could not run.
#
# Issue #121. This repository pins actionlint by digest, which is right: a
# mutable tag of a repository we do not control, executed in a job that checks
# out the tree, is arbitrary code execution. But a digest pin also freezes the
# check set, and nothing said which version the digest was. It was v1.7.7,
# released 2025-01-25 — and between that and v1.7.12 upstream added three
# checks that report exactly this issue's subject, a check that cannot fail:
#
#   * `glob`        — a `paths:` filter entry beginning with `./` matches
#                     nothing, so the workflow never starts (v1.7.11, #521).
#                     The same defect scripts/ci/check-workflow-path-coverage.mjs
#                     exists for, one level lower: that gate asks whether the
#                     files a gate reads can start it, and answers correctly
#                     for a dead pattern that is the filter's only entry. When
#                     a dead pattern sits beside a live one, the live sibling
#                     covers the files and the dead entry is invisible to it.
#   * `if-cond`     — `if: false` on a job. The job exists, is listed in the
#                     status gate's needs, and can never report anything
#                     (v1.7.9, extended in v1.7.10).
#   * `runner-label`— a label GitHub has removed (`ubuntu-20.04`,
#                     `windows-2019`, `macos-13`). The job never starts
#                     (v1.7.8 and v1.7.10).
#
# and one it reported for the wrong reason: a YAML merge key `<<`, which
# GitHub Actions ignores outright. v1.7.7 calls it a node-type mismatch —
# true, and not the thing that will bite.
#
# Both parts are measurements, not assertions, and the script exits 0 either
# way. It needs docker and a network: it pulls both images and runs the same
# fixtures through each.
#
# Usage: bash experiments/reproduce-issue121-actionlint-version-gap.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# The digest this repository pinned before issue #121, and the one it pins now.
# Written out rather than read from the workflow so this keeps reproducing the
# comparison after the workflow moves on again.
OLD_DIGEST="sha256:887a259a5a534f3c4f36cb02dca341673c6089431057242cdc931e9f133147e9" # v1.7.7
NEW_DIGEST="sha256:b1934ee5f1c509618f2508e6eb47ee0d3520686341fec936f3b79331f9315667" # v1.7.12

if ! command -v docker >/dev/null 2>&1; then
  echo "SKIP: docker is not available; this comparison runs two pinned actionlint images"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/.github/workflows"

# actionlint locates the project by walking up to a .git directory, and refuses
# to lint anything without one. `mktemp -d` creates the directory 0700 and the
# image does not run as this user, so the mount also has to be readable - the
# failure otherwise is "no project was found", which reads like a missing .git.
git init -q "$WORK" >/dev/null 2>&1
chmod -R a+rX "$WORK"

# One fixture per finding, in separate files on purpose. Put together in one
# workflow, v1.7.7 stops at the merge key it treats as a parse error and never
# reaches the other three — which would make it look as though the version
# difference were smaller than it is.
cat >"$WORK/.github/workflows/a-dead-path-filter.yml" <<'YAML'
name: Dead path filter
on:
  push:
    paths:
      - ./scripts/**
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
      - run: echo hi
YAML

cat >"$WORK/.github/workflows/b-job-that-cannot-run.yml" <<'YAML'
name: Job that cannot run
on: push
permissions:
  contents: read
jobs:
  never:
    runs-on: ubuntu-24.04
    if: false
    steps:
      - run: echo hi
YAML

cat >"$WORK/.github/workflows/c-runner-that-is-gone.yml" <<'YAML'
name: Runner that is gone
on: push
permissions:
  contents: read
jobs:
  gone:
    runs-on: ubuntu-20.04
    steps:
      - run: echo hi
YAML

cat >"$WORK/.github/workflows/d-merge-key.yml" <<'YAML'
name: Merge key
on: push
permissions:
  contents: read
jobs:
  merged:
    runs-on: ubuntu-24.04
    steps:
      - run: echo one
        env: &shared
          A: '1'
      - run: echo two
        env:
          <<: *shared
          B: '2'
YAML

run_actionlint() {
  docker run --rm -v "$WORK:/repo" -w /repo "docker.io/rhysd/actionlint@$1" \
    -no-color -oneline 2>&1
}

echo "=== 1. Four fixtures, two pinned versions ==="
echo ""
echo "  Each file is a workflow GitHub accepts and then does not run as written."
echo ""

for label_digest in "v1.7.7 (pinned before issue #121)|$OLD_DIGEST" "v1.7.12 (pinned now)|$NEW_DIGEST"; do
  label="${label_digest%%|*}"
  digest="${label_digest##*|}"
  echo "  -- $label --"
  output="$(run_actionlint "$digest")"
  if [ -z "$output" ]; then
    echo "     no findings"
  else
    # The runner-label message lists every valid label; keep the rule and the
    # position, drop the catalogue.
    printf '%s\n' "$output" | sed -e 's/\. available labels.*\[runner-label\]/ [runner-label]/' \
      -e 's/\. note: filter pattern syntax.*\[glob\]/ [glob]/' \
      | sed 's/^/     /'
  fi
  count="$(printf '%s' "$output" | grep -c . || true)"
  echo "     -> $count finding(s)"
  echo ""
done

echo "=== 2. The dead pattern the coverage gate cannot see ==="
echo ""
echo '  A `paths:` entry that matches nothing is caught by'
echo "  check-workflow-path-coverage.mjs only when the files it should have"
echo "  matched are left uncovered. Give the dead pattern a live sibling and"
echo "  the gate is satisfied, because some pattern does match:"
echo ""

PROBE="$WORK/probe"
mkdir -p "$PROBE"
# A mirror of this repository, so the gate runs against real workflows rather
# than a fixture that might not resemble them.
tar -cf - --exclude=.git --exclude=dev/log . 2>/dev/null | (mkdir -p "$PROBE" && tar -xf - -C "$PROBE")
(
  cd "$PROBE" || exit 1
  git init -q . >/dev/null 2>&1
  git -c user.email=ci@example.com -c user.name=ci add -A >/dev/null 2>&1

  # Add a dead entry beside the live ones in scripts.yml's pull_request filter.
  python3 - <<'PY'
import re
path = '.github/workflows/scripts.yml'
text = open(path).read()
# The first `paths:` list item, whatever it is, gets a dead twin above it.
text = re.sub(r"(\n( +)paths:\n)(\2  - )", r"\1\2  - ./scripts/ci/**\n\3", text, count=1)
open(path, 'w').write(text)
PY
  git -c user.email=ci@example.com -c user.name=ci add -A >/dev/null 2>&1

  if node scripts/ci/check-workflow-path-coverage.mjs >/dev/null 2>&1; then
    echo "     check-workflow-path-coverage.mjs: exit 0 - the dead entry is invisible to it"
  else
    echo "     check-workflow-path-coverage.mjs: non-zero - it did see the dead entry"
  fi

  old="$(docker run --rm -v "$PWD:/repo" -w /repo "docker.io/rhysd/actionlint@$OLD_DIGEST" \
    -no-color -oneline 2>&1 | grep -c 'glob' || true)"
  new="$(docker run --rm -v "$PWD:/repo" -w /repo "docker.io/rhysd/actionlint@$NEW_DIGEST" \
    -no-color -oneline 2>&1 | grep -c 'glob' || true)"
  echo "     actionlint v1.7.7:  $old glob finding(s)"
  echo "     actionlint v1.7.12: $new glob finding(s)"
)

echo ""
echo "=== 3. What each version says about this repository as it stands ==="
echo ""
for label_digest in "v1.7.7 |$OLD_DIGEST" "v1.7.12|$NEW_DIGEST"; do
  label="${label_digest%%|*}"
  digest="${label_digest##*|}"
  output="$(docker run --rm -v "$PWD:/repo" -w /repo "docker.io/rhysd/actionlint@$digest" \
    -no-color -oneline 2>&1)"
  count="$(printf '%s' "$output" | grep -c . || true)"
  echo "  $label: $count finding(s)"
  [ "$count" -eq 0 ] || printf '%s\n' "$output" | sed 's/^/    /'
done

echo ""
echo "  Both are clean, so the bump costs nothing today. What it buys is the"
echo "  three findings above, which no gate in this repository can make."
