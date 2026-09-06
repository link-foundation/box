#!/usr/bin/env python3
"""Validate data/disk-space-measurements.json.

The check this replaces lived inline in .github/workflows/measure-disk-space.yml
and read:

    if [ "$TOTAL_SIZE" -lt 1000 ] || [ "$COMPONENT_COUNT" -lt 10 ]; then

`total_size_mb` is a JSON number and serialises as a float ("7286.0"), so bash's
integer test never evaluated it: it printed "integer expression expected",
returned 2, and `||` fell through to the component count. The size half of the
gate had therefore never run — a measurement reporting 5 MB with a plausible
component list was accepted as valid and committed to the README (issue #115).

Doing it here also lets the same rules run on a pull request, where the file is
edited by hand, without the three-hour measurement.

Usage:
  python3 scripts/ci/validate-measurements.py [FILE]
                                              [--min-total-mb N]
                                              [--min-components N]
                                              [--verbose]

Exit code 0 = valid; 1 = invalid; 2 = usage error.
"""

import argparse
import json
import sys

DEFAULT_PATH = "data/disk-space-measurements.json"
# A full box installation measures ~7 GB. 1000 MB is a floor, not a target: it
# only has to be high enough that "the install silently did nothing" fails.
DEFAULT_MIN_TOTAL_MB = 1000
DEFAULT_MIN_COMPONENTS = 10

REQUIRED_COMPONENT_KEYS = ("name", "category", "size_mb")


def annotate(level, message, path):
    """Emit a GitHub Actions annotation as well as a plain line."""
    print(f"::{level} file={path}::{message}")


def main(argv):
    parser = argparse.ArgumentParser(add_help=True, description=__doc__)
    parser.add_argument("path", nargs="?", default=DEFAULT_PATH)
    parser.add_argument("--min-total-mb", type=float, default=DEFAULT_MIN_TOTAL_MB)
    parser.add_argument("--min-components", type=int, default=DEFAULT_MIN_COMPONENTS)
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    path = args.path
    errors = []

    def debug(message):
        if args.verbose:
            print(f"[debug] {message}")

    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError:
        annotate("error", f"{path} does not exist", path)
        return 1
    except json.JSONDecodeError as exc:
        annotate("error", f"{path} is not valid JSON: {exc}", path)
        return 1

    if not isinstance(data, dict):
        annotate("error", f"{path} must contain a JSON object", path)
        return 1

    debug(f"top-level keys: {sorted(data)}")

    for key in ("generated_at", "total_size_mb", "components"):
        if key not in data:
            errors.append(f"missing required key '{key}'")

    total = data.get("total_size_mb")
    if not isinstance(total, (int, float)) or isinstance(total, bool):
        errors.append(f"total_size_mb must be a number, got {total!r}")
        total = None
    elif total < args.min_total_mb:
        errors.append(
            f"total_size_mb is {total} MB, below the {args.min_total_mb} MB floor "
            "— the installation probably did not complete"
        )

    components = data.get("components")
    if not isinstance(components, list):
        errors.append(f"components must be a list, got {type(components).__name__}")
        components = []
    elif len(components) < args.min_components:
        errors.append(
            f"only {len(components)} component(s) measured, expected at least "
            f"{args.min_components}"
        )

    summed = 0.0
    for index, component in enumerate(components):
        where = f"components[{index}]"
        if not isinstance(component, dict):
            errors.append(f"{where} must be an object")
            continue
        for key in REQUIRED_COMPONENT_KEYS:
            if key not in component:
                errors.append(f"{where} is missing '{key}'")
        size = component.get("size_mb")
        if not isinstance(size, (int, float)) or isinstance(size, bool):
            errors.append(f"{where}.size_mb must be a number, got {size!r}")
        elif size < 0:
            errors.append(f"{where}.size_mb is negative ({size})")
        else:
            summed += size
        debug(f"{where}: {component.get('name')!r} = {size} MB")

    # The total is reported separately from the per-component numbers, so the
    # two can disagree. A large gap means components went unattributed.
    if total is not None and components and summed > 0:
        drift = abs(total - summed) / max(total, 1.0)
        debug(f"total_size_mb={total}, sum(components)={summed:.1f}, drift={drift:.1%}")
        if drift > 0.5:
            annotate(
                "warning",
                f"total_size_mb ({total}) and the sum of the components "
                f"({summed:.1f}) differ by {drift:.0%}",
                path,
            )

    if errors:
        print(f"{path}: INVALID")
        for error in errors:
            print(f"  - {error}")
            annotate("error", error, path)
        return 1

    print(
        f"{path}: OK — {total} MB total across {len(components)} components "
        f"(generated at {data.get('generated_at')})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
