#!/usr/bin/env bash
# test-issue121-log-injection.sh
#
# Issue #121: "Check for all false positives, false negatives, warnings and
# errors in CI/CD and fix them all."
#
# The largest false positive was 56 of them at once. Release run 34293698000+
# (34293699247) finished with every build job green, and the checks API served
# 58 annotations at level "failure" against those same green jobs, path
# ".github", arbitrary line numbers. Nothing had failed.
#
# The chain, each link verified against the source it comes from:
#
#   1. docker/setup-buildx-action boots the docker-container driver. Since
#      buildx v0.30.0 that driver writes the GitHub event payload into the
#      builder container so provenance can record it - driver/docker-container/
#      driver.go, `d.Files["provenance.d/github_actions_context.json"]`, from
#      util/ghutil/ghutil.go which reads GITHUB_EVENT_PATH whole.
#   2. `provenance: false` does not stop it. That flag drops the *attestation
#      attached to the image*; buildx still resolves provenance for
#      `--metadata-file` (commands/build.go: the mode is disabled only when
#      there is no metadata file), and the default `min` mode strips
#      BuildConfig and Metadata only - build/provenance.go - so
#      invocation.environment.github_event_payload survives.
#   3. docker/build-push-action prints that metadata verbatim:
#      `core.info(JSON.stringify(metadata, null, 2))`, src/main.ts.
#   4. The runner matches the legacy `##[command]` form *anywhere* in a line:
#      ActionCommand.TryParse uses `message.IndexOf("##[")`, unlike TryParseV2
#      which requires the `::` form at the start. So any line of that JSON
#      containing `##[error]` becomes an error annotation on the job.
#
# Commit a2e6420 explains a fix for jobs that died with exit code 143, and
# quotes the runner's own messages while doing so. That commit message went
# into the push payload, into the builder, into the provenance, into the log,
# and back out as 56 failures against builds that had all succeeded.
#
# The fix is BUILDX_METADATA_PROVENANCE=disabled: buildx then writes no
# provenance to the metadata file, so there is nothing to print and nothing to
# misread. `provenance: false` stays - the two settings do different jobs and
# neither replaces the other.
#
# What it asserts:
#   Part 1  the runner's parsing rule, which is why `##[` is the vector
#   Part 2  a real metadata dump carries the payload, and the fixed one does not
#   Part 3  every workflow that builds images sets the variable, at job scope
#   Part 4  the attestation is still switched off everywhere it was
#
# The end-to-end reproduction against a real buildx needs Docker and is kept
# separate, in experiments/test-issue121-provenance-metadata-leak.sh.
#
# Usage: bash experiments/test-issue121-log-injection.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

PASS=0
FAIL=0

pass() {
  echo "PASS: $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "FAIL: $1"
  FAIL=$((FAIL + 1))
  [ $# -gt 1 ] && printf '      %s\n' "${@:2}" >&2
  return 0
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The commands the runner answers to, from
# src/Runner.Worker/ActionCommandManager.cs. `stop-commands` is in the list too,
# which is why this is not only about noisy annotations: a line the runner reads
# can also switch command processing off for the rest of the step.
REGISTERED='set-env set-output save-state add-mask add-path add-matcher remove-matcher debug warning error notice group endgroup echo stop-commands internal-set-repo-path'

# parses_v1 - would the runner read this line as a legacy `##[command]`?
# Modelled on ActionCommand.TryParse: IndexOf("##["), then the first ']' after
# it, then the first word of what is between them, then the registered list.
parses_v1() {
  local line="$1" after cmdinfo name
  case "$line" in
    *'##['*) after="${line#*##[}" ;;
    *) return 1 ;;
  esac
  case "$after" in
    *']'*) cmdinfo="${after%%]*}" ;;
    *) return 1 ;;
  esac
  name="${cmdinfo%% *}"
  case " $REGISTERED " in
    *" $name "*) return 0 ;;
    *) return 1 ;;
  esac
}

