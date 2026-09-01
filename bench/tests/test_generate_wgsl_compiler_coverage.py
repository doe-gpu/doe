#!/usr/bin/env python3
"""Tests for the generated WGSL compiler coverage ledger."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from bench.gates import wgsl_compiler_coverage_gate as gate
from bench.tools import generate_wgsl_compiler_coverage as coverage


class WgslCompilerCoverageTests(unittest.TestCase):
    def test_spirv_report_requires_subgroup_coverage(self) -> None:
        passed, reason = coverage.spirv_report_pass({
            "passed": 10,
            "failed": 0,
            "discovered": {
                "validated": 4,
                "validationFailed": 0,
                "emitSkipped": 0,
                "subgroupValidated": 0,
                "subgroupSkipped": 0,
            },
        })
        self.assertFalse(passed)
        self.assertIn("no subgroup", reason)

    def test_cts_report_rejects_zero_exit_false_pass(self) -> None:
        passed, reason, query_ids = coverage.cts_report_pass(
            {
                "summary": {
                    "identityBound": True,
                    "dryRun": False,
                    "queryCount": 1,
                    "passCount": 0,
                    "failCount": 1,
                },
                "rows": [{"id": "subgroup_add", "pass": False, "exitCode": 0}],
            },
            ["subgroup_add"],
        )
        self.assertFalse(passed)
        self.assertEqual(query_ids, ["subgroup_add"])
        self.assertIn("failing rows", reason)

    def test_workaround_scan_finds_forbidden_capability_removal(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            fixture = Path(temporary_directory) / "vk_feature_caps.zig"
            fixture.write_text('const name = "DOE_DISABLE_SUBGROUPS";\n', encoding="utf-8")
            matches = coverage.find_workaround_matches(
                "DOE_DISABLE_SUBGROUPS",
                [str(fixture)],
            )
        self.assertEqual(len(matches), 1)
        self.assertTrue(matches[0].endswith("vk_feature_caps.zig:1"))

    def test_coverage_gate_rejects_changed_artifact_hash(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            artifact = Path(temporary_directory) / "shader.spv"
            artifact.write_bytes(b"SPIR-V")
            failure = gate.artifact_failure(
                {"path": str(artifact), "sha256": "0" * 64},
                "shader",
            )
        self.assertIsNotNone(failure)
        self.assertIn("hash changed", failure)


if __name__ == "__main__":
    unittest.main()
