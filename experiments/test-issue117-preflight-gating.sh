#!/usr/bin/env bash
# test-issue117-preflight-gating.sh
#
# Issue #117. The credential check exists (scripts/release/preflight-credentials.sh,
# pinned by test-issue117-preflight.sh); this suite checks that it is actually
# in front of the expensive work, and stays there.
#
# That wiring cannot be tested by running the pipeline on a pull request: the
# build jobs only run on a push to main or a manual dispatch, and the preflight
# runs in report mode on a pull request precisely so a PR is never blocked by a
# release credential. A job that quietly loses its `needs: [preflight]` would
# therefore be found by the next release, which is the failure mode this whole
# issue is about. So it is asserted structurally, from the parsed YAML.
#
# What it asserts:
#   Part 1  the preflight job exists, starts first, and can prove what it claims
#   Part 2  every job that spends runner minutes or writes a version is gated
#   Part 3  every Docker Hub login goes through one action with an OIDC path
#
# Usage: bash experiments/test-issue117-preflight-gating.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# Ruby ships with the runner image and parses YAML without a pip install, the
# same choice test-issue115-workflow-split.sh and
# test-issue90-release-workflow-policy.sh already make.
ruby <<'RUBY'
require "yaml"

CALLER = ".github/workflows/release.yml"
FAMILIES = %w[
  .github/workflows/release-js.yml
  .github/workflows/release-essentials.yml
  .github/workflows/release-languages.yml
  .github/workflows/release-full.yml
  .github/workflows/release-dind.yml
]
ACTION = ".github/actions/dockerhub-login/action.yml"

$pass = 0
$fail = 0

def check(name)
  ok, detail = yield
  if ok
    puts "PASS: #{name}"
    $pass += 1
  else
    puts "FAIL: #{name}"
    puts "      #{detail}" if detail
    $fail += 1
  end
end

caller_doc = YAML.load_file(CALLER, aliases: true)
jobs = caller_doc["jobs"]

puts "=== Part 1: the preflight job ==="

check("release.yml defines a preflight job") do
  [jobs.key?("preflight"), "jobs: #{jobs.keys.join(', ')}"]
end

preflight = jobs["preflight"] || {}

check("the preflight waits for nothing (it is the first thing the run does)") do
  [!preflight.key?("needs"), "needs: #{preflight['needs'].inspect}"]
end

check("the preflight requests packages: write, so it probes with the scope the builds push with") do
  perms = preflight["permissions"] || {}
  [perms["packages"] == "write", perms.inspect]
end

steps = preflight["steps"] || []
run_blocks = steps.map { |s| s["run"] }.compact.join("\n")

check("the preflight runs preflight-credentials.sh in release mode") do
  [run_blocks.include?("preflight-credentials.sh --mode release"), run_blocks]
end

check("and in report mode for a pull request, which tests code rather than releasing") do
  [run_blocks.include?("preflight-credentials.sh --mode report") &&
     run_blocks.include?("pull_request"), run_blocks]
end

check("the preflight passes both registries' credentials, or it would check nothing") do
  env = steps.map { |s| s["env"] || {} }.reduce({}, :merge)
  missing = %w[GHCR_IMAGE_NAME GITHUB_TOKEN DOCKERHUB_IMAGE_NAME DOCKERHUB_USERNAME DOCKERHUB_TOKEN] -
            env.keys
  [missing.empty?, "missing from env: #{missing.join(', ')}"]
end

puts ""
puts "=== Part 2: everything expensive is behind it ==="

# js/essentials/languages/full/dind burn about forty runner jobs between them;
# create-release publishes the notes; apply-changesets and version-bump write
# the version. 2.5.0 is a version bump with no tag and no release, because the
# bump happened in a run that could not publish (issue #117, point 5).
GATED = %w[js essentials languages full dind create-release apply-changesets version-bump]

GATED.each do |name|
  job = jobs[name]
  check("#{name} needs the preflight") do
    needs = Array(job && job["needs"])
    [needs.include?("preflight"), "needs: #{needs.inspect}"]
  end
  check("#{name} runs only when the preflight succeeded") do
    condition = (job && job["if"]).to_s
    [condition.include?("needs.preflight.result == 'success'"), condition]
  end
end

puts ""
puts "=== Part 3: one Docker Hub login, with a path that needs no stored token ==="

def docker_hub_login_steps(doc)
  (doc["jobs"] || {}).flat_map do |_, job|
    (job["steps"] || []).select do |step|
      with = step["with"] || {}
      "#{step['name']}#{with['registry']}".include?("Docker Hub") ||
        with["registry"].to_s.include?("DOCKERHUB_REGISTRY")
    end
  end
end

FAMILIES.each do |file|
  doc = YAML.load_file(file, aliases: true)
  logins = docker_hub_login_steps(doc).select { |s| s.key?("uses") }

  check("#{File.basename(file)} has Docker Hub logins to check") do
    [logins.size == 3, "found #{logins.size}"]
  end

  check("#{File.basename(file)} logs in to Docker Hub only through the shared action") do
    stray = logins.reject { |s| s["uses"] == "./.github/actions/dockerhub-login" }
    [stray.empty?, stray.map { |s| s["uses"] }.inspect]
  end

  check("#{File.basename(file)} passes the OIDC connection id through, so setting one variable is enough") do
    missing = logins.reject { |s| (s["with"] || {}).key?("oidc-connection-id") }
    [missing.empty?, "#{missing.size} step(s) without oidc-connection-id"]
  end

  check("#{File.basename(file)} still tolerates a Docker Hub login failure (issue #82)") do
    bad = logins.reject { |s| s["continue-on-error"] == true }
    [bad.empty?, "#{bad.size} step(s) without continue-on-error"]
  end
end

action = YAML.load_file(ACTION, aliases: true)
action_steps = action["runs"]["steps"]

check("the action logs in with OIDC when a connection id is configured") do
  step = action_steps.find { |s| (s["env"] || {}).key?("DOCKERHUB_OIDC_CONNECTIONID") }
  [!step.nil? && !(step["with"] || {}).key?("password"),
   "docker/login-action wants the connection id in env and no password at all"]
end

check("the action falls back to the personal access token") do
  step = action_steps.find { |s| (s["with"] || {})["password"].to_s.include?("inputs.password") }
  [!step.nil?, action_steps.map { |s| s["name"] }.inspect]
end

check("a job with no credential at all fails the login instead of skipping it") do
  step = action_steps.find { |s| s["run"].to_s.include?("Docker Hub credential missing") }
  [!step.nil? && step["run"].include?("exit 1"),
   "the caller's `continue-on-error` + outcome check only works if this fails"]
end

check("the OIDC path refuses to run in a job that cannot mint a token") do
  step = action_steps.find { |s| s["run"].to_s.include?("ACTIONS_ID_TOKEN_REQUEST_URL") }
  [!step.nil?, "setting the variable without id-token: write must say so, not fail obscurely"]
end

puts ""
puts "=========================================="
puts "Passed: #{$pass}"
puts "Failed: #{$fail}"
puts "=========================================="
exit($fail.zero? ? 0 : 1)
RUBY
