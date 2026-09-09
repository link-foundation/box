"""Regression tests for CI change detection."""

from __future__ import annotations

import pytest

from scripts.detect_code_changes import detect_change_types


@pytest.mark.parametrize("event_name", ["pull_request", "push"])
@pytest.mark.parametrize(
    ("file_path", "docs_changed"),
    [
        ("experiments/repro.md", True),
        ("README.md", True),
        ("docs/case-studies/audit.py", True),
        ("changelog.d/20260903_fragment.md", True),
        ("experiments/repro.mjs", False),
        ("dev/log/trace.py", False),
    ],
)
def test_excluded_only_changes_do_not_activate_jobs(
    event_name: str, file_path: str, docs_changed: bool
) -> None:
    """Excluded paths must stay excluded for every automatic event type."""
    assert detect_change_types([file_path], event_name=event_name) == {
        "any-code-changed": False,
        "docs-changed": docs_changed,
    }


@pytest.mark.parametrize("event_name", ["pull_request", "push"])
def test_source_changes_activate_jobs(event_name: str) -> None:
    """Source changes must activate change-gated jobs for PRs and pushes."""
    assert detect_change_types(
        ["src/my_package/__init__.py"], event_name=event_name
    ) == {"any-code-changed": True, "docs-changed": False}


@pytest.mark.parametrize("event_name", ["pull_request", "push"])
def test_markdown_changes_activate_the_docs_gate(event_name: str) -> None:
    """A docs-only PR must flip docs-changed so validate-docs runs."""
    assert detect_change_types(["README.md"], event_name=event_name) == {
        "any-code-changed": False,
        "docs-changed": True,
    }
