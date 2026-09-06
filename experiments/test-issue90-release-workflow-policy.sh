#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

# The manifest jobs used to all live in release.yml; the split by image family
# (issue #115, RC-8) put each one in its own release-<family>.yml. The list is
# resolved from the caller's `uses:` graph, so a policy suite cannot end up
# reading a file the jobs have left - which would make every check below pass
# on zero jobs.
# shellcheck disable=SC2046 # deliberate word splitting: one path per argument
ruby - $(bash scripts/ci/list-release-workflows.sh) <<'RUBY'
require "yaml"

release_workflow_paths = ARGV
measure_workflow_path = ".github/workflows/measure-disk-space.yml"

if release_workflow_paths.empty?
  warn "no release workflows to check; the checks below would verify nothing"
  exit 1
end

release_text = release_workflow_paths
  .map { |path| File.read(path, encoding: "UTF-8") }
  .join("\n")
measure_text = File.read(measure_workflow_path, encoding: "UTF-8")

# Pinned versions moved out of the workflows and into composite actions
# (issue #117). A version ban that only reads .github/workflows would stop
# seeing the pins it bans.
composite_action_text = Dir.glob(".github/actions/*/action.yml")
  .sort
  .map { |path| File.read(path, encoding: "UTF-8") }
  .join("\n")

errors = []

DOCKERHUB_LOGIN_ACTION = "docker/login-action@v4"
COMPOSITE_LOGIN_ACTION = "./.github/actions/dockerhub-login"
COMPOSITE_LOGIN_PATH = ".github/actions/dockerhub-login/action.yml"

# The composite action is where the login action is actually pinned now. If it
# stops using the pinned version - or stops existing - every check above would
# still pass, because the calling steps would be unchanged.
if File.exist?(COMPOSITE_LOGIN_PATH)
  composite_text = File.read(COMPOSITE_LOGIN_PATH, encoding: "UTF-8")
  unless composite_text.include?("uses: #{DOCKERHUB_LOGIN_ACTION}")
    errors << "#{COMPOSITE_LOGIN_PATH} must use #{DOCKERHUB_LOGIN_ACTION}"
  end
else
  errors << "#{COMPOSITE_LOGIN_PATH} is missing, but jobs still reference #{COMPOSITE_LOGIN_ACTION}"
end

manifest_jobs = %w[
  js-manifest
  essentials-manifest
  languages-manifest
  docker-manifest
  dind-manifest
]

# One job map across the whole pipeline. Job ids are unique across it (pinned by
# experiments/test-issue115-workflow-split.sh), so which file a job is in does
# not matter here - only that it exists somewhere.
jobs = {}
release_workflow_paths.each do |path|
  workflow = YAML.load(File.read(path, encoding: "UTF-8"), aliases: true)
  (workflow["jobs"] || {}).each { |id, job| jobs[id] = job }
end

missing = manifest_jobs.reject { |job_name| jobs.key?(job_name) }
unless missing.empty?
  warn "missing manifest job(s): #{missing.join(", ")} (searched #{release_workflow_paths.join(", ")})"
  exit 1
end

