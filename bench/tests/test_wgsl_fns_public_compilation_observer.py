from __future__ import annotations

import hashlib
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PLAN = (
    ROOT
    / "bench/external-projects/wgsl-fns"
    / "public-compilation-observer-qm0.plan.json"
)
RESULT = (
    ROOT
    / "bench/out/external-projects/wgsl-fns"
    / "public-compilation-observer-qm0r1-v1/result.json"
)
REPORT = (
    ROOT
    / "reports/ecosystem/wgsl-fns"
    / "wgsl-fns-public-compilation-observer-amd-vulkan-2026-08-16-diagnostic.json"
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class WgslFnsPublicCompilationObserverTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.plan = json.loads(PLAN.read_text())
        cls.result = json.loads(RESULT.read_text())
        cls.report = json.loads(REPORT.read_text())
        cls.registry = json.loads(
            (ROOT / "config/ecosystem-registry.json").read_text()
        )

    def test_frozen_workload_and_credit_boundary(self) -> None:
        self.assertIn("unchanged wgsl-fns smoothStep", self.plan["workload"])
        self.assertEqual(self.result["status"], "passed")
        self.assertEqual(self.result["failures"], [])
        credit = self.result["credit"]
        self.assertTrue(credit["publicCompilationDiagnosticAdmission"])
        for field in (
            "runtimeOwnershipDecisionReopened",
            "runtimeOwnershipCredit",
            "performanceCredit",
            "promotionCredit",
            "releaseCredit",
        ):
            self.assertFalse(credit[field])

    def test_compilation_info_is_bound_to_the_exact_shader_module(self) -> None:
        for lane_id in ("W0", "D0"):
            lane = self.result["lanes"][lane_id]
            self.assertEqual(lane["execution"]["exitCode"], 0)
            self.assertTrue(lane["validation"]["valid"])
            self.assertTrue(lane["semantic"]["oracle"]["passed"])
            observation = lane["observation"]
            self.assertEqual(observation["summary"]["compilationInfoCount"], 1)
            self.assertEqual(observation["summary"]["dispatchCount"], 1)
            self.assertEqual(observation["summary"]["readbackCount"], 1)
            info = observation["compilationInfos"][0]
            self.assertEqual(info["status"], "returned")
            self.assertEqual(info["messages"], [])
            self.assertEqual(
                info["shaderModuleId"], observation["shaderModules"][0]["id"]
            )

    def test_provider_lanes_have_identical_program_and_output_evidence(self) -> None:
        self.assertEqual(
            self.result["identities"]["normalized"]["W0"],
            self.result["identities"]["normalized"]["D0"],
        )
        self.assertEqual(
            self.result["identities"]["output"]["W0"],
            self.result["identities"]["output"]["D0"],
        )

    def test_reviewed_report_and_registry_bind_raw_evidence(self) -> None:
        self.assertEqual(self.report["review"]["status"], "reviewed")
        for reference in self.report["receipts"] + self.report["rawEvidence"]:
            self.assertEqual(reference["sha256"], sha256(ROOT / reference["path"]))
        actor = next(
            actor for actor in self.registry["actors"] if actor["id"] == "wgsl-fns"
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
