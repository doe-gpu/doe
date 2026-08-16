from __future__ import annotations

import hashlib
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PLAN = (
    ROOT
    / "bench/external-projects/world-lab-runtime-webgpu"
    / "package-compilation-observer-qm1.plan.json"
)
RESULT = (
    ROOT
    / "bench/out/external-projects/world-lab-runtime-webgpu"
    / "world-lab-package-compilation-observer-qm1-v1/result.json"
)
REPORT = (
    ROOT
    / "reports/ecosystem/world-lab-runtime-webgpu"
    / "world-lab-package-compilation-observer-amd-vulkan-2026-08-16-diagnostic.json"
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class WorldLabPackageCompilationObserverTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.plan = json.loads(PLAN.read_text())
        cls.result = json.loads(RESULT.read_text())
        cls.report = json.loads(REPORT.read_text())
        cls.registry = json.loads(
            (ROOT / "config/ecosystem-registry.json").read_text()
        )

    def test_correction_only_successor_preserves_scientific_contract(self) -> None:
        predecessor = self.plan["predecessor"]
        self.assertEqual(predecessor["failureClass"], "infrastructure")
        self.assertIn("LF-normalized runtime", predecessor["correction"])
        self.assertFalse(
            self.plan["frozenWork"]["scientificParametersChangedFromQm0"]
        )

    def test_real_compilation_diagnostic_is_source_bound_in_both_lanes(self) -> None:
        self.assertEqual(self.result["status"], "passed")
        expected_source = self.result["expectedInvalidShaderSourceSha256"]
        for lane_id in ("W0", "D0"):
            lane = self.result["lanes"][lane_id]
            self.assertTrue(lane["success"])
            self.assertTrue(lane["evidence"]["valid"])
            self.assertEqual(lane["evidence"]["validationErrors"], [])
            self.assertEqual(lane["evidence"]["counts"], self.result["expectedCounts"])
            self.assertEqual(lane["evidence"]["errorCompilationInfoCount"], 1)
            self.assertGreaterEqual(lane["evidence"]["errorMessageCount"], 1)
            self.assertEqual(lane["evidence"]["errorShaderSources"], [expected_source])
            self.assertGreater(lane["process"]["peakProcessTreeMemoryBytes"], 0)
        self.assertTrue(self.result["adjudication"]["diagnosticSourceMatch"])
        self.assertEqual(
            self.result["lanes"]["W0"]["evidence"]["diagnosticSourceIdentitySha256"],
            self.result["lanes"]["D0"]["evidence"]["diagnosticSourceIdentitySha256"],
        )

    def test_credit_boundary_is_explicit(self) -> None:
        adjudication = self.result["adjudication"]
        self.assertTrue(adjudication["packageCompilationObserverAdmission"])
        for field in (
            "runtimeOwnershipDecisionReopened",
            "runtimeOwnershipCredit",
            "performanceCredit",
            "promotionCredit",
            "releaseCredit",
        ):
            self.assertFalse(adjudication[field])

    def test_reviewed_report_and_registry_bind_evidence(self) -> None:
        self.assertEqual(self.report["review"]["status"], "reviewed")
        for reference in self.report["receipts"] + self.report["rawEvidence"]:
            self.assertEqual(reference["sha256"], sha256(ROOT / reference["path"]))
        actor = next(
            actor
            for actor in self.registry["actors"]
            if actor["id"] == "world-lab-runtime-webgpu"
        )
        reference = next(
            reference
            for reference in actor["reviewedReports"]
            if reference["reportId"] == self.report["reportId"]
        )
        self.assertEqual(reference["sha256"], sha256(REPORT))
        self.assertEqual(actor["promotionStatus"], "not-promoted")


if __name__ == "__main__":
    unittest.main()
