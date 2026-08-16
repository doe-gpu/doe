from __future__ import annotations

import hashlib
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
RUN_ROOT = (
    ROOT
    / "bench/out/external-projects/umap-gpu"
    / "20260816T-umap-sgd-governed-qm0-v1"
)
RAW = RUN_ROOT / "raw-benchmark.json"
RECEIPT = RUN_ROOT / "receipt-summary.json"
REVIEWED = (
    ROOT
    / "reports/ecosystem/umap-gpu"
    / "umap-sgd-governed-benchmark-amd-vulkan-2026-08-16-diagnostic.json"
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class UmapSgdGovernedBenchmarkTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.raw = json.loads(RAW.read_text())
        cls.receipt = json.loads(RECEIPT.read_text())
        cls.reviewed = json.loads(REVIEWED.read_text())
        cls.registry = json.loads(
            (ROOT / "config/ecosystem-registry.json").read_text()
        )

    def test_every_lane_and_semantic_replay_pass(self) -> None:
        self.assertEqual(self.raw["decision"]["status"], "terminal")
        for lane_id in ("I0", "I1", "W0", "D0"):
            lane = self.raw["lanes"][lane_id]
            self.assertTrue(lane["probe"]["hardwareEligible"])
            self.assertTrue(lane["probe"]["identityMatches"])
            self.assertEqual(lane["summary"]["cleanProcessRuns"], 3)
            self.assertEqual(lane["summary"]["successes"], 3)
            self.assertEqual(lane["summary"]["failures"], 0)
            identities = {
                sample["outputSha256"]
                for run in lane["runs"]
                for sample in run["benchmark"]["samples"]
                if sample["sampleKind"] == "measured"
            }
            self.assertEqual(len(identities), 1)
            self.assertTrue(
                all(
                    sample["oracle"]["pass"]
                    for run in lane["runs"]
                    for sample in run["benchmark"]["samples"]
                )
            )
        for lane_id in ("W0", "D0"):
            replay = self.raw["replays"][lane_id]
            self.assertEqual(replay["status"], "pass")
            self.assertEqual(replay["expectedSha256"], replay["actualSha256"])

    def test_output_boundary_and_performance_rejection_are_explicit(self) -> None:
        comparison = self.raw["comparison"]
        self.assertFalse(comparison["crossProviderExactOutputIdentity"])
        self.assertNotEqual(
            comparison["outputIdentities"]["W0"],
            comparison["outputIdentities"]["D0"],
        )
        self.assertFalse(comparison["materialPerformanceWin"])
        self.assertLess(comparison["W0OverD0Speedup"]["p50"], 1.10)
        self.assertFalse(self.raw["decision"]["runtimeOwnershipCredit"])
        self.assertFalse(self.raw["decision"]["performanceCredit"])

    def test_receipts_bind_dispatch_shaders_and_exact_outputs(self) -> None:
        self.assertEqual(self.receipt["dispatch"]["edgeCount"], 120)
        self.assertEqual(self.receipt["dispatch"]["epochs"], 500)
        self.assertEqual(self.receipt["dispatch"]["totalDispatches"], 1000)
        self.assertEqual(len(self.receipt["shaderHashes"]), 2)
        for reference in self.receipt["immutableInputs"].values():
            path = Path(reference["path"])
            if not path.is_absolute():
                path = (
                    ROOT
                    / path
                    if reference["path"].startswith("bench/")
                    else ROOT
                    / "bench/out/external-projects/umap-gpu/upstream"
                    / path
                )
            self.assertEqual(reference["sha256"], sha256(path), reference["path"])

    def test_reviewed_report_and_registry_bind_terminal_result(self) -> None:
        self.assertEqual(self.reviewed["review"]["status"], "reviewed")
        self.assertEqual(self.reviewed["outcome"], "no-material-result")
        self.assertEqual(
            self.reviewed["runtimeOwnershipAssessment"]["status"], "fail"
        )
        for reference in self.reviewed["receipts"] + self.reviewed["rawEvidence"]:
            self.assertEqual(reference["sha256"], sha256(ROOT / reference["path"]))
        actor = next(
            actor for actor in self.registry["actors"] if actor["id"] == "umap-gpu"
        )
        harness = next(
            harness for harness in actor["harnesses"] if harness["id"] == "sgd-benchmark"
        )
        self.assertEqual(harness["status"], "measured")
        self.assertEqual(
            harness["manifestPath"],
            "bench/external-projects/umap-gpu/sgd-benchmark.harness.json",
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
