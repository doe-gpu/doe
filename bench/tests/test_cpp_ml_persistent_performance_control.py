from __future__ import annotations

import hashlib
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PLAN = (
    ROOT
    / "bench/external-projects/electronicarts-cpp-ml-intro"
    / "persistent-performance-control.plan.json"
)
RESULT = (
    ROOT
    / "bench/out/external-projects/electronicarts-cpp-ml-intro"
    / "persistent-performance-control-qm0-v1/result.json"
)
REVIEWED = (
    ROOT
    / "reports/ecosystem/electronicarts-cpp-ml-intro"
    / "cpp-ml-mnist-persistent-performance-control-amd-vulkan-2026-08-16-diagnostic.json"
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class CppMlPersistentPerformanceControlTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.plan = json.loads(PLAN.read_text())
        cls.result = json.loads(RESULT.read_text())
        cls.reviewed = json.loads(REVIEWED.read_text())
        cls.registry = json.loads(
            (ROOT / "config/ecosystem-registry.json").read_text()
        )

    def test_frozen_population_is_complete_and_exact(self) -> None:
        self.assertEqual(self.result["status"], "passed")
        self.assertEqual(self.result["failures"], [])
        self.assertFalse(self.result["developmentOverride"])
        self.assertTrue(self.result["frozenPopulation"])
        self.assertEqual(
            self.result["population"],
            {"coldCount": 30, "warmupCount": 5, "warmCount": 100},
        )
        self.assertTrue(self.result["hostHardware"]["physicalGpuEligible"])
        self.assertEqual(
            self.result["outputSha256"],
            "17287b3124138aac38b936254f378f6f4765e5e9ffc524766686e5117c48a079",
        )
        for lane_id in ("W0", "D0"):
            lane = self.result["samples"][lane_id]
            self.assertEqual(len(lane["cold"]), 30)
            self.assertTrue(
                all(
                    sample["exitCode"] == 0
                    and sample["signal"] is None
                    and not sample["timedOut"]
                    and sample["result"]["status"] == "passed"
                    for sample in lane["cold"]
                )
            )
            self.assertEqual(lane["warm"]["result"]["warmupCount"], 5)
            self.assertEqual(lane["warm"]["result"]["sampleCount"], 100)

    def test_performance_property_is_terminally_rejected(self) -> None:
        self.assertEqual(
            self.plan["claimedRuntimeOwnershipProperty"],
            "persistent-performance-control",
        )
        self.assertFalse(self.result["materialPerformanceWin"])
        self.assertFalse(self.result["noPerformanceRegression"])
        self.assertEqual(
            self.result["decision"], "reject-persistent-performance-control"
        )
        for population in ("cold", "warm"):
            for percentile in ("p50", "p95", "p99"):
                ratio = self.result["ratios"][population][percentile]
                self.assertLess(ratio["speedup"], 1.10)
                self.assertGreater(ratio["comparisonOverBaseline"], 1.05)
        self.assertFalse(self.result["credit"]["publicPerformanceClaim"])
        self.assertFalse(self.result["credit"]["applicationPromotion"])
        self.assertFalse(self.result["credit"]["releaseBlocker"])

    def test_reviewed_report_and_registry_bind_the_result(self) -> None:
        self.assertEqual(self.reviewed["review"]["status"], "reviewed")
        self.assertEqual(self.reviewed["outcome"], "no-material-result")
        ownership = self.reviewed["runtimeOwnershipAssessment"]
        self.assertEqual(ownership["status"], "fail")
        self.assertEqual(
            ownership["claimedProperty"], "persistent-performance-control"
        )
        for reference in self.reviewed["receipts"] + self.reviewed["rawEvidence"]:
            self.assertEqual(reference["sha256"], sha256(ROOT / reference["path"]))
        actor = next(
            actor
            for actor in self.registry["actors"]
            if actor["id"] == "electronicarts-cpp-ml-intro"
        )
        registry_reference = next(
            reference
            for reference in actor["reviewedReports"]
            if reference["reportId"] == self.reviewed["reportId"]
        )
        self.assertEqual(registry_reference["sha256"], sha256(REVIEWED))
        self.assertEqual(actor["promotionStatus"], "not-promoted")


if __name__ == "__main__":
    unittest.main()
