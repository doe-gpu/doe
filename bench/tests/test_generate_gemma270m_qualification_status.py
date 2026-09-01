#!/usr/bin/env python3
"""Tests for the generated Gemma 270M qualification status bundle."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from bench.tools import generate_gemma270m_qualification_status as status


def passing_cts(provider: str, driver_value: object) -> dict[str, object]:
    adapter_info: dict[str, object] = {
        "device": "Radeon 8060S Graphics (RADV STRIX_HALO)",
        "description": "Radeon 8060S Graphics (RADV STRIX_HALO)",
        "isFallbackAdapter": False,
    }
    if isinstance(driver_value, int):
        adapter_info["driverVersion"] = driver_value
    else:
        adapter_info["description"] = driver_value
    return {
        "identityProbe": {
            "pass": True,
            "identity": {"provider": provider, "adapterInfo": adapter_info},
        },
        "summary": {
            "identityBound": True,
            "dryRun": False,
            "queryCount": 1,
            "passCount": 1,
            "failCount": 0,
        },
        "rows": [{"id": "subgroup_add", "pass": True}],
    }


class Gemma270mQualificationStatusTests(unittest.TestCase):
    def test_packed_vulkan_driver_version_matches_mesa_tuple(self) -> None:
        self.assertEqual(status.packed_vulkan_driver_version(109051907), "26.0.3")

    def test_cts_identity_accepts_dawn_and_doe_forms(self) -> None:
        dawn_pass, _ = status.cts_identity_matches(
            passing_cts("dawn-node-gpu-provider", "radv: Mesa 26.0.3-1ubuntu1"),
            provider="dawn-node-gpu-provider",
            adapter="Radeon 8060S Graphics",
            driver="Mesa 26.0.3",
        )
        doe_pass, _ = status.cts_identity_matches(
            passing_cts("fawn-node-gpu-provider", 109051907),
            provider="fawn-node-gpu-provider",
            adapter="Radeon 8060S Graphics",
            driver="Mesa 26.0.3",
        )
        self.assertTrue(dawn_pass)
        self.assertTrue(doe_pass)

    def test_correctness_rejects_decode_drift_with_nonzero_kv(self) -> None:
        gate = status.correctness_gate(
            {
                "pass": False,
                "stepCountPass": True,
                "logitsComparisons": [
                    {"stepIndex": 0, "pass": True, "maxAbs": 0},
                    {"stepIndex": 1, "pass": False, "maxAbs": 0.0026},
                ],
                "checkpointCoverage": {"W0": {"pass": True}, "D0": {"pass": True}},
                "kv": {"W0": True, "D0": True},
                "modelCheckpoints": {"pass": False},
            },
            [],
        )
        self.assertEqual(gate["status"], "FAIL")
        self.assertIn("1 failed", gate["detail"])
        self.assertIn("non-zero KV W0/D0=true", gate["detail"])

    def test_failed_physical_reproduction_is_not_identity_evidence(self) -> None:
        self.assertFalse(status.reproduction_execution_pass({
            "actorId": "doppler",
            "harnessId": "gemma270m-electron",
            "status": "failed",
            "preparation": {"status": "passed"},
            "failure": {"stage": "workload"},
        }))

    def test_absent_campaign_is_not_tested(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            gate = status.optional_campaign_gate(
                "reliability", Path(temporary_directory) / "missing.json"
            )
        self.assertEqual(gate["status"], "NOT_TESTED")
        self.assertEqual(gate["evidence"], [])

    def test_ownership_rejects_any_nonpassing_prerequisite(self) -> None:
        gate = status.ownership_gate([
            {"id": "identity", "status": "PASS", "evidence": []},
            {"id": "correctness", "status": "FAIL", "evidence": []},
            {"id": "reliability", "status": "NOT_TESTED", "evidence": []},
        ])
        self.assertEqual(gate["status"], "REJECTED")
        self.assertIn("correctness", gate["detail"])
        self.assertIn("reliability", gate["detail"])


if __name__ == "__main__":
    unittest.main()
