#!/usr/bin/env python3
"""Render disk-space measurements as a Markdown job summary.

Extracted from the inline python3 heredoc in
.github/workflows/measure-disk-space.yml: as YAML-embedded Python indented
inside a `run:` block it could not be syntax-checked, linted or run locally, and
a KeyError in it produced a workflow failure with no useful message.

Usage:
  python3 scripts/ci/summarize-measurements.py [FILE] >> "$GITHUB_STEP_SUMMARY"
"""

import json
import sys

DEFAULT_PATH = "data/disk-space-measurements.json"


def main(argv):
    path = argv[0] if argv else DEFAULT_PATH
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"Could not read measurements from `{path}`: {exc}")
        return 0

    print(f"**Generated at:** {data.get('generated_at', 'unknown')}")
    print()
    print(f"**Total Installation Size:** {data.get('total_size_mb', 'unknown')} MB")
    print()
    print("### Components by Size")
    print()
    print("| Component | Category | Size (MB) |")
    print("|-----------|----------|-----------|")
    components = sorted(
        data.get("components", []),
        key=lambda c: c.get("size_mb", 0),
        reverse=True,
    )
    for component in components:
        print(
            f"| {component.get('name', '?')} "
            f"| {component.get('category', '?')} "
            f"| {component.get('size_mb', '?')} |"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
