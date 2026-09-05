#!/usr/bin/env bash
# Unit test for the build-time version policy and the one-version-per-language
# invariant added for issue #112 (ubuntu/24.04/common.sh).
#
# The resolvers are the only thing standing between a rebuild and a runtime
# that silently stays on last year's release, so they are tested here without
# building an image and without touching the network: a mock `curl` on PATH
# serves recorded fixtures of the real upstream feeds (recorded 2026-09-05) and
# can be told to fail, which is how the pinned-fallback path is exercised.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON="$SCRIPT_DIR/../ubuntu/24.04/common.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export FIXTURES="$WORK/fixtures"
mkdir -p "$FIXTURES" "$WORK/bin"

# --- Recorded upstream feeds (trimmed to the fields the resolvers read) ---

# nodejs.org/dist/index.json: newest first; LTS lines carry a codename, current
# releases carry "lts":false.
cat > "$FIXTURES/node-index.json" <<'JSON'
[{"version":"v25.1.0","date":"2026-08-20","lts":false,"security":false},{"version":"v24.20.0","date":"2026-08-12","lts":"Krypton","security":false},{"version":"v22.21.1","date":"2026-07-30","lts":"Jod","security":false},{"version":"v20.19.5","date":"2026-05-01","lts":"Iron","security":false}]
JSON

# api.sdkman.io java vendor list: Temurin publishes a non-LTS feature release
# (26) alongside the LTS lines, and versions carry a build suffix (25.0.4+1.1).
cat > "$FIXTURES/sdkman-java.txt" <<'TXT'
================================================================================
 Vendor        | Use | Version      | Dist    | Status     | Identifier
--------------------------------------------------------------------------------
 Temurin        |     | 26.0.2+1.1         | 26.0.2+1.1-tem
                |     | 25.0.4             | 25.0.4-tem
                |     | 21.0.12+1.1        | 21.0.12+1.1-tem
                |     | 17.0.20            | 17.0.20-tem
                |     | 11.0.32+1.1        | 11.0.32+1.1-tem
                |     | 8.0.504+1          | 8.0.504+1-tem
 Zulu           |     | 26.0.2.fx          | 26.0.2.fx-zulu
================================================================================
TXT

# releases-index.json: several channels, only one is active LTS.
cat > "$FIXTURES/dotnet-index.json" <<'JSON'
{
  "releases-index": [
    {
      "channel-version": "11.0",
      "support-phase": "preview",
      "release-type": "sts"
    },
    {
      "channel-version": "10.0",
      "support-phase": "active",
      "release-type": "lts"
    },
    {
      "channel-version": "9.0",
      "support-phase": "maintenance",
      "release-type": "sts"
    },
    {
      "channel-version": "8.0",
      "support-phase": "maintenance",
      "release-type": "lts"
    }
  ]
}
JSON

cat > "$FIXTURES/swift-releases.json" <<'JSON'
[{"name":"6.2.4","tag":"swift-6.2.4-RELEASE","platforms":[{"name":"Ubuntu 24.04"}]},{"name":"6.3","tag":"swift-6.3-RELEASE","platforms":[{"name":"Ubuntu 24.04"}]},{"name":"6.3.1","tag":"swift-6.3.1-RELEASE","platforms":[{"name":"Ubuntu 24.04"}]},{"name":"6.3.2","tag":"swift-6.3.2-RELEASE","platforms":[{"name":"Ubuntu 24.04"}]},{"name":"6.3.3","tag":"swift-6.3.3-RELEASE","platforms":[{"name":"Ubuntu 24.04"}]}]
JSON

