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
  # download.swift.org answers a missing tarball with a 302 to swift.org/404.html
  # instead of a 404, so a probe that does not follow redirects sees success for
  # every URL. The mock reproduces exactly that: without -L it always succeeds.
  *download.swift.org/*)
    follow=0
    for arg in "$@"; do case "$arg" in -*L*) follow=1 ;; esac; done
    [ "$follow" = "1" ] || exit 0
    case "$url" in
      *-"${MOCK_SWIFT_PLATFORM:-ubuntu24.04}".tar.gz) exit 0 ;;
      *) exit 22 ;;
    esac ;;
  # github_latest_tag reads the redirect target that -w '%{url_effective}' prints
  *github.com/nvm-sh/nvm/releases/latest)
    printf '%s' "https://github.com/nvm-sh/nvm/releases/tag/${MOCK_NVM_TAG:-v0.40.7}" ;;
  *github.com/ocaml/opam/releases/latest)
    printf '%s' "https://github.com/ocaml/opam/releases/tag/${MOCK_OPAM_TAG:-2.5.2}" ;;
  # CRAN publishes one suite per supported codename; MOCK_CRAN_SUITE says which
  # one exists, so the "unsupported codename" path can be exercised too.
  *cloud.r-project.org/bin/linux/ubuntu/*-cran40/Release)
    suite="${url##*/ubuntu/}"; suite="${suite%/Release}"
    [ "$suite" = "${MOCK_CRAN_SUITE:-noble-cran40}" ] || exit 22
    printf 'Origin: CRAN\nSuite: %s\n' "$suite" ;;
  *cloud.r-project.org/bin/linux/ubuntu/marutter_pubkey.asc)
    [ "${MOCK_CRAN_KEY_FAIL:-0}" = "1" ] && exit 22
    printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\nmock\n-----END PGP PUBLIC KEY BLOCK-----\n' ;;
  *) exit 22 ;;
esac
MOCK
chmod +x "$WORK/bin/curl"

# Mock sudo: the functions under test write apt configuration through
# maybe_sudo. Running the real sudo here would create root-owned files in the
# temporary tree (which the test could then neither inspect nor clean up), so
# the mock simply runs the command as the test user.
cat > "$WORK/bin/sudo" <<'MOCK'
#!/usr/bin/env bash
exec "$@"
MOCK
chmod +x "$WORK/bin/sudo"
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

# The Swift installers walk that list and probe each candidate's tarball, which
# only tells them anything if the probe follows redirects (issue #112).
swift_url() { echo "https://download.swift.org/swift-$1-release/$2/swift-$1-RELEASE/swift-$1-RELEASE-$3.tar.gz"; }
check "remote_file_exists accepts a tarball that is published" \
  remote_file_exists "$(swift_url 6.3.3 ubuntu2404 ubuntu24.04)"
if remote_file_exists "$(swift_url 6.3.3 ubuntu2604 ubuntu26.04)"; then
  echo "  FAIL: remote_file_exists accepted a redirect to swift.org/404.html"; fail=$((fail+1))
else
  echo "  PASS: remote_file_exists rejects a redirect to swift.org/404.html"; pass=$((pass+1))
fi
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
rm -rf "$BOX_HOME/.nvm/versions/node/v20.19.5"

# Lean joined the invariant in issue #115: elan keeps every toolchain it has
# ever installed under ~/.elan/toolchains, so a box that installed `stable` and
# then a pinned version would carry both (a Lean toolchain is ~200 MB).
mkdir -p "$BOX_HOME/.elan/toolchains/leanprover--lean4---v4.33.1"
check "one lean toolchain satisfies the invariant" \
  bash -c '. "'"$COMMON"'"; BOX_HOME="'"$BOX_HOME"'" assert_single_runtime_versions >/dev/null 2>&1'
mkdir -p "$BOX_HOME/.elan/toolchains/leanprover--lean4---v4.32.0"
check "two lean toolchains fail the invariant" \
  bash -c '. "'"$COMMON"'"; BOX_HOME="'"$BOX_HOME"'" assert_single_runtime_versions >/dev/null 2>&1 && exit 1; exit 0'
check "the violation names the lean root" \
  bash -c '. "'"$COMMON"'"; out=$(BOX_HOME="'"$BOX_HOME"'" assert_single_runtime_versions 2>&1 || true); case "$out" in *"lean: expected exactly 1 version"*) exit 0 ;; *) exit 1 ;; esac'
rm -rf "$BOX_HOME/.elan"

echo "== Case 8: the .NET channel is intersected with what apt can actually install =="
# Mock apt-cache: APT_CHANNELS lists the dotnet-sdk channels this archive has.
cat > "$WORK/bin/apt-cache" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  policy)
    pkg="$2"
    case "$pkg" in
      dotnet-sdk-*)
        channel="${pkg#dotnet-sdk-}"
        for available in ${APT_CHANNELS:-}; do
          if [ "$available" = "$channel" ]; then
            printf '%s:\n  Installed: (none)\n  Candidate: %s.100-1\n' "$pkg" "$channel"
            exit 0
          fi
        done
        ;;
    esac
    exit 0 ;;
  search)
    for available in ${APT_CHANNELS:-}; do
      echo "dotnet-sdk-$available - .NET $available Software Development Kit"
    done
    exit 0 ;;