# parses_v2 - the modern `::command::` form. ActionCommand.TryParseV2 trims
# leading whitespace and then requires StartsWith("::"), so this one cannot be
# reached from the middle of a line.
parses_v2() {
  local line="$1" trimmed
  trimmed="${line#"${line%%[![:space:]]*}"}"
  case "$trimmed" in
    '::'*'::'*) ;;
    *) return 1 ;;
  esac
  local rest name
  rest="${trimmed#::}"
  name="${rest%%::*}"
  name="${name%% *}"
  case " $REGISTERED " in
    *" $name "*) return 0 ;;
    *) return 1 ;;
  esac
}

echo "=== Part 1: why '##[' is the vector and '::' is not ==="

# This is the exact shape of the line that produced the 56 annotations: a JSON
# string value, indented, with the commit body's newlines escaped, so the whole
# commit message is one physical line of log.
INJECTED='              "message": "ci: spend the idle disk (issue #119)\n\n##[error]Process completed with exit code 143.\n  ##[error]The runner has received a shutdown signal.\n\nrest of the body"'

if parses_v1 "$INJECTED"; then
  pass "a commit message quoting ##[error] is read as a command from the middle of a line"
else
  fail "a commit message quoting ##[error] is read as a command from the middle of a line"
fi

SAFE='              "message": "ci: quote the modern form ::error::something instead"'
if ! parses_v2 "$SAFE" && ! parses_v1 "$SAFE"; then
  pass "the same message written with the ::error:: form is not a command mid-line"
else
  fail "the same message written with the ::error:: form is not a command mid-line"
fi

if parses_v2 '::error::a step that means it starts the line'; then
  pass "the ::error:: form still works where a step actually writes it"
else
  fail "the ::error:: form still works where a step actually writes it"
fi

if parses_v1 '              "message": "release: ##[stop-commands]abc, and nothing after me is read"'; then
  pass "the vector is not only annotations: ##[stop-commands] is registered too"
else
  fail "the vector is not only annotations: ##[stop-commands] is registered too"
fi

if ! parses_v1 '              "message": "mentions ##[something-else] which is not a command"'; then
  pass "an unregistered name in brackets is left alone"
else
  fail "an unregistered name in brackets is left alone"
fi

echo
echo "=== Part 2: what the build step prints ==="

# Recorded from `docker buildx build --provenance=false --metadata-file` against
# buildx v0.34.1 with GITHUB_ACTIONS/GITHUB_EVENT_NAME/GITHUB_EVENT_PATH set,
# pretty-printed the way docker/build-push-action prints it. The full artifacts
# are in dev/log/issues/121/pulls/122/probes/provenance-injection/.
cat >"$TMP/metadata-default.txt" <<'FIXTURE'
{
  "buildx.build.provenance": {
    "builder": {
      "id": ""
    },
    "buildType": "https://mobyproject.org/buildkit@v1",
    "invocation": {
      "configSource": {
        "entryPoint": "Dockerfile"
      },
      "environment": {
        "dockerfileVersion": "1.26.0",
        "github_event_name": "push",
        "github_event_payload": {
          "after": "deadbeef",
          "commits": [
            {
              "id": "a2e6420",
              "message": "ci: spend the idle disk (issue #119)\n\n##[error]Process completed with exit code 143.\n  ##[error]The runner has received a shutdown signal.\n\nrest of the body"
            }
          ],
          "repository": {
            "full_name": "link-foundation/box"
          }
        },
        "platform": "linux/amd64"
      }
    }
  },
  "buildx.build.ref": "provrepro/provrepro0/06gawqty97i5gmz6onef8xju9"
}
FIXTURE

# Same build, same event, BUILDX_METADATA_PROVENANCE=disabled.
cat >"$TMP/metadata-disabled.txt" <<'FIXTURE'
{
  "buildx.build.ref": "provrepro/provrepro0/vd9k3wq1sb7uxplm2ohcz4e6t"
}
FIXTURE

count_commands() {
  local file="$1" n=0 line
  while IFS= read -r line; do
    if parses_v1 "$line" || parses_v2 "$line"; then
      n=$((n + 1))
    fi
  done <"$file"
  printf '%s\n' "$n"
}

DEFAULT_HITS="$(count_commands "$TMP/metadata-default.txt")"
DISABLED_HITS="$(count_commands "$TMP/metadata-disabled.txt")"

if [ "$DEFAULT_HITS" -ge 1 ]; then
  pass "the default metadata dump hands the runner $DEFAULT_HITS command(s) it never meant to receive"
