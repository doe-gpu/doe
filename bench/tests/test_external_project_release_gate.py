"""Tests for the downstream application promotion boundary."""

from __future__ import annotations

import unittest
from pathlib import Path

from bench.gates.external_project_release_gate import _floor_failures, evaluate
from bench.lib.ecosystem_registry import load_json_object


REPO_ROOT = Path(__file__).resolve().parents[2]


class ExternalProjectReleaseGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.registry = load_json_object(
            REPO_ROOT / "config/ecosystem-registry.json"
        )
        cls.policy = load_json_object(
            REPO_ROOT / "config/external-project-promotion-policy.json"
        )
        cls.holo_manifest = load_json_object(
            REPO_ROOT
            / "bench/external-projects/holoscript-snn-webgpu/tropical-spmv.harness.json"
        )

    def test_checked_in_release_surface_passes_without_false_promotion(self) -> None:
        result = evaluate(REPO_ROOT, self.registry, self.policy)

        self.assertTrue(result["ok"], result["failures"])
        self.assertEqual(result["summary"]["promotedHarnessCount"], 0)

    def test_diagnostic_harness_cannot_satisfy_promotion_floor(self) -> None:
        actor = self.registry["actors"][0]
        failures = _floor_failures(
            actor,
            self.holo_manifest,
            {},
            self.policy["promotionFloor"],
            "actors[0].harnesses[0]",
        )
        codes = {item["code"] for item in failures}

        self.assertIn("production_substitution_unvalidated", codes)
        self.assertIn("missing_promoted_support_target", codes)
        self.assertIn("reliability_floor_not_met", codes)
        self.assertIn("replay_not_required", codes)
        self.assertIn("release_command_not_blocking", codes)
        self.assertIn("missing_promotion_report", codes)


if __name__ == "__main__":
    unittest.main()
