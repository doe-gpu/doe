#!/usr/bin/env python3
"""Tests for the Qwen selected-logit splice runner."""

from __future__ import annotations

import argparse
import importlib.util
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = (
    REPO_ROOT
    / "bench"
    / "tools"
    / "run_qwen_3_6_27b_af16_doppler_selected_logit_splice.py"
)


class QwenSelectedLogitSpliceRunnerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        spec = importlib.util.spec_from_file_location(
            "qwen_selected_logit_splice_runner",
            SCRIPT,
        )
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_missing_reference_export_preserves_existing_out_dir(self) -> None:
        manifest = self.tmp / "manifest.json"
        manifest.write_text("{}", encoding="utf-8")
        out_dir = self.tmp / "out"
        out_dir.mkdir()
        sentinel = out_dir / "selected-logit-splice.json"
        sentinel.write_text("existing\n", encoding="utf-8")
        args = argparse.Namespace(
            manifest=manifest,
            tsir_fixture=self.tmp / "tsir-fixture",
            reference_export=self.tmp / "missing-reference-export.json",
            reference_report=self.tmp / "missing-reference-report.json",
            program_bundle=self.tmp / "missing-program-bundle.json",
            out_dir=out_dir,
            sdk_root=self.tmp / "sdk",
            cells_root=self.tmp / "cells",
            tail_cells_root=self.tmp / "tail-cells",
            token_id=None,
            top_k=64,
            chunk_pe_width=32,
            atol=2.0e-2,
        )

        with mock.patch.object(self.module, "parse_args", return_value=args):
            with self.assertRaises(FileNotFoundError):
                self.module.main()

        self.assertTrue(sentinel.is_file())
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "existing\n")


if __name__ == "__main__":
    unittest.main()
