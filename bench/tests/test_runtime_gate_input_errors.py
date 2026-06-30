#!/usr/bin/env python3
"""CLI input-error regressions for runtime gates."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


def _run_gate(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, *args],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )


def _assert_typed_failure(result: subprocess.CompletedProcess[str], message: str) -> None:
    combined_output = result.stdout + result.stderr
    assert result.returncode == 1
    assert message in result.stdout
    assert "Traceback" not in combined_output


def test_comparable_runtime_invariants_missing_report_is_typed_failure() -> None:
    result = _run_gate("bench/gates/comparable_runtime_invariants_gate.py")

    _assert_typed_failure(
        result,
        "FAIL: comparable runtime invariants gate input error:",
    )


def test_sync_conformance_missing_report_is_typed_failure() -> None:
    result = _run_gate("bench/gates/sync_conformance_gate.py", "--backend", "metal")

    _assert_typed_failure(result, "FAIL: metal sync conformance input error:")


def test_timing_policy_missing_report_is_typed_failure() -> None:
    result = _run_gate("bench/gates/timing_policy_gate.py", "--backend", "metal")

    _assert_typed_failure(result, "FAIL: metal timing policy gate input error:")