manifest_jobs.each do |job_name|
  steps = jobs.fetch(job_name).fetch("steps")

  dockerhub_login = steps.find { |step| step.is_a?(Hash) && step["id"] == "dockerhub-login" }
  unless dockerhub_login
    errors << "#{job_name}: missing dockerhub-login step"
  else
    unless dockerhub_login["continue-on-error"] == true
      errors << "#{job_name}: dockerhub-login must use continue-on-error"
    end

    # The 15 copies of this login block became one composite action (issue
    # #117), so the calling step now says `uses: ./.github/actions/...`. The
    # policy is about which login action the pipeline ends up running, not
    # about where the `uses:` line is written, so both spellings are accepted -
    # and when it is the composite action, the pin is checked inside it below.
    unless [DOCKERHUB_LOGIN_ACTION, COMPOSITE_LOGIN_ACTION].include?(dockerhub_login["uses"])
      errors << "#{job_name}: dockerhub-login should use #{DOCKERHUB_LOGIN_ACTION} " \
                "or #{COMPOSITE_LOGIN_ACTION}, found #{dockerhub_login["uses"].inspect}"
    end
  end

  # Issue #115: the ten byte-identical `docker manifest create --amend` blocks
  # were replaced by scripts/release/create-multiarch-manifest.sh. Match both
  # forms - a policy suite that only knows the old spelling passes vacuously on
  # the new one, which is the exact false negative this file exists to prevent.
  manifest_steps = steps.select do |step|
    next false unless step.is_a?(Hash)
    run = step["run"].to_s
    run.include?("docker manifest") || run.include?("create-multiarch-manifest.sh")
  end

  dockerhub_steps = manifest_steps.select do |step|
    step["run"].to_s.include?("DOCKERHUB_IMAGE_NAME")
  end

  ghcr_steps = manifest_steps.select do |step|
    step["run"].to_s.include?("GHCR_REGISTRY") || step["run"].to_s.include?("GHCR_IMAGE_NAME")
  end

  if dockerhub_steps.empty?
    errors << "#{job_name}: missing Docker Hub manifest step"
  end

  if ghcr_steps.empty?
    errors << "#{job_name}: missing GHCR manifest step"
  end

  dockerhub_steps.each do |step|
    if step["run"].to_s.include?("GHCR_REGISTRY") || step["run"].to_s.include?("GHCR_IMAGE_NAME")
      errors << "#{job_name}: #{step["name"]} mixes Docker Hub and GHCR manifest commands"
    end

    unless step["if"] == "steps.dockerhub-login.outcome == 'success'"
      errors << "#{job_name}: #{step["name"]} is not guarded by successful Docker Hub login"
    end

    # Issue #115 RC-3: GHCR is the registry of record (written with the run's
    # own GITHUB_TOKEN, which cannot expire); Docker Hub is a mirror written
    # with a long-lived secret that can. A mirror failure must degrade to a
    # warning, never fail a release whose GHCR side already published.
    next unless step["run"].to_s.include?("create-multiarch-manifest.sh")
    if step.dig("env", "MANIFEST_REQUIRED").to_s != "0"
      errors << "#{job_name}: #{step["name"]} must set MANIFEST_REQUIRED: '0' so an expired Docker Hub token cannot fail the release"
    end
  end

  ghcr_steps.each do |step|
    if step["run"].to_s.include?("DOCKERHUB_IMAGE_NAME")
      errors << "#{job_name}: #{step["name"]} mixes GHCR and Docker Hub manifest commands"
    end

    # The converse of the Docker Hub rule above: the registry of record must
    # stay required, or a failed release would report success.
    next unless step["run"].to_s.include?("create-multiarch-manifest.sh")
    if step.dig("env", "MANIFEST_REQUIRED").to_s == "0"
      errors << "#{job_name}: #{step["name"]} must not make the GHCR manifest optional"
    end
  end

  skip_step = steps.find do |step|
    step.is_a?(Hash) &&
      step["name"].to_s.include?("Skip") &&
      step["name"].to_s.include?("Docker Hub") &&
      step["name"].to_s.include?("manifest")
  end

  unless skip_step && skip_step["if"] == "steps.dockerhub-login.outcome != 'success'"
    errors << "#{job_name}: missing Docker Hub manifest skip warning"
  end
end

forbidden_actions = {
  "actions/checkout@v4" => "actions/checkout@v6",
  "actions/upload-artifact@v4" => "actions/upload-artifact@v7",
  "actions/download-artifact@v4" => "actions/download-artifact@v7",
  "docker/setup-buildx-action@v3" => "docker/setup-buildx-action@v4",
  "docker/login-action@v3" => "docker/login-action@v4",
  "docker/build-push-action@v5" => "docker/build-push-action@v7",
  "docker/metadata-action@v5" => "docker/metadata-action@v6",
}

forbidden_actions.each do |old_action, new_action|
  if release_text.include?(old_action) ||
     measure_text.include?(old_action) ||
     composite_action_text.include?(old_action)
    errors << "found #{old_action}; use #{new_action}"
  end
end

if release_text.match?(/^\s*-\s+name:\s+Check Docker Hub login \(issue #82\)/)
  errors << "Docker Hub warning step name with #82 must be quoted"
end

if errors.empty?
  puts "issue 90 release workflow policy checks passed"
else
  warn errors.join("\n")
  exit 1
end
RUBY