# --- Mock curl: serves the fixtures, or fails when CURL_FAIL=1 ---
cat > "$WORK/bin/curl" <<'MOCK'
#!/usr/bin/env bash
url=""
for arg in "$@"; do case "$arg" in http*) url="$arg" ;; esac; done
if [ "${CURL_FAIL:-0}" = "1" ]; then exit 22; fi
case "$url" in
  *nodejs.org/dist/index.json)          cat "$FIXTURES/node-index.json" ;;
  *api.sdkman.io/2/candidates/java/*)   cat "$FIXTURES/sdkman-java.txt" ;;
  *releases-index.json)                 cat "$FIXTURES/dotnet-index.json" ;;
  *swift.org/api/v1/install/releases.json) cat "$FIXTURES/swift-releases.json" ;;
  # github_latest_tag reads the redirect target that -w '%{url_effective}' prints
  *github.com/nvm-sh/nvm/releases/latest)
    printf '%s' "https://github.com/nvm-sh/nvm/releases/tag/${MOCK_NVM_TAG:-v0.40.7}" ;;
  *github.com/ocaml/opam/releases/latest)
    printf '%s' "https://github.com/ocaml/opam/releases/tag/${MOCK_OPAM_TAG:-2.5.2}" ;;
  *) exit 22 ;;
esac
MOCK
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"

# shellcheck disable=SC1090
. "$COMMON"

pass=0; fail=0
check() { # check <description> <condition-cmd...>
  desc="$1"; shift
  if "$@"; then echo "  PASS: $desc"; pass=$((pass+1)); else echo "  FAIL: $desc"; fail=$((fail+1)); fi
}
eq() { # eq <description> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "  PASS: $1"; pass=$((pass+1));
  else echo "  FAIL: $1 (expected '$2', got '$3')"; fail=$((fail+1)); fi
}

echo "== Case 1: resolvers read the upstream feeds =="
eq "node resolves the newest LTS major, not the newest release" "24" "$(resolve_node_lts_major)"
eq "nvm resolves the latest installer tag"                      "v0.40.7" "$(resolve_nvm_version)"
eq "java resolves the newest LTS, skipping non-LTS 26"          "25" "$(resolve_java_lts_major)"
eq "dotnet resolves the active LTS channel"                     "10.0" "$(resolve_dotnet_lts_channel)"
eq "swift resolves newest-first"                                "6.3.3 6.3.2 6.3.1 6.3 6.2.4" "$(resolve_swift_versions | tr '\n' ' ' | sed 's/ $//')"
eq "opam resolves the latest release"                           "2.5.2" "$(resolve_opam_version)"

echo "== Case 2: an unreachable feed degrades to the pinned fallback, never fails the build =="
eq "node falls back"   "$NODE_LTS_FALLBACK"       "$(CURL_FAIL=1 resolve_node_lts_major)"
eq "nvm falls back"    "$NVM_VERSION_FALLBACK"    "$(CURL_FAIL=1 resolve_nvm_version)"
eq "java falls back"   "$JAVA_LTS_FALLBACK"       "$(CURL_FAIL=1 resolve_java_lts_major)"
eq "dotnet falls back" "$DOTNET_CHANNEL_FALLBACK" "$(CURL_FAIL=1 resolve_dotnet_lts_channel)"
eq "swift falls back"  "$SWIFT_VERSION_FALLBACK"  "$(CURL_FAIL=1 resolve_swift_versions)"
eq "opam falls back"   "$OPAM_VERSION_FALLBACK"   "$(CURL_FAIL=1 resolve_opam_version)"
check "resolvers exit 0 even when every feed is down" \
  bash -c 'set -euo pipefail; . "'"$COMMON"'"; CURL_FAIL=1 resolve_node_lts_major >/dev/null'

echo "== Case 3: the pinned fallbacks are not stale relative to the recorded feeds =="
eq "NODE_LTS_FALLBACK matches the feed"       "$(resolve_node_lts_major)"    "$NODE_LTS_FALLBACK"
eq "NVM_VERSION_FALLBACK matches the feed"    "$(resolve_nvm_version)"       "$NVM_VERSION_FALLBACK"
eq "JAVA_LTS_FALLBACK matches the feed"       "$(resolve_java_lts_major)"    "$JAVA_LTS_FALLBACK"
eq "DOTNET_CHANNEL_FALLBACK matches the feed" "$(resolve_dotnet_lts_channel)" "$DOTNET_CHANNEL_FALLBACK"
eq "SWIFT_VERSION_FALLBACK matches the feed"  "$(resolve_swift_versions | head -n1)" "$SWIFT_VERSION_FALLBACK"
eq "OPAM_VERSION_FALLBACK matches the feed"   "$(resolve_opam_version)"      "$OPAM_VERSION_FALLBACK"

echo "== Case 4: an explicit override wins over the feed =="
eq "NODE_VERSION=22 pins node"          "22"   "$(NODE_VERSION=22 resolve_node_lts_major)"
eq "NODE_VERSION=22.14.0 pins the major" "22"  "$(NODE_VERSION=22.14.0 resolve_node_lts_major)"
eq "JAVA_VERSION=21 pins java"          "21"   "$(JAVA_VERSION=21 resolve_java_lts_major)"
eq "DOTNET_CHANNEL=8.0 pins dotnet"     "8.0"  "$(DOTNET_CHANNEL=8.0 resolve_dotnet_lts_channel)"
eq "SWIFT_VERSION=6.0.3 pins swift"     "6.0.3" "$(SWIFT_VERSION=6.0.3 resolve_swift_versions)"
eq "OPAM_VERSION=2.3.0 pins opam"       "2.3.0" "$(OPAM_VERSION=2.3.0 resolve_opam_version)"
eq "NVM_VERSION=v0.40.3 pins nvm"       "v0.40.3" "$(NVM_VERSION=v0.40.3 resolve_nvm_version)"

echo "== Case 5: a malformed feed response is rejected, not installed =="
eq "garbage node feed falls back" "$NODE_LTS_FALLBACK" \
  "$(MOCK_NODE_GARBAGE=1 bash -c 'echo "not json" > "$FIXTURES/node-index.json"; . "'"$COMMON"'"; resolve_node_lts_major')"
eq "malformed nvm tag falls back" "$NVM_VERSION_FALLBACK" "$(MOCK_NVM_TAG=HEAD resolve_nvm_version)"
eq "malformed opam tag falls back" "$OPAM_VERSION_FALLBACK" "$(MOCK_OPAM_TAG=nightly resolve_opam_version)"

echo "== Case 6: Java LTS cadence (8, 11, 17, then every 4th from 21) =="
for major in 8 11 17 21 25 29; do
  check "java $major is LTS" is_java_lts_major "$major"
done
for major in 9 12 18 20 22 23 24 26 27; do
  check "java $major is not LTS" bash -c '. "'"$COMMON"'"; ! is_java_lts_major "'"$major"'"'
done

echo "== Case 7: one-version-per-language-root invariant =="
export BOX_HOME="$WORK/home"
mkdir -p "$BOX_HOME/.nvm/versions/node/v24.20.0" \
         "$BOX_HOME/.rustup/toolchains/1.98.0-x86_64-unknown-linux-gnu" \
         "$BOX_HOME/.pyenv/versions/3.14.2" \
         "$BOX_HOME/.sdkman/candidates/java/25.0.4-tem"
ln -s "$BOX_HOME/.sdkman/candidates/java/25.0.4-tem" "$BOX_HOME/.sdkman/candidates/java/current"
eq "a single node version counts as 1" "1" "$(count_installed_versions "$BOX_HOME/.nvm/versions/node")"
eq "the sdkman 'current' symlink is not counted as a version" "1" \
  "$(count_installed_versions "$BOX_HOME/.sdkman/candidates/java")"
eq "a missing root counts as 0" "0" "$(count_installed_versions "$BOX_HOME/.does-not-exist")"
check "clean tree passes the invariant" assert_single_runtime_versions

# The exact defect from issue #112: a stale 'stable' toolchain carried in by a
# COPY --from a cached rust image, sitting next to the pinned one.
mkdir -p "$BOX_HOME/.rustup/toolchains/stable-x86_64-unknown-linux-gnu"
check "two rust toolchains fail the invariant" \
  bash -c '. "'"$COMMON"'"; BOX_HOME="'"$BOX_HOME"'" assert_single_runtime_versions >/dev/null 2>&1 && exit 1; exit 0'
check "the violation names the offending root" \
  bash -c '. "'"$COMMON"'"; out=$(BOX_HOME="'"$BOX_HOME"'" assert_single_runtime_versions 2>&1 || true); echo "$out" | grep -q "rust: expected exactly 1 version"'
check "--warn reports the violation without failing the build" \
  bash -c '. "'"$COMMON"'"; BOX_HOME="'"$BOX_HOME"'" assert_single_runtime_versions --warn >/dev/null 2>&1'
rmdir "$BOX_HOME/.rustup/toolchains/stable-x86_64-unknown-linux-gnu"

# Two Node versions is the same defect on the JS side (nvm install 20 + 24).
mkdir -p "$BOX_HOME/.nvm/versions/node/v20.19.5"
check "two node versions fail the invariant" \
  bash -c '. "'"$COMMON"'"; BOX_HOME="'"$BOX_HOME"'" assert_single_runtime_versions >/dev/null 2>&1 && exit 1; exit 0'

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
