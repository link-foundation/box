#!/usr/bin/env bash
# test-issue115-registry-split.sh
#
# Issue #115, root cause RC-3: one `docker buildx build --push` wrote both the
# GHCR and the Docker Hub tags, so an expired DOCKERHUB_TOKEN took down the GHCR
# publish and the `cache-to: type=gha` export with it (main run 33972074755).
# Worse, every downstream job then pulled its base image from Docker Hub only,
# so GHCR was a write-only mirror that nothing could fall back to - the
# "tolerate Docker Hub login failure" handling added for issue #82 could not
# actually keep a release going.
#
# This suite locks in the corrected topology:
#   GHCR is the registry of record (written with the per-run GITHUB_TOKEN, which
#   cannot expire), Docker Hub is a mirror, and every Docker Hub write is guarded
#   on the login outcome so it degrades to a warning instead of a failed release.
#
# Usage: bash experiments/test-issue115-registry-split.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

WORKFLOW=".github/workflows/release.yml"
MIRROR="scripts/release/mirror-to-dockerhub.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { if [ "$1" = "0" ]; then pass "$2"; else fail "$2"; fi; }

echo "== Part 1: build steps push GHCR only =="

# A Docker Hub name on its own line inside a `tags:` block is a direct push.
if grep -nE '^\s+\$\{\{ env\.DOCKERHUB_IMAGE_NAME \}\}' "$WORKFLOW" >/dev/null; then
  fail "no build step lists a Docker Hub tag as a push target"
  grep -nE '^\s+\$\{\{ env\.DOCKERHUB_IMAGE_NAME \}\}' "$WORKFLOW" | sed 's/^/      /' >&2
else
  pass "no build step lists a Docker Hub tag as a push target"
fi

if grep -nE '^\s+--tag \$\{\{ env\.DOCKERHUB_IMAGE_NAME \}\}' "$WORKFLOW" >/dev/null; then
  fail "no buildx-retry invocation passes a Docker Hub --tag"
else
  pass "no buildx-retry invocation passes a Docker Hub --tag"
fi

# docker/metadata-action feeds `tags:`; a Docker Hub entry in `images:` puts the
# Docker Hub names straight back into the coupled push.
ruby -e '
lines = File.read(ARGV[0], encoding: "UTF-8").lines
bad = []
lines.each_with_index do |l, i|
  next unless l =~ /^\s+images:\s*\|?\s*$/
  j = i + 1
  while j < lines.size && lines[j] =~ /^\s+\S/ && lines[j] !~ /^\s+\w[\w-]*:/
    bad << (j + 1) if lines[j].include?("DOCKERHUB_IMAGE_NAME")
    j += 1
  end
end
if bad.empty?
  puts "PASS: docker/metadata-action emits GHCR image names only"
else
  puts "FAIL: docker/metadata-action still emits Docker Hub names (lines #{bad.join(", ")})"
  exit 1
end
' "$WORKFLOW"
check "$?" "metadata-action check completed"

echo ""
echo "== Part 2: base images resolve from GHCR =="

# Every $GITHUB_OUTPUT write that names a base image for a downstream build.
BASE_OUTPUTS=$(grep -cE 'echo "(image|essentials|base_image|\$\{lang\})=\$\{\{ env\.GHCR_REGISTRY \}\}' "$WORKFLOW")
if [ "$BASE_OUTPUTS" -ge 18 ]; then
  pass "all $BASE_OUTPUTS base-image outputs resolve from GHCR"
else
  fail "expected >= 18 GHCR base-image outputs, found $BASE_OUTPUTS"
fi

if grep -nE 'echo "(image|essentials|base_image|\$\{lang\})=\$\{\{ env\.DOCKERHUB_IMAGE_NAME' "$WORKFLOW" >/dev/null; then
  fail "no base-image output resolves from Docker Hub"
  grep -nE 'echo "(image|essentials|base_image|\$\{lang\})=\$\{\{ env\.DOCKERHUB_IMAGE_NAME' "$WORKFLOW" | sed 's/^/      /' >&2
else
  pass "no base-image output resolves from Docker Hub"
fi

echo ""
echo "== Part 3: every Docker Hub write is guarded on the login outcome =="

