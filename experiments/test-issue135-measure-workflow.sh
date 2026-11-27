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

python3 - <<'PYTHON'
import json
from pathlib import Path
import subprocess
import tempfile

validator = ['python3', 'scripts/ci/validate-measurements.py']
document = json.loads(Path('data/disk-space-measurements.json').read_text())

with tempfile.TemporaryDirectory() as directory:
    path = Path(directory, 'measurement.json')
    for total, sizes, expected in (
        (1000, [100] * 10, None),
        (float('nan'), [100] * 10, 'total_size_mb must be a finite number'),
        (1000, [float('inf')] + [100] * 9, 'components[0].size_mb must be a finite number'),
        (1000, [0] * 10, 'components must add up to a positive finite size'),
    ):
        document['total_size_mb'] = total
        document['components'] = [
            {'name': str(i), 'category': 'test', 'size_mb': size}
            for i, size in enumerate(sizes)
        ]
        path.write_text(json.dumps(document))
        check = subprocess.run([*validator, path], capture_output=True, text=True)
        if expected is None:
            assert check.returncode == 0, check.stdout + check.stderr
        else:
            assert check.returncode == 1 and expected in check.stdout, check.stdout + check.stderr

print('Measurement validator accepts finite data and rejects non-finite or all-zero results.')
PYTHON
