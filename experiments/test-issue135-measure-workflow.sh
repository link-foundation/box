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
abort 'hosted measurement must remove runner-owned Homebrew' unless named.fetch('Free up disk space').fetch('run').include?('sudo rm -rf /home/linuxbrew/.linuxbrew')
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

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
bash scripts/ci/extract-quoted-heredoc.sh scripts/measure-disk-space.sh EOF_BOX >"$work/generated.sh"
sed -n '/^measure_install() {/,/^}/p; /^install_php() {/,/^}/p; /^install_swift() {/,/^}/p; /^install_lean() {/,/^}/p' "$work/generated.sh" >"$work/functions.sh"
# shellcheck source=/dev/null
source "$work/functions.sh"

log_info() { :; }
log_warning() { :; }
cleanup_for_measurement() { :; }
get_disk_usage_bytes() { printf '0\n'; }
add_measurement() { printf '%s %s\n' "$3" "$4" >>"$work/results"; }
brew() { return 19; }

measurement_failed=0
measure_install PHP Runtime install_php
[[ "$measurement_failed" -eq 1 ]]
[[ "$(cat "$work/results")" == "0 0" ]]
echo 'A failed PHP installation leaves a partial result and sets the failure status.'

export HOME="$work/home"
package=swift-6.3.3-RELEASE-ubuntu24.04
mkdir -p "$work/$package/usr/bin"
printf '#!/bin/sh\nprintf "Swift fixture\\n"\n' >"$work/$package/usr/bin/swift"
chmod +x "$work/$package/usr/bin/swift"
tar -czf "$work/swift.tar.gz" -C "$work" "$package"
uname() { printf 'x86_64\n'; }
remote_file_exists() { [[ "$1" == */"$package.tar.gz" ]]; }
curl() {
  case "$*" in
    *"$package.tar.gz") cat "$work/swift.tar.gz" ;;
    *elan-init.sh*) printf ':\n' ;;
    *) return 22 ;;
  esac
}
[[ "$(SWIFT_CANDIDATES='99.9.9 6.3.3' install_swift)" == 'Swift fixture' ]]
if SWIFT_CANDIDATES='99.9.9' install_swift; then
  echo 'missing Swift tarball passed measurement' >&2
  exit 1
fi
echo 'Swift uses the parent candidates and fails if a matching tarball is missing.'

elan() { [[ "$*" == 'toolchain install stable' ]] && touch "$work/lean-installed"; }
lean() { [[ "$1" == --version && -f "$work/lean-installed" ]]; }
install_lean
echo 'Lean installs the toolchain before reading its version.'
