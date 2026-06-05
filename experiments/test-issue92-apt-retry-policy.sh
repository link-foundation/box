#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

ruby <<'RUBY'
checks = []

common = File.read("ubuntu/24.04/common.sh")
dind_install = File.read("ubuntu/24.04/dind/install.sh")
essentials_install = File.read("ubuntu/24.04/essentials-box/install.sh")
full_install = File.read("ubuntu/24.04/full-box/install.sh")
php_install = File.read("ubuntu/24.04/php/install.sh")
measure_script = File.read("scripts/measure-disk-space.sh")
server_install = File.read("scripts/ubuntu-24-server-install.sh")
measure_workflow = File.read(".github/workflows/measure-disk-space.yml")

unless common.include?("apt_update_with_retry()")
  checks << "common.sh must define apt_update_with_retry"
end

unless common.include?("Acquire::Retries")
  checks << "apt_update_with_retry must use apt's Acquire::Retries option"
end

unless common.include?("/var/lib/apt/lists")
  checks << "apt_update_with_retry must clean apt list state between failed attempts"
end

unless dind_install.include?('elif [ -f "/tmp/common.sh" ]; then')
  checks << "dind install must source /tmp/common.sh when copied into Docker builds"
end

Dir["ubuntu/24.04/*/install.sh"].sort.each do |path|
  text = File.read(path)
  next unless text.include?("SCRIPT_DIR=") && text.include?("common.sh")

  unless text.include?('"/tmp/common.sh"')
    checks << "#{path} must source /tmp/common.sh when copied into Docker builds"
  end
end

dind_install.each_line.with_index(1) do |line, number|
  next if line.include?("apt_update_with_retry()")

  if line.match?(/maybe_sudo apt(?:-get)? update -y/)
    checks << "dind install line #{number} must use apt_update_with_retry instead of direct apt update"
  end
end

[
  ["dind install", dind_install],
  ["essentials install", essentials_install],
  ["full-box install", full_install],
  ["php apt fallback", php_install],
  ["disk measurement script", measure_script],
  ["server install script", server_install],
].each do |name, text|
  unless text.include?("apt_update_with_retry")
    checks << "#{name} must use apt_update_with_retry"
  end
end

[
  "Dockerfile",
  "ubuntu/24.04/full-box/Dockerfile",
  "ubuntu/24.04/essentials-box/Dockerfile",
  "ubuntu/24.04/js/Dockerfile",
  "ubuntu/24.04/php/Dockerfile",
  "ubuntu/24.04/rocq/Dockerfile",
].each do |path|
  text = File.read(path)
  unless text.include?("apt_update_with_retry")
    checks << "#{path} must use apt_update_with_retry for apt metadata refreshes"
  end

  if text.match?(/apt(?:-get)? update -y/)
    checks << "#{path} must not call apt update directly"
  end
end

unless measure_workflow.include?("apt_update_with_retry")
  checks << "measure-disk-space workflow must use apt_update_with_retry"
end

if measure_workflow.include?("sudo apt-get update")
  checks << "measure-disk-space workflow must not call sudo apt-get update directly"
end

if checks.empty?
  puts "issue 92 apt retry policy checks passed"
else
  warn checks.join("\n")
  exit 1
end
RUBY

source ubuntu/24.04/common.sh

APT_TEST_ATTEMPTS=0
APT_TEST_CLEANUPS=0
APT_TEST_APT_ARGS=""
APT_TEST_RM_ARGS=""

maybe_sudo() {
  case "$1" in
    apt-get)
      APT_TEST_ATTEMPTS=$((APT_TEST_ATTEMPTS + 1))
      APT_TEST_APT_ARGS="$*"
      if [ "$APT_TEST_ATTEMPTS" -eq 1 ]; then
        return 100
      fi
      return 0
      ;;
    rm)
      APT_TEST_CLEANUPS=$((APT_TEST_CLEANUPS + 1))
      APT_TEST_RM_ARGS="$*"
      return 0
      ;;
    *)
      "$@"
      ;;
  esac
}

sleep() {
  :
}

APT_UPDATE_MAX_RETRIES=2 APT_UPDATE_INITIAL_DELAY=0 apt_update_with_retry >/dev/null

if [ "$APT_TEST_ATTEMPTS" -ne 2 ]; then
  echo "apt_update_with_retry should retry once after a failed apt update" >&2
  exit 1
fi

if [ "$APT_TEST_CLEANUPS" -ne 1 ]; then
  echo "apt_update_with_retry should clear apt list state before retrying" >&2
  exit 1
fi

case "$APT_TEST_APT_ARGS" in
  *"Acquire::Retries=3"*) ;;
  *)
    echo "apt_update_with_retry should pass Acquire::Retries=3 to apt-get" >&2
    exit 1
    ;;
esac

case "$APT_TEST_RM_ARGS" in
  *"/var/lib/apt/lists"*) ;;
  *)
    echo "apt_update_with_retry should clean /var/lib/apt/lists state" >&2
    exit 1
    ;;
esac
