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

echo "Reading measurements from: $JSON_FILE"
echo "Updating README at: $README_FILE"

# Generate the markdown table using Python
MARKDOWN_TABLE=$(
  python3 <<'PYTHON_SCRIPT'
import json
import sys
import os

json_file = os.environ.get('JSON_FILE', 'data/disk-space-measurements.json')

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
)

# Check if the README already has a component sizes section
if grep -q "<!-- COMPONENT_SIZES_START -->" "$README_FILE"; then
  # Replace existing section
  echo "Updating existing component sizes section..."

  # Create temporary file with updated content
  awk '
    /<!-- COMPONENT_SIZES_START -->/ {
      print
      print "'"$(echo "$MARKDOWN_TABLE" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')"'"
      skip = 1
      next
    }
    /<!-- COMPONENT_SIZES_END -->/ {
      skip = 0
    }
    !skip {
      print
    }
  ' "$README_FILE" >"$README_FILE.tmp"

  # Actually, let's use a simpler approach with sed
  # First, let's create the content to insert
  echo "$MARKDOWN_TABLE" >/tmp/markdown_table_content.txt

  # Use Python for reliable replacement
  python3 <<PYTHON_REPLACE
import re
import os

readme_file = os.environ.get('README_FILE', 'README.md')
with open(readme_file, 'r') as f:
    content = f.read()

with open('/tmp/markdown_table_content.txt', 'r') as f:
    table_content = f.read()

# Pattern to match the section between markers
pattern = r'(<!-- COMPONENT_SIZES_START -->).*?(<!-- COMPONENT_SIZES_END -->)'
replacement = r'\1\n' + table_content + r'\n\2'

new_content = re.sub(pattern, replacement, content, flags=re.DOTALL)

with open(readme_file, 'w') as f:
    f.write(new_content)

print(f"Updated {readme_file}")
PYTHON_REPLACE

  rm -f /tmp/markdown_table_content.txt "$README_FILE.tmp"

else
  # Add section before License
  echo "Adding component sizes section..."

  # Find where to insert (before ## License or at end)
  python3 <<PYTHON_INSERT
import os

readme_file = os.environ.get('README_FILE', 'README.md')
with open(readme_file, 'r') as f:
    content = f.read()

with open('/tmp/markdown_table_content.txt', 'r') as f:
    table_content = f.read()

# Create the full section with markers
section = f'''
<!-- COMPONENT_SIZES_START -->
{table_content}
<!-- COMPONENT_SIZES_END -->

'''

# Try to insert before ## License
if '## License' in content:
    content = content.replace('## License', section + '## License')
elif '## Documentation' in content:
    content = content.replace('## Documentation', section + '## Documentation')
else:
    # Append at end
    content = content + '\n' + section

with open(readme_file, 'w') as f:
    f.write(content)

print(f"Added component sizes section to {readme_file}")
PYTHON_INSERT

  echo "$MARKDOWN_TABLE" >/tmp/markdown_table_content.txt

  # Re-run the insert script
  python3 <<PYTHON_INSERT
import os

readme_file = os.environ.get('README_FILE', 'README.md')
with open(readme_file, 'r') as f:
    content = f.read()

with open('/tmp/markdown_table_content.txt', 'r') as f:
    table_content = f.read()

# Create the full section with markers
section = f'''<!-- COMPONENT_SIZES_START -->
{table_content}
<!-- COMPONENT_SIZES_END -->

'''

# Check if markers already exist (from previous partial run)
if '<!-- COMPONENT_SIZES_START -->' in content:
    print("Markers already exist, skipping insert")
else:
    # Try to insert before ## License
    if '## License' in content:
        content = content.replace('## License', section + '## License')
    elif '## Documentation' in content:
        content = content.replace('## Documentation', section + '## Documentation')
    else:
        # Append at end
        content = content + '\n' + section

    with open(readme_file, 'w') as f:
        f.write(content)

    print(f"Added component sizes section to {readme_file}")
PYTHON_INSERT

  rm -f /tmp/markdown_table_content.txt
fi

echo "README update complete!"
