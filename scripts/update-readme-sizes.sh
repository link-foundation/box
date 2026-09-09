#!/usr/bin/env bash
set -euo pipefail

# Update README with Component Sizes
# This script reads the disk space measurements JSON and updates the README.md
# with a detailed table showing the size of each installed component.
#
# Usage: ./update-readme-sizes.sh [--json-file FILE] [--readme-file FILE]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

JSON_FILE="${JSON_FILE:-$REPO_ROOT/data/disk-space-measurements.json}"
README_FILE="${README_FILE:-$REPO_ROOT/README.md}"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --json-file)
      JSON_FILE="$2"
      shift 2
      ;;
    --readme-file)
      README_FILE="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# Check if JSON file exists
if [[ ! -f "$JSON_FILE" ]]; then
  echo "Error: JSON file not found: $JSON_FILE"
  exit 1
fi

# Check if README file exists
if [[ ! -f "$README_FILE" ]]; then
  echo "Error: README file not found: $README_FILE"
  exit 1
fi

# Both paths are read by the Python below, which runs in a child process: an
# unexported variable would leave it on its own defaults, so `--readme-file`
# would announce one file and rewrite another (issue #121).
export JSON_FILE README_FILE

echo "Reading measurements from: $JSON_FILE"
echo "Updating README at: $README_FILE"

# Render the table into a file of this run's own, not a fixed path under /tmp
# that every invocation on the machine shares (issue #121): with a leftover
# there, this script used to write another run's measurements into the README
# and report success.
TABLE_FILE="$(mktemp "${TMPDIR:-/tmp}/component-sizes.XXXXXX")"
trap 'rm -f "$TABLE_FILE"' EXIT
export TABLE_FILE

# Generate the markdown table using Python
python3 >"$TABLE_FILE" <<'PYTHON_SCRIPT'
import json
import sys
import os

json_file = os.environ['JSON_FILE']

with open(json_file, 'r') as f:
    data = json.load(f)

# Group components by category
categories = {}
for comp in data['components']:
    cat = comp['category']
    if cat not in categories:
        categories[cat] = []
    categories[cat].append(comp)

# Define category order for nice display
category_order = [
    'Runtime',
    'Build Tools',
    'Development Tools',
    'Package Manager',
    'Dependencies',
    'System'
]

# Build the markdown table
lines = []
lines.append("## Component Sizes")
lines.append("")
lines.append(f"_Last updated: {data['generated_at']}_")
lines.append("")
lines.append(f"**Total installation size: {data['total_size_mb']} MB**")
lines.append("")
lines.append("| Component | Category | Size (MB) |")
lines.append("|-----------|----------|-----------|")

# Sort categories by defined order, then alphabetically for any extras
sorted_cats = sorted(categories.keys(),
                     key=lambda x: (category_order.index(x) if x in category_order else len(category_order), x))

for cat in sorted_cats:
    comps = sorted(categories[cat], key=lambda x: x['size_mb'], reverse=True)
    for comp in comps:
        name = comp['name']
        size = comp['size_mb']
        lines.append(f"| {name} | {cat} | {size} |")

lines.append("")
lines.append("_Note: Sizes are measured after cleanup and may vary based on system state and package versions._")

print('\n'.join(lines))
PYTHON_SCRIPT

# One pass writes the README, whichever branch it takes: replace the marked
# section when the markers are there, and put the marked section back when they
# are not. The two used to be separate branches, and the second one read the
# table from a file it wrote three lines later.
python3 <<'PYTHON_UPDATE'
import os
import re

readme_file = os.environ['README_FILE']

with open(os.environ['TABLE_FILE'], 'r') as f:
    table = f.read().strip('\n')

with open(readme_file, 'r') as f:
    content = f.read()

START = '<!-- COMPONENT_SIZES_START -->'
END = '<!-- COMPONENT_SIZES_END -->'
section = f'{START}\n{table}\n\n{END}'

pattern = re.compile(re.escape(START) + '.*?' + re.escape(END), re.DOTALL)

if pattern.search(content):
    # A lambda, so a backslash or a \1 in the measurements is data rather than
    # a replacement-template escape.
    content = pattern.sub(lambda _match: section, content, count=1)
    action = 'Updated'
elif '## License' in content:
    content = content.replace('## License', section + '\n\n## License', 1)
    action = 'Added'
elif '## Documentation' in content:
    content = content.replace('## Documentation', section + '\n\n## Documentation', 1)
    action = 'Added'
else:
    content = content.rstrip('\n') + '\n\n' + section + '\n'
    action = 'Appended'

with open(readme_file, 'w') as f:
    f.write(content)

print(f'{action} the component sizes section in {readme_file}')
PYTHON_UPDATE

echo "README update complete!"