ruby -e '
lines = File.read(ARGV[0], encoding: "UTF-8").lines
writes = []
lines.each_with_index do |l, i|
  writes << i if l =~ /docker (manifest push|push) \$\{\{ env\.DOCKERHUB_IMAGE_NAME/
  writes << i if l =~ /mirror-to-dockerhub\.sh/
end
unguarded = []
seen = {}
writes.each do |i|
  j = i
  j -= 1 while j > 0 && lines[j] !~ /^      - name: /
  next if seen[j]
  seen[j] = true
  # The guard may sit on an `if:` scalar or inside an `if: |` block.
  window = lines[j, 8].join
  unguarded << lines[j].strip unless window.include?("steps.dockerhub-login.outcome == \x27success\x27")
end
if unguarded.empty?
  puts "PASS: all #{seen.size} Docker Hub write steps are guarded on the login outcome"
else
  puts "FAIL: unguarded Docker Hub write steps:"
  unguarded.each { |s| puts "      #{s}" }
  exit 1
end
' "$WORKFLOW"
check "$?" "Docker Hub guard check completed"

echo ""
echo "== Part 4: every image-building job mirrors what it published =="

ruby -e '
lines = File.read(ARGV[0], encoding: "UTF-8").lines
jobs = {}
current = nil
lines.each do |l|
  current = $1 if l =~ /^  ([a-z][a-z0-9-]*):\s*$/
  (jobs[current] ||= []) << l if current
end
expected = %w[
  build-js-amd64 build-js-arm64
  build-essentials-amd64 build-essentials-arm64
  build-languages-amd64 build-languages-arm64
  docker-build-push docker-build-push-arm64
  build-dind-amd64 build-dind-arm64
]
missing = expected.reject { |j| jobs[j] && jobs[j].any? { |l| l.include?("mirror-to-dockerhub.sh") } }
if missing.empty?
  puts "PASS: all #{expected.size} image-building jobs mirror to Docker Hub"
else
  puts "FAIL: jobs with no Docker Hub mirror step: #{missing.join(", ")}"
  exit 1
end
' "$WORKFLOW"
check "$?" "mirror coverage check completed"

echo ""
echo "== Part 5: the mirror script degrades instead of failing the release =="

STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT
cat > "$STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${DOCKER_STUB_CALLS:?}"
case "${DOCKER_STUB_MODE:-ok}" in
  ok)        echo "created"; exit 0 ;;
  transient) echo "error: failed to do request: unexpected EOF" >&2; exit 1 ;;
  expired)   echo "unauthorized: personal access token is expired" >&2; exit 1 ;;
esac
STUB
chmod +x "$STUB_DIR/docker"

# run_mirror MODE [EXTRA_ENV=VALUE...]
run_mirror() {
  local mode="$1"
  shift
  env "DOCKER_STUB_MODE=$mode" "DOCKER_STUB_CALLS=$STUB_DIR/calls" \
      "PATH=$STUB_DIR:$PATH" MAX_RETRIES=3 INITIAL_DELAY=0 "$@" \
      bash "$MIRROR" ghcr.io/o/r:1.0.0-amd64 o/r:latest-amd64 o/r:1.0.0-amd64 \
      >"$STUB_DIR/out" 2>&1
}

: > "$STUB_DIR/calls"
run_mirror ok
check "$?" "a successful mirror exits 0"
CALLS=$(wc -l < "$STUB_DIR/calls" | tr -d '[:space:]')
if [ "$CALLS" = "1" ]; then pass "a successful mirror runs imagetools once"; else fail "expected 1 imagetools call, got $CALLS"; fi
if grep -q -- '--tag o/r:latest-amd64 --tag o/r:1.0.0-amd64 ghcr.io/o/r:1.0.0-amd64' "$STUB_DIR/calls"; then
  pass "the mirror copies the GHCR ref to every Docker Hub tag"
else
  fail "unexpected imagetools arguments: $(cat "$STUB_DIR/calls")"
fi

: > "$STUB_DIR/calls"
run_mirror expired
check "$?" "a permanent auth failure still exits 0 (GHCR release is already published)"
CALLS=$(wc -l < "$STUB_DIR/calls" | tr -d '[:space:]')
if [ "$CALLS" = "1" ]; then
  pass "a permanent auth failure is not retried"
else
  fail "expected 1 attempt for an expired token, got $CALLS"
fi
if grep -q '::warning title=Docker Hub mirror failed::' "$STUB_DIR/out"; then
  pass "a failed mirror emits a warning annotation"
else
  fail "a failed mirror emits a warning annotation"
fi
if grep -q 'IS published on GHCR' "$STUB_DIR/out"; then
  pass "the warning states that the GHCR release is unaffected"
else
  fail "the warning states that the GHCR release is unaffected"
fi

: > "$STUB_DIR/calls"
run_mirror transient
check "$?" "a transient failure still exits 0"
CALLS=$(wc -l < "$STUB_DIR/calls" | tr -d '[:space:]')
if [ "$CALLS" = "3" ]; then
  pass "a transient failure is retried MAX_RETRIES times"
else
  fail "expected 3 attempts for a transient failure, got $CALLS"
fi

: > "$STUB_DIR/calls"
if run_mirror expired MIRROR_REQUIRED=1; then
  fail "MIRROR_REQUIRED=1 turns a mirror failure into a job failure"
else
  pass "MIRROR_REQUIRED=1 turns a mirror failure into a job failure"
fi
if grep -q '::error title=Docker Hub mirror failed::' "$STUB_DIR/out"; then
  pass "MIRROR_REQUIRED=1 emits an error annotation"
else
  fail "MIRROR_REQUIRED=1 emits an error annotation"
fi

echo ""
echo "=================================================="
echo "passed: $PASS"
echo "failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "All registry-split assertions hold."
