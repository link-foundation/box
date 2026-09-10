#!/usr/bin/env bash
# Reproduce: actions/runner-images writes `APT::Acquire::Retries` to
# /etc/apt/apt.conf.d/80-retries, and apt reads `Acquire::Retries`. The file is
# therefore inert: it names the word without setting the value.
#
# Offline and non-invasive - nothing under /etc/apt is touched. APT_CONFIG names
# an extra configuration file that apt reads during pkgInitConfig, which is the
# same read that pulls in /etc/apt/apt.conf.d, so a file handed to apt this way
# is treated exactly like a file dropped into that directory.
#
# Usage: bash repro-apt-retries-key.sh
set -uo pipefail

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "apt: $(apt-config --version 2>/dev/null || dpkg-query -W -f '${Version}' apt 2>/dev/null)"
echo

# The line runner-images writes, verbatim from
# images/ubuntu/scripts/build/configure-apt.sh:
#   echo "APT::Acquire::Retries \"10\";" > /etc/apt/apt.conf.d/80-retries
printf 'APT::Acquire::Retries "10";\n' >"$WORK/80-retries"

echo "### Case A: the key runner-images writes"
sed "s/^/    /" "$WORK/80-retries"
echo "  apt-config dump Acquire::Retries ->"
APT_CONFIG="$WORK/80-retries" apt-config dump Acquire::Retries 2>&1 | sed 's/^/    /'
echo "  (empty above means apt did not read this setting: the acquire code falls"
echo "   back to _config->FindI(\"Acquire::Retries\", 3), apt-pkg/acquire-item.cc)"
echo "  apt-config dump | grep -i retries ->"
APT_CONFIG="$WORK/80-retries" apt-config dump 2>/dev/null | grep -i retries | sed 's/^/    /'
echo "  so the key is present in apt's configuration space, under a name nothing consults."
echo

echo "### Case B: the key apt reads"
printf 'Acquire::Retries "10";\n' >"$WORK/80-retries-fixed"
sed "s/^/    /" "$WORK/80-retries-fixed"
echo "  apt-config dump Acquire::Retries ->"
APT_CONFIG="$WORK/80-retries-fixed" apt-config dump Acquire::Retries 2>&1 | sed 's/^/    /'
echo

echo "### Case C: what the image actually has in force"
echo "  apt-config dump Acquire::Retries ->"
DUMP="$(apt-config dump Acquire::Retries 2>/dev/null)"
if [ -n "$DUMP" ]; then
  printf '%s\n' "$DUMP" | sed 's/^/    /'
else
  echo "    (nothing: no file sets it here, so apt uses its compiled-in 3)"
fi
echo "  every key matching Retries ->"
KEYS="$(apt-config dump 2>/dev/null | grep -i retries)"
if [ -n "$KEYS" ]; then printf '%s\n' "$KEYS" | sed 's/^/    /'; else echo "    (none)"; fi
echo "  lines mentioning retries under /etc/apt ->"
HITS="$(grep -rnsi retries /etc/apt/apt.conf /etc/apt/apt.conf.d 2>/dev/null | head -40)"
if [ -n "$HITS" ]; then printf '%s\n' "$HITS" | sed 's/^/    /'; else echo "    (none)"; fi
echo
echo "On an ubuntu-24.04 GitHub runner Case C prints Acquire::Retries \"1\" while"
echo "Case A shows the only file naming the word cannot be what set it."
