#!/usr/bin/env python3
"""Tests for the Qwen simfabric cell summary receipt CLI."""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = (
    REPO_ROOT
    / "bench"
    / "tools"
    / "synthesize_qwen_3_6_27b_simfabric_cells_summary_receipt.py"
)


class QwenSimfabricCellsSummaryReceiptTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_documented_canary_constraints_exit_success(self) -> None:
        import importlib.util

        spec = importlib.util.spec_from_file_location(
            "qwen_simfabric_summary",
            SCRIPT,
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)

        cells_root = self.tmp / "cells"
        receipts_root = self.tmp / "receipts"
        smoke_config = self.tmp / "smoke.json"
        out = self.tmp / "summary.json"
        cells_root.mkdir()
        receipts_root.mkdir()
        smoke_config.write_text(
            json.dumps({"scopeRestrictions": {"example": "typed"}}),
            encoding="utf-8",
        )

        for cell in module.CELLS:
            for source_key in (
                "layout_basename",
                "pe_program_basename",
                "run_basename",
            ):
                (cells_root / cell[source_key]).write_text(
                    f"// {cell['kernel']} {source_key}\n",
                    encoding="utf-8",
                )
            receipt_dir = receipts_root / cell["receipt_dir_basename"]
            receipt_dir.mkdir()
            (receipt_dir / "receipt.json").write_text(
                json.dumps(
                    {
                        "verdict": "pass",
                        "parityMaxAbsDiff": 0,
                        "parityMaxRelDiff": 0,
                        "shape": {"canary": True},
                    }
                ),
                encoding="utf-8",
            )

        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--cells-root",
                str(cells_root),
                "--receipts-root",
                str(receipts_root),
                "--smoke-config",
                str(smoke_config),
                "--out",
                str(out),
            ],
            check=False,
            cwd=REPO_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(
            receipt["verdict"],
            "pass_with_documented_canary_constraints",
        )
        self.assertEqual(receipt["passCount"], len(module.CELLS))
        self.assertEqual(receipt["failCount"], 0)


if __name__ == "__main__":
    unittest.main()
