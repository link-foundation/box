#!/usr/bin/env bash
# Measure what `--force` buys the Playwright install in ubuntu/24.04/js/install.sh.
#
# ubuntu/24.04/js/install.sh:153 ran
#   run_with_retry npm install -g playwright @playwright/test @puppeteer/browsers --no-fund --force
# and every JS build job has printed
#   npm warn using --force Recommended protections disabled.
# since issue #84 (2026-04-06) -- visible in
# docs/case-studies/issue-84/ci-logs/run-24024582176.log:4781. A warning is a
# claim that something is wrong; this measures whether anything is.
#
# npm documents --force as "will force npm to fetch remote resources even if a
# local copy exists on disk" and, per `npm help config`, it makes npm ignore
# engine mismatches, overwrite conflicting bin links, and skip several safety
# checks. Two of those are plausible reasons for the flag to be here:
#
#   1. a bin conflict -- `playwright` and `@playwright/test` both declare a bin
#      named `playwright`, so installing both in one command could collide;
#   2. a retry over a half-installed tree -- run_with_retry re-runs the *same*
#      command after a failure, so the second attempt starts with bins and
#      package directories the first attempt already created.
#
# Both are measured below, because dropping the flag is only safe if the retry
# path survives it. Three cases per image:
#
#   fresh      one install, which is the build's happy path;
#   reinstall  the same install run twice, which is what run_with_retry does;
#   shipped    `npm install -g npm@latest` first, as install.sh:146 does, so the
#              npm under test is the one the image actually ships with.
#
# Needs docker and a network. Usage:
#   bash experiments/issue-123/measure-npm-force.sh [IMAGE ...]
set -uo pipefail

images=("$@")
[ "${#images[@]}" -eq 0 ] && images=("node:22-bookworm" "node:24-bookworm")

PKGS='playwright @playwright/test @puppeteer/browsers'

run_case() {
  local image="$1" scenario="$2" flags="$3" prelude="$4"
  echo "### ${image} :: ${scenario} :: npm install -g ${PKGS} ${flags}"
  docker run --rm "${image}" bash -c "
    set -uo pipefail
    ${prelude}
    echo \"npm \$(npm --version), node \$(node --version)\"
    npm install -g ${PKGS} ${flags} >/tmp/install.log 2>&1
    status=\$?
    tail -6 /tmp/install.log
    echo \"exit=\${status}\"
    # Recorded explicitly rather than left to tail: the warning this whole
    # measurement is about is printed near the *top* of a long install, so a
    # tail window shows it only when the output happens to be short.
    if grep -qF 'using --force' /tmp/install.log; then
      echo \"force-warning: present -- \$(grep -m1 -F 'using --force' /tmp/install.log)\"
    else
      echo 'force-warning: absent'
    fi
    ls -l /usr/local/bin/playwright /usr/local/bin/browsers 2>&1 || true
    playwright --version || echo 'playwright --version FAILED'
    npx --yes @puppeteer/browsers --help >/dev/null 2>&1 && echo '@puppeteer/browsers resolves' || echo '@puppeteer/browsers MISSING'
  " 2>&1 | sed 's/^/  /'
  echo
}

for image in "${images[@]}"; do
  for flags in "--no-fund" "--no-fund --force"; do
    run_case "${image}" "fresh" "${flags}" ':'
    # The retry path: the identical command a second time, over the tree the
    # first one left. `--force` is what overwrites an existing bin link, so if
    # it is load-bearing anywhere it is here.
    run_case "${image}" "reinstall" "${flags}" \
      "npm install -g ${PKGS} --no-fund >/dev/null 2>&1; echo 'prelude: first install exit='\$?"
    # install.sh:146 self-updates npm before this line, so the npm that runs the
    # install is not the one baked into the image.
    run_case "${image}" "shipped" "${flags}" \
      "npm install -g npm@latest --no-fund --silent >/dev/null 2>&1; echo 'prelude: npm@latest exit='\$?"
  done
done
