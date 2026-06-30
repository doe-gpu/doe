#!/usr/bin/env python3
"""Tests for backend selection gate CLI behavior."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
GATE_PATH = REPO_ROOT / "bench" / "gates" / "backend_selection_gate.py"


def test_missing_report_fails_without_traceback() -> None:
    result = subprocess.run(
        [
            sys.executable,
            str(GATE_PATH),
            "--report",
            "bench/out/missing-backend-selection-report.json",
        ],
        cwd=REPO_ROOT,
        check=False,
        capture_output=True,
        text=True,
    )

    combined_output = result.stdout + result.stderr
    assert result.returncode == 1
    assert "FAIL: backend selection gate input error:" in result.stdout
    assert "Traceback" not in combined_output
