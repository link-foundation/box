"""Tests for scripts/version_and_commit.py (issue #67)."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest


SCRIPT_PATH = (
    Path(__file__).resolve().parent.parent / "scripts" / "version_and_commit.py"
)
spec = importlib.util.spec_from_file_location("version_and_commit", SCRIPT_PATH)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)  # type: ignore[union-attr]


def test_parse_version_reads_project_table_not_other_tables() -> None:
    """A version key in another table must not shadow project.version."""
    content = """
[tool.scriv]
version = "scripted"

[project]
name = "example"
version = "2.3.4"
"""
    assert module.parse_version(content) == "2.3.4"


def test_parse_version_fails_loudly_when_project_version_is_missing() -> None:
    with pytest.raises(ValueError, match="no project.version"):
        module.parse_version("[project]\nname = 'example'\n")


def test_parse_version_fails_loudly_on_invalid_toml() -> None:
    with pytest.raises(ValueError, match="not valid TOML"):
        module.parse_version("not toml at all ][")


def test_get_current_version_reads_file(tmp_path: Path) -> None:
    pyproject = tmp_path / "pyproject.toml"
    pyproject.write_text("[project]\nversion = '3.1.4'\n")
    assert module.get_current_version(pyproject) == "3.1.4"


RULESET_REJECTION = (
    "remote: error: GH006: Protected branch update failed for refs/heads/main.\n"
    "remote: - Changes must be made through a pull request.\n"
    "! [remote rejected] main -> main (push declined due to repository rule violations)\n"
    "error: failed to push some refs to 'github.com:example/example.git'"
)

LOST_RACE = (
    "To github.com:example/example.git\n"
    " ! [rejected]        main -> main (fetch first)\n"
    "error: failed to push some refs to 'github.com:example/example.git'\n"
    "hint: Updates were rejected because the remote contains work that you do not have locally."
)

REAL_ERROR = (
    "ssh: connect to host github.com port 22: Connection timed out\r\n"
    "fatal: Could not read from remote repository."
)


def test_repository_rules_are_classified_before_the_rebase_retry() -> None:
    """A ruleset refusal looks like a non-fast-forward but is policy, not a race."""
    assert (
        module.classify_push_failure(RULESET_REJECTION)
        is module.PushFailure.REPOSITORY_RULES
    )
    assert (
        module.classify_push_failure(RULESET_REJECTION.lower())
        is module.PushFailure.REPOSITORY_RULES
    )


def test_a_lost_race_is_classified_for_the_rebase_retry() -> None:
    assert module.classify_push_failure(LOST_RACE) is module.PushFailure.LOST_RACE


def test_other_failures_never_trigger_a_rebase() -> None:
    assert module.classify_push_failure(REAL_ERROR) is module.PushFailure.OTHER


def test_lost_race_is_rebased_and_push_succeeds(monkeypatch, capsys) -> None:
    """A non-fast-forward triggers exactly one pull --rebase, then a retry."""
    commands: list[list[str]] = []

    def fake_run(cmd):
        commands.append(cmd)
        if cmd[:2] == ["git", "push"] and len(commands) == 1:
            return subprocess.CompletedProcess(cmd, 1, stdout="", stderr=LOST_RACE)
        return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

    monkeypatch.setattr(module, "run_git_capturing", fake_run)
    module.push_branch_with_rebase_retry("main")

    assert commands[0] == ["git", "push", "origin", "main"]
    assert commands[1] == ["git", "pull", "--rebase", "origin", "main"]
    assert commands[2] == ["git", "push", "origin", "main"]
    assert "Rebasing and retrying" in capsys.readouterr().err


def test_repository_rules_exit_without_retrying(monkeypatch, capsys) -> None:
    """Policy refusals must fail immediately; rebasing cannot change policy."""
    attempts: list[list[str]] = []

    def fake_run(cmd):
        attempts.append(cmd)
        if cmd[:2] == ["git", "push"]:
            return subprocess.CompletedProcess(
                cmd, 1, stdout="", stderr=RULESET_REJECTION
            )
        return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

    monkeypatch.setattr(module, "run_git_capturing", fake_run)
    with pytest.raises(SystemExit) as exc_info:
        module.push_branch_with_rebase_retry("main")

    assert exc_info.value.code == 1
    assert len(attempts) == 1
    captured = capsys.readouterr()
    assert "::error title=Push declined by repository rules::" in captured.err
    assert "cannot change repository policy" in captured.err


def test_other_failures_exit_without_retrying(monkeypatch, capsys) -> None:
    attempts: list[list[str]] = []

    def fake_run(cmd):
        attempts.append(cmd)
        if cmd[:2] == ["git", "push"]:
            return subprocess.CompletedProcess(cmd, 128, stdout="", stderr=REAL_ERROR)
        return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

    monkeypatch.setattr(module, "run_git_capturing", fake_run)
    with pytest.raises(SystemExit) as exc_info:
        module.push_branch_with_rebase_retry("main")

    assert exc_info.value.code == 1
    assert len(attempts) == 1
    assert "Error pushing:" in capsys.readouterr().err


def test_persistent_race_gives_up_after_max_attempts(monkeypatch, capsys) -> None:
    commands: list[list[str]] = []

    def fake_run(cmd):
        commands.append(cmd)
        if cmd[:2] == ["git", "push"]:
            return subprocess.CompletedProcess(cmd, 1, stdout="", stderr=LOST_RACE)
        return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

    monkeypatch.setattr(module, "run_git_capturing", fake_run)
    with pytest.raises(SystemExit) as exc_info:
        module.push_branch_with_rebase_retry("main", max_attempts=3)

    assert exc_info.value.code == 1
    pushes = [cmd for cmd in commands if cmd[:2] == ["git", "push"]]
    rebases = [cmd for cmd in commands if cmd[:2] == ["git", "pull"]]
    assert len(pushes) == 3
    assert len(rebases) == 2
    assert "Error pushing after 3 attempts:" in capsys.readouterr().err


def test_failed_rebase_aborts_and_exits(monkeypatch, capsys) -> None:
    commands: list[list[str]] = []

    def fake_run(cmd):
        commands.append(cmd)
        if cmd[:2] == ["git", "pull"]:
            return subprocess.CompletedProcess(
                cmd, 1, stdout="", stderr="CONFLICT (content): Merge conflict in x"
            )
        if cmd[:2] == ["git", "push"]:
            return subprocess.CompletedProcess(cmd, 1, stdout="", stderr=LOST_RACE)
        return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

    monkeypatch.setattr(module, "run_git_capturing", fake_run)
    with pytest.raises(SystemExit) as exc_info:
        module.push_branch_with_rebase_retry("main")

    assert exc_info.value.code == 1
    assert ["git", "rebase", "--abort"] in commands
    assert "Error during pull --rebase:" in capsys.readouterr().err
