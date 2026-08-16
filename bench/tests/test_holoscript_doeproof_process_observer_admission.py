from __future__ import annotations

import hashlib
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PLAN = (
    ROOT
    / "bench/external-projects/holoscript-snn-webgpu"
    / "doeproof-process-observer-admission-qm2.plan.json"
)
RESULT = (
    ROOT
    / "bench/out/external-projects/holoscript-snn-webgpu"
    / "doeproof-process-observer-admission-qm2-v1/result.json"
)
REPORT = (
    ROOT
    / "reports/ecosystem/holoscript-snn-webgpu"
    / "holoscript-doeproof-process-observer-amd-vulkan-2026-08-16-diagnostic.json"
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class HoloScriptDoeProofProcessObserverAdmissionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.plan = json.loads(PLAN.read_text())
        cls.result = json.loads(RESULT.read_text())
        cls.report = json.loads(REPORT.read_text())
        cls.registry = json.loads(
            (ROOT / "config/ecosystem-registry.json").read_text()
        )

    def test_correction_is_infrastructure_only(self) -> None:
        predecessor = self.plan["predecessor"]
        self.assertEqual(predecessor["failureClass"], "infrastructure")
        self.assertIn("exact WebGPU method", predecessor["correction"])
        self.assertIn(
            "unchanged pinned HoloScript tropical-SpMV",
            self.plan["workload"],
        )

    def test_unchanged_process_observation_passes_both_lanes(self) -> None:
        self.assertEqual(self.result["status"], "passed")
        self.assertEqual(self.result["failures"], [])
        expected = {
            "shaderModuleCount": 1,
            "computePipelineCount": 1,
            "renderPipelineCount": 0,
            "commandCount": 340,
            "dispatchCount": 68,
            "drawCount": 0,
            "submissionCount": 136,
            "synchronizationCount": 136,
            "readbackCount": 68,
        }
        for lane_id in ("W0", "D0"):
            lane = self.result["lanes"][lane_id]
            self.assertEqual(lane["run"]["exitCode"], 0)
            self.assertEqual(lane["verify"]["exitCode"], 0)
            self.assertEqual(lane["inspect"]["exitCode"], 0)
            self.assertEqual(lane["receipt"]["oracle"], "pass")
            self.assertEqual(
                lane["receipt"]["programEvidenceStatus"], "observed"
            )
            self.assertEqual(lane["receipt"]["programCheckpointCount"], 69)
            for key, value in expected.items():
                self.assertEqual(lane["summary"][key], value)
        self.assertEqual(
            self.result["identities"]["shape"]["W0"],
            self.result["identities"]["shape"]["D0"],
        )
        self.assertEqual(
            self.result["identities"]["output"]["W0"],
            self.result["identities"]["output"]["D0"],
        )

    def test_replay_and_credit_boundary(self) -> None:
        self.assertEqual(self.result["replay"]["run"]["exitCode"], 0)
        self.assertEqual(self.result["replay"]["verify"]["exitCode"], 0)
        self.assertEqual(self.result["replay"]["compare"]["exitCode"], 0)
        credit = self.result["credit"]
        self.assertTrue(credit["packageProcessObserverAdmission"])
        for field in (
            "runtimeOwnershipDecisionReopened",
            "runtimeOwnershipCredit",
            "performanceCredit",
            "promotionCredit",
            "releaseCredit",
        ):
            self.assertFalse(credit[field])

    def test_reviewed_report_and_registry_bind_raw_evidence(self) -> None:
        self.assertEqual(self.report["review"]["status"], "reviewed")
        for reference in self.report["receipts"] + self.report["rawEvidence"]:
            self.assertEqual(reference["sha256"], sha256(ROOT / reference["path"]))
        actor = next(
            actor
            for actor in self.registry["actors"]
            if actor["id"] == "holoscript-snn-webgpu"
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
