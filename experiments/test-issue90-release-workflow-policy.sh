#!/usr/bin/env bash

set -euo pipefail

cd "$(dirname "$0")/.."

ruby <<'RUBY'
require "yaml"

release_workflow_path = ".github/workflows/release.yml"
measure_workflow_path = ".github/workflows/measure-disk-space.yml"

release_workflow = YAML.load_file(release_workflow_path)
release_text = File.read(release_workflow_path, encoding: "UTF-8")
measure_text = File.read(measure_workflow_path, encoding: "UTF-8")

errors = []

manifest_jobs = %w[
  js-manifest
  essentials-manifest
  languages-manifest
  docker-manifest
  dind-manifest
]

jobs = release_workflow.fetch("jobs")

manifest_jobs.each do |job_name|
  steps = jobs.fetch(job_name).fetch("steps")

  dockerhub_login = steps.find { |step| step.is_a?(Hash) && step["id"] == "dockerhub-login" }
  unless dockerhub_login
    errors << "#{job_name}: missing dockerhub-login step"
  else
    unless dockerhub_login["continue-on-error"] == true
      errors << "#{job_name}: dockerhub-login must use continue-on-error"
    end

    unless dockerhub_login["uses"] == "docker/login-action@v4"
      errors << "#{job_name}: dockerhub-login should use docker/login-action@v4"
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
  if release_text.include?(old_action) || measure_text.include?(old_action)
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