else
  fail "the default metadata dump hands the runner a command it never meant to receive" \
    "the fixture stopped reproducing the defect, so Part 2 checks nothing"
fi

if [ "$DISABLED_HITS" -eq 0 ]; then
  pass "with BUILDX_METADATA_PROVENANCE=disabled there is nothing left to misread"
else
  fail "with BUILDX_METADATA_PROVENANCE=disabled there is nothing left to misread" \
    "found $DISABLED_HITS command(s)"
fi

if ! grep -q 'github_event_payload' "$TMP/metadata-disabled.txt"; then
  pass "and the push event payload is not printed into a public build log either"
else
  fail "and the push event payload is not printed into a public build log either"
fi

echo
echo "=== Part 3: every workflow that builds sets it ==="

mapfile -t BUILD_WORKFLOWS < <(
  grep -lE 'docker/build-push-action|buildx-retry\.sh|docker buildx build' .github/workflows/*.yml | sort
)

if [ "${#BUILD_WORKFLOWS[@]}" -eq 0 ]; then
  fail "at least one workflow builds container images" \
    "the discovery pattern matched nothing, so Part 3 checks nothing"
else
  pass "found ${#BUILD_WORKFLOWS[@]} workflow(s) that build container images"
fi

for wf in "${BUILD_WORKFLOWS[@]}"; do
  base="$(basename "$wf")"
  if grep -qE '^\s*BUILDX_METADATA_PROVENANCE:\s*(disabled|"disabled"|false|0)\s*$' "$wf"; then
    pass "$base sets BUILDX_METADATA_PROVENANCE"
  else
    fail "$base sets BUILDX_METADATA_PROVENANCE" \
      "a build step here would print the push event payload into the log"
  fi

  # At workflow scope, so a job added later inherits it instead of being the one
  # job whose log can be written by whoever wrote the last commit message.
  if awk '/^env:/{ineny=1;next} ineny && /^[^[:space:]]/{ineny=0} ineny && /BUILDX_METADATA_PROVENANCE/{found=1} END{exit !found}' "$wf"; then
    pass "$base sets it at workflow scope, so every job inherits it"
  else
    fail "$base sets it at workflow scope, so every job inherits it" \
      "found only inside a job or a step; the next build step added will miss it"
  fi
done

echo
echo "=== Part 4: the attestation is still off ==="

# BUILDX_METADATA_PROVENANCE only governs the metadata file. Dropping
# `provenance: false` because "provenance is disabled now" would start attaching
# attestations to published images again and turn every single-platform tag into
# a two-manifest index - issue #119's regression, arriving by a different door.
# `provenance: false` is written with a trailing comment in release-full.yml, so
# an anchored `$` here would report a workflow as unprotected when it is not -
# a false negative about a false positive, which is the whole subject of #121.
count_matches() {
  grep -chE -e "$1" .github/workflows/*.yml | awk '{s+=$1} END{print s+0}'
}

BUILD_STEPS="$(count_matches 'uses: docker/build-push-action')"
PROVENANCE_FALSE="$(count_matches '^[[:space:]]*provenance:[[:space:]]*false[[:space:]]*(#.*)?$')"
if [ "$BUILD_STEPS" -gt 0 ] && [ "$PROVENANCE_FALSE" -ge "$BUILD_STEPS" ]; then
  pass "all $BUILD_STEPS build-push-action step(s) still carry provenance: false"
else
  fail "all $BUILD_STEPS build-push-action step(s) still carry provenance: false" \
    "provenance: false appears $PROVENANCE_FALSE time(s)"
fi

RETRY_CALLS="$(count_matches 'buildx-retry\.sh')"
RETRY_NO_PROV="$(count_matches '--provenance=false')"
if [ "$RETRY_CALLS" -gt 0 ] && [ "$RETRY_NO_PROV" -ge "$RETRY_CALLS" ]; then
  pass "all $RETRY_CALLS buildx-retry.sh call(s) still pass --provenance=false"
else
  fail "all $RETRY_CALLS buildx-retry.sh call(s) still pass --provenance=false" \
    "--provenance=false appears $RETRY_NO_PROV time(s)"
fi

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
