from __future__ import annotations

import hashlib
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HARNESS = ROOT / "bench/external-projects/holoscript-snn-webgpu"
REPORT = (
    ROOT
    / "reports/benchmarks/amd-vulkan/20260815T230727Z"
    / "holoscript-lif-determinism-diagnostic.json"
)
REVIEWED_REPORT = (
    ROOT
    / "reports/ecosystem/holoscript-snn-webgpu"
    / "holoscript-lif-determinism-2026-08-15-diagnostic.json"
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class HoloScriptLifDeterminismTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.report = json.loads(REPORT.read_text())
        cls.reviewed = json.loads(REVIEWED_REPORT.read_text())
        cls.registry = json.loads(
            (ROOT / "config/ecosystem-registry.json").read_text()
        )

    def test_raw_report_is_hash_bound_and_all_lanes_pass(self) -> None:
        self.assertEqual(self.report["status"], "passed")
        for reference in self.report["immutableInputs"]:
            path = Path(reference["path"])
            if not path.is_absolute():
                path = ROOT / path
            self.assertEqual(reference["sha256"], sha256(path), reference["path"])
        for lane_id in ("I0", "I1", "W0", "D0"):
            lane = self.report["lanes"][lane_id]
            self.assertEqual(lane["runCount"], 3)
            self.assertEqual(lane["passingRuns"], 3)
            for evidence in lane["evidence"]:
                self.assertTrue(evidence["hardwareEligible"])
                self.assertTrue(evidence["sameBackendDeterminism"]["nondegenerate"])
                for case in evidence["cases"]:
                    self.assertTrue(case["oraclePass"])
                    self.assertEqual(case["delta"]["spikeMismatches"], 0)
        self.assertEqual(self.report["lanes"]["P0"]["status"], "not-required")

    def test_replay_and_cross_provider_identity_are_exact(self) -> None:
        for lane_id in ("W0", "D0"):
            replay = self.report["replay"][lane_id]
            self.assertEqual(replay["status"], "passed")
            self.assertEqual(
                replay["expectedEvidenceSha256"], replay["actualEvidenceSha256"]
            )
        self.assertTrue(self.report["crossProvider"]["exactGpuOutputIdentity"])
        self.assertEqual(
            len(self.report["crossProvider"]["identity"]["cases"]), 3
        )

    def test_decision_grants_no_ownership_or_promotion_credit(self) -> None:
        decision = self.report["decision"]
        self.assertTrue(decision["compatibilityEvidence"])
        self.assertTrue(decision["determinismEvidence"])
        for credit in (
            "runtimeOwnershipCredit",
            "applicationPromotionCredit",
            "performanceCredit",
            "releaseCredit",
        ):
            self.assertFalse(decision[credit])
        self.assertEqual(
            decision["nextGate"],
            "retain-lif-determinism-regression-and-close-runtime-ownership-hypothesis",
        )

    def test_reviewed_report_and_registry_bind_the_raw_result(self) -> None:
        self.assertEqual(self.reviewed["review"]["status"], "reviewed")
        self.assertEqual(self.reviewed["outcome"], "no-material-result")
        self.assertEqual(
            self.reviewed["runtimeOwnershipAssessment"]["decision"],
            "retain-diagnostic",
        )
        self.assertEqual(
            self.reviewed["reliability"]["baseline"]["peakMemoryBytes"],
            self.report["lanes"]["W0"]["peakMemoryBytes"],
        )
        self.assertEqual(
            self.reviewed["reliability"]["comparison"]["peakMemoryBytes"],
            self.report["lanes"]["D0"]["peakMemoryBytes"],
        )
        for reference in self.reviewed["receipts"] + self.reviewed["rawEvidence"]:
            self.assertEqual(reference["sha256"], sha256(ROOT / reference["path"]))

        self.assertEqual(self.registry["registryRevision"], "15")
        actor = next(
            actor
            for actor in self.registry["actors"]
            if actor["id"] == "holoscript-snn-webgpu"
        )
        harness = next(
            harness for harness in actor["harnesses"] if harness["id"] == "lif-determinism"
        )
        self.assertEqual(harness["status"], "measured")
        self.assertEqual(
            harness["manifestPath"],
            "bench/external-projects/holoscript-snn-webgpu/lif-determinism.harness.json",
        )
        registry_reference = next(
            reference
            for reference in actor["reviewedReports"]
            if reference["reportId"] == self.reviewed["reportId"]
        )
        self.assertEqual(registry_reference["sha256"], sha256(REVIEWED_REPORT))
        self.assertEqual(actor["promotionStatus"], "not-promoted")


if __name__ == "__main__":
    unittest.main()
