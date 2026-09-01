#!/usr/bin/env python3
"""Tests for the configured CTS subset runner."""

from __future__ import annotations

import unittest

from bench.runners import run_cts_subset as runner


class CtsSubsetRunnerTests(unittest.TestCase):
    def test_parse_adapter_identity_materializes_physical_fields(self) -> None:
        payload = runner.parse_adapter_identity(
            [
                "provider setup",
                '{"schemaVersion":1,"artifactKind":"webgpu_cts_adapter_identity",'
                '"provider":"fawn-node-gpu-provider","adapterInfo":{'
                '"vendor":"AMD","device":"Radeon","description":"RADV",'
                '"vendorID":4098,"deviceID":5510,"driverVersion":109051907}}',
            ]
        )
        self.assertEqual(payload["adapterInfo"]["vendorID"], 4098)
        self.assertEqual(payload["adapterInfo"]["deviceID"], 5510)
        self.assertEqual(payload["adapterInfo"]["driverVersion"], 109051907)

    def test_parse_adapter_identity_rejects_incomplete_identity(self) -> None:
        with self.assertRaisesRegex(ValueError, "missing non-empty fields: description"):
            runner.parse_adapter_identity(
                [
                    '{"schemaVersion":1,"artifactKind":"webgpu_cts_adapter_identity",'
                    '"provider":"fawn-node-gpu-provider","adapterInfo":{'
                    '"vendor":"AMD","device":"Radeon"}}',
                ]
            )

    def test_load_identity_probe_requires_explicit_policy(self) -> None:
        with self.assertRaisesRegex(ValueError, "identityProbe.required"):
            runner.load_identity_probe({"commandTemplate": "node probe.cjs"})

    def test_parse_cts_text_summary_detects_failures_despite_zero_exit(self) -> None:
        summary = runner.parse_cts_text_summary(
            """
** Summary **
Passed  w/o warnings = 0 / 5 = 0.00%
Passed with warnings = 0 / 5 = 0.00%
Skipped              = 0 / 5 = 0.00%
Failed               = 5 / 5 = 100.00%
""",
            "",
        )
        self.assertIsNotNone(summary)
        self.assertEqual(summary["failed"], 5)
        self.assertEqual(summary["total"], 5)

    def test_parse_cts_text_summary_accepts_complete_pass(self) -> None:
        summary = runner.parse_cts_text_summary(
            """
Passed  w/o warnings = 5 / 5 = 100.00%
Passed with warnings = 0 / 5 = 0.00%
Skipped              = 0 / 5 = 0.00%
Failed               = 0 / 5 = 0.00%
""",
            "",
        )
        self.assertIsNotNone(summary)
        self.assertEqual(summary["passedWithoutWarnings"], 5)
        self.assertEqual(summary["failed"], 0)


if __name__ == "__main__":
    unittest.main()
