from __future__ import annotations

import hashlib
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PLAN = (
    ROOT
    / "bench/external-projects/world-lab-runtime-webgpu"
    / "package-compilation-observer-qm2.plan.json"
)
RESULT = (
    ROOT
    / "bench/out/external-projects/world-lab-runtime-webgpu"
    / "world-lab-package-compilation-observer-qm2-v1/result.json"
)
REPORT = (
    ROOT
    / "reports/ecosystem/world-lab-runtime-webgpu"
    / "world-lab-native-program-identity-amd-vulkan-2026-08-16-diagnostic.json"
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class WorldLabNativeProgramIdentityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.plan = json.loads(PLAN.read_text())
        cls.result = json.loads(RESULT.read_text())
        cls.report = json.loads(REPORT.read_text())
        cls.registry = json.loads(
            (ROOT / "config/ecosystem-registry.json").read_text()
        )

    def test_successor_preserves_application_and_scientific_parameters(self) -> None:
        self.assertEqual(
            self.plan["predecessor"]["planId"],
            "world-lab-package-compilation-observer-qm1-v1",
        )
        self.assertTrue(self.plan["frozenWork"]["applicationSourceUnchanged"])
        self.assertTrue(self.plan["frozenWork"]["shaderSourceUnchanged"])
        self.assertFalse(
            self.plan["frozenWork"]["scientificParametersChangedFromQm1"]
        )

    def test_native_dispatches_match_public_observer(self) -> None:
        self.assertEqual(self.result["status"], "passed")
        identity = self.result["lanes"]["D0"]["nativeIdentity"]
        self.assertTrue(identity["valid"])
        self.assertEqual(identity["validationErrors"], [])
        self.assertTrue(identity["dispatchIdentityMatches"])
        self.assertEqual(identity["dispatchCount"], 3)
        self.assertEqual(identity["submissionCount"], 3)
        self.assertEqual(identity["rowCount"], 6)

    def test_native_runtime_trace_and_spirv_bytes_are_bound(self) -> None:
        identity = self.result["lanes"]["D0"]["nativeIdentity"]
        # This predecessor used the mutable workspace runtime path. Its receipt
        # preserves the runtime digest observed during the run; later clean-
        # install successors bind an immutable copied runtime payload.
        self.assertRegex(identity["runtime"]["sha256"], r"^[a-f0-9]{64}$")
        self.assertEqual(identity["trace"]["sha256"], sha256(Path(identity["trace"]["path"])))
        self.assertGreaterEqual(len(identity["artifacts"]), 1)
        for artifact in identity["artifacts"]:
            self.assertEqual(artifact["sha256"], sha256(Path(artifact["path"])))
            self.assertTrue(artifact["spirvValPassed"])

    def test_credit_boundary_remains_closed(self) -> None:
        adjudication = self.result["adjudication"]
        for field in (
            "runtimeOwnershipDecisionReopened",
            "runtimeOwnershipCredit",
            "performanceCredit",
            "promotionCredit",
            "releaseCredit",
        ):
            self.assertFalse(adjudication[field])

    def test_reviewed_report_and_registry_bind_native_evidence(self) -> None:
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
        self.assertEqual(reference["reviewedAt"], self.report["review"]["reviewedAt"])
        self.assertGreaterEqual(
            actor["lastReviewedAt"],
            self.report["review"]["reviewedAt"],
        )
        self.assertEqual(actor["promotionStatus"], "not-promoted")


if __name__ == "__main__":
    unittest.main()
