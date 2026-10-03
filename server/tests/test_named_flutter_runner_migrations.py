"""Static routing contract for required named Client/Core runners."""

import ast
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]
CASES = {
    "f05_flutter_acceptance.py": (
        "test/features/home_workflows/home_workflow_normal_core_test.dart",
        "real Client completes and reconciles a durable workflow across restart",
        "f05-",
    ),
    "f20_flutter_acceptance.py": (
        "test/features/core_audit/core_audit_normal_core_test.dart",
        "real Client pins, rotates and compares Core audit across restart",
        "f20-",
    ),
    "f54_flutter_acceptance.py": (
        "test/features/local_notifications/local_notification_normal_core_test.dart",
        "real Client persists the subscription and deduplicates a safe tap after restart",
        "f54-",
    ),
}


def _assignments(tree):
    values = {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1:
            target = node.targets[0]
            if isinstance(target, ast.Name) and target.id in {"TEST_FILE", "TEST_NAME"}:
                values[target.id] = ast.literal_eval(node.value)
    return values


@pytest.mark.parametrize("filename", sorted(CASES))
def test_runner_uses_one_fixed_named_machine_gate(filename):
    expected_file, expected_name, log_prefix = CASES[filename]
    path = ROOT / "server" / "tests" / "support" / filename
    source = path.read_text()
    tree = ast.parse(source, filename=str(path))
    imports = {
        alias.name
        for node in tree.body
        if isinstance(node, (ast.Import, ast.ImportFrom))
        for alias in node.names
    }
    assert "subprocess" not in imports
    assert "run_named_flutter" in imports
    assert _assignments(tree) == {
        "TEST_FILE": expected_file,
        "TEST_NAME": expected_name,
    }

    calls = [
        node
        for node in ast.walk(tree)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Name)
        and node.func.id == "run_named_flutter"
    ]
    assert len(calls) == 1
    keywords = {item.arg: item.value for item in calls[0].keywords}
    assert set(keywords) == {
        "test_file",
        "test_name",
        "env",
        "cwd",
        "log_path",
        "timeout_seconds",
    }
    assert isinstance(keywords["test_file"], ast.Name)
    assert keywords["test_file"].id == "TEST_FILE"
    assert isinstance(keywords["test_name"], ast.Name)
    assert keywords["test_name"].id == "TEST_NAME"
    assert ast.literal_eval(keywords["timeout_seconds"]) == 120
    assert log_prefix in ast.unparse(keywords["log_path"])
    assert ".machine.jsonl" in ast.unparse(keywords["log_path"])

    for node in ast.walk(tree):
        if (
            isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name)
            and node.func.id == "RuntimeError"
        ):
            assert len(node.args) == 1
            assert isinstance(node.args[0], ast.Constant)
            assert isinstance(node.args[0].value, str)
