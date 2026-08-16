from __future__ import annotations

import hashlib
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PLAN = (
    ROOT
    / "bench/external-projects/world-lab-runtime-webgpu"
    / "package-observer-admission-qm1.plan.json"
)
RESULT = (
    ROOT
    / "bench/out/external-projects/world-lab-runtime-webgpu"
    / "world-lab-package-observer-admission-qm1r2-v1/result.json"
)
REPORT = (
    ROOT
    / "reports/ecosystem/world-lab-runtime-webgpu"
    / "world-lab-package-observer-admission-amd-vulkan-2026-08-16-diagnostic.json"
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class WorldLabPackageObserverAdmissionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.plan = json.loads(PLAN.read_text())
        cls.result = json.loads(RESULT.read_text())
        cls.report = json.loads(REPORT.read_text())
        cls.registry = json.loads(
            (ROOT / "config/ecosystem-registry.json").read_text()
        )
        cls.package = json.loads(
            (ROOT / "packages/doe-gpu/package.json").read_text()
        )

    def test_correction_preserves_the_frozen_application_population(self) -> None:
        predecessor = self.plan["predecessor"]
        self.assertEqual(predecessor["failureClass"], "infrastructure")
        self.assertIn("mapped-readback checkpoint", predecessor["correction"])
        self.assertFalse(
            self.plan["frozenWork"]["scientificParametersChangedFromQm0"]
        )
        self.assertEqual(self.plan["frozenWork"]["assertionCount"], 16)

    def test_public_observer_passes_both_provider_lanes(self) -> None:
        self.assertEqual(self.result["status"], "passed")
        expected = {
            "workerCount": 2,
            "shaderAttemptCount": 6,
            "dispatchCount": 3,
            "drawCount": 2,
            "submissionCount": 5,
            "readbackCount": 8,
        }
        for lane_id in ("W0", "D0"):
            lane = self.result["lanes"][lane_id]
            self.assertTrue(lane["success"])
            self.assertTrue(lane["evidence"]["valid"])
            self.assertEqual(lane["evidence"]["validationErrors"], [])
            self.assertEqual(lane["evidence"]["counts"], expected)
            self.assertEqual(len(lane["assertions"]), 16)
            self.assertGreater(lane["process"]["peakProcessTreeMemoryBytes"], 0)
        self.assertEqual(
            self.result["lanes"]["W0"]["evidence"]["shapeIdentitySha256"],
            self.result["lanes"]["D0"]["evidence"]["shapeIdentitySha256"],
        )
        self.assertEqual(
            self.result["lanes"]["W0"]["evidence"]["outputIdentitySha256"],
            self.result["lanes"]["D0"]["evidence"]["outputIdentitySha256"],
        )

    def test_credit_boundary_and_public_package_surface_are_bound(self) -> None:
        adjudication = self.result["adjudication"]
        self.assertTrue(adjudication["packageObserverAdmission"])
        for field in (
            "runtimeOwnershipDecisionReopened",
            "runtimeOwnershipCredit",
            "performanceCredit",
            "promotionCredit",
            "releaseCredit",
        ):
            self.assertFalse(adjudication[field])
        self.assertIn("./observe", self.package["exports"])
        self.assertEqual(
            self.package["exports"]["./transparent-webgpu-observation.schema.json"],
            "./assets/transparent-webgpu-observation.schema.json",
        )

    def test_reviewed_report_and_registry_bind_raw_evidence(self) -> None:
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