esac
exit 0
MOCK
chmod +x "$WORK/bin/apt-cache"

eq "prefers the active LTS channel when apt has it" "10.0" \
  "$(APT_CHANNELS='8.0 9.0 10.0' resolve_dotnet_apt_channel)"
eq "falls back to the newest channel apt actually offers" "8.0" \
  "$(APT_CHANNELS='8.0' resolve_dotnet_apt_channel)"
eq "falls back to the pin when apt offers no dotnet at all" "$DOTNET_CHANNEL_FALLBACK" \
  "$(APT_CHANNELS='' resolve_dotnet_apt_channel)"
check "apt_has_package survives pipefail (no SIGPIPE 141)" \
  bash -c 'set -euo pipefail; . "'"$COMMON"'"; APT_CHANNELS="10.0" apt_has_package dotnet-sdk-10.0'
check "apt_has_package is false for a missing package" \
  bash -c 'set -euo pipefail; . "'"$COMMON"'"; APT_CHANNELS="10.0" apt_has_package dotnet-sdk-99.0 && exit 1; exit 0'

echo "== Case 9: the CRAN repository is added before installing R =="
# Ubuntu freezes r-base at whatever shipped with the release (4.3.3 on 24.04);
# CRAN carries the current R for the same codename. add_cran_repo() is what
# makes `apt-get install r-base` deliver the fresh one (issue #112).
export CRAN_APT_ROOT="$WORK/cran-root"
CRAN_LIST="$CRAN_APT_ROOT/etc/apt/sources.list.d/cran.list"
CRAN_KEY="$CRAN_APT_ROOT/etc/apt/keyrings/cran_ubuntu_key.asc"

check "add_cran_repo succeeds for a supported codename" \
  bash -c 'set -euo pipefail; . "'"$COMMON"'"; CRAN_APT_ROOT="'"$CRAN_APT_ROOT"'" CRAN_UBUNTU_CODENAME=noble add_cran_repo >/dev/null'
check "it writes a signed-by sources entry for that codename" \
  bash -c 'grep -q "signed-by=.*cran_ubuntu_key.asc.*noble-cran40/" "'"$CRAN_LIST"'"'
check "it stores the CRAN signing key" \
  bash -c 'grep -q "BEGIN PGP PUBLIC KEY BLOCK" "'"$CRAN_KEY"'"'
check "a second call is a no-op instead of duplicating the entry" \
  bash -c 'set -euo pipefail; . "'"$COMMON"'"; CRAN_APT_ROOT="'"$CRAN_APT_ROOT"'" CRAN_UBUNTU_CODENAME=noble add_cran_repo >/dev/null; [ "$(wc -l < "'"$CRAN_LIST"'")" -eq 1 ]'

# The failure modes must leave apt exactly as it was: a sources entry pointing at
# a suite whose Release file 404s breaks every later apt-get update in the build.
rm -rf "$WORK/cran-unsupported"
check "an unsupported codename is reported, not configured" \
  bash -c 'set -euo pipefail; . "'"$COMMON"'"; CRAN_APT_ROOT="'"$WORK"'/cran-unsupported" CRAN_UBUNTU_CODENAME=questing add_cran_repo >/dev/null 2>&1 && exit 1; exit 0'
check "no sources entry is left behind for an unsupported codename" \
  bash -c '[ ! -e "'"$WORK"'/cran-unsupported/etc/apt/sources.list.d/cran.list" ]'

rm -rf "$WORK/cran-nokey"
check "a failed key download aborts the repository setup" \
  bash -c 'set -euo pipefail; . "'"$COMMON"'"; MOCK_CRAN_KEY_FAIL=1 CRAN_APT_ROOT="'"$WORK"'/cran-nokey" CRAN_UBUNTU_CODENAME=noble add_cran_repo >/dev/null 2>&1 && exit 1; exit 0'
check "no sources entry is left behind when the key download fails" \
  bash -c '[ ! -e "'"$WORK"'/cran-nokey/etc/apt/sources.list.d/cran.list" ]'
check "no empty keyring is left behind when the key download fails" \
  bash -c '[ ! -e "'"$WORK"'/cran-nokey/etc/apt/keyrings/cran_ubuntu_key.asc" ]'

rm -rf "$WORK/cran-offline"
check "an unreachable CRAN degrades to the distro R instead of failing" \
  bash -c 'set -euo pipefail; . "'"$COMMON"'"; CURL_FAIL=1 CRAN_APT_ROOT="'"$WORK"'/cran-offline" CRAN_UBUNTU_CODENAME=noble add_cran_repo >/dev/null 2>&1 && exit 1; exit 0'
unset CRAN_APT_ROOT

echo
echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
