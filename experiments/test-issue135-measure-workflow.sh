#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

ruby -ryaml - <<'RUBY'
workflow = YAML.load_file('.github/workflows/measure-disk-space.yml')
job = workflow.fetch('jobs').fetch('measure-disk-space')
abort 'measurement must wait for the fast checks' unless job.fetch('needs') == 'validate'
steps = job.fetch('steps')
named = steps.to_h { |step| [step['name'], step] }
measure = named.fetch('Run disk space measurement').fetch('run')
abort 'measurement must write and check fresh output' unless measure.include?('--json-output measurement.json') && measure.include?('[ -s measurement.json ]')
validate = named.fetch('Validate measurements')
update = named.fetch('Update README with component sizes')
publish = named.fetch('Commit and push changes')
abort 'validate the fresh result before updating the README' unless steps.index(validate) < steps.index(update) && validate.fetch('run').end_with?('validate-measurements.py measurement.json')
abort 'publication must be main-only' unless publish.fetch('if').include?("github.ref == 'refs/heads/main'")
puts 'Measurement workflow ordering, output isolation, and publication guard passed.'
RUBY
