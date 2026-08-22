"""Regression tests for live workload evaluation and promotion gates."""

from __future__ import annotations

import unittest

from bench.fawn_matrix.harness.live_evidence import (
    LiveEvidenceError,
    aggregate_platform_suites,
    build_platform_suite,
    evaluate_live_workload,
    validate_live_raw,
    validate_passport_candidate,
)
from bench.fawn_matrix.harness.types import Lane


class LiveWorkloadTest(unittest.TestCase):
    def test_simulation_is_rejected(self) -> None:
        with self.assertRaisesRegex(LiveEvidenceError, "simulated"):
            validate_live_raw(
                {"simulated_mode": True},
                {"workloadId": "webgpu_model_preprocessing"},
            )

    def test_gpu_evaluator_is_scoped_to_c_over_b(self) -> None:
        lanes = {}
        bases = {
            Lane.LANE_A.value: 12.0,
            Lane.LANE_B.value: 10.0,
            Lane.LANE_C.value: 5.0,
            Lane.LANE_D.value: 5.0,
        }
        for lane_id, base in bases.items():
            lanes[lane_id] = {
                "samples": [
                    {
                        "phase": "timed",
                        "success": True,
                        "oraclePass": True,
                        "maxAbsError": 0,
                        "memoryMb": 1,
                        "timing": {
                            "totalWallMs": base + index,
                            "compilationMs": 1,
                            "pipelineCreationMs": 1,
                            "uploadMs": 1,
                            "dispatchMs": 1,
                            "synchronizationMs": 1,
                            "readbackMs": 1,
                        },
                    }
                    for index in range(3)
                ]
            }
        report = evaluate_live_workload(
            {"workloadId": "webgpu_model_preprocessing", "lanes": lanes, "platform": {"platformId": "apple-metal"}},
            {"materialSpeedupRatio": 1.05},
            {"status": "pass"},
            _file_path(),
        )
        self.assertEqual(report["primaryComparison"], "lane_c_over_lane_b")
        self.assertEqual(report["overallThesisStatus"], "DOE_RUNTIME_PREPROCESSING_EVIDENCED")

    def test_suite_requires_all_workloads(self) -> None:
        with self.assertRaisesRegex(LiveEvidenceError, "all three"):
            build_platform_suite([], "MISSING_KEY")

    def test_aggregate_requires_amd(self) -> None:
        suite = {
            "platform": {"platformId": "apple-metal", "hardwareIdentity": {"identityHash": "apple"}},
        }
        with self.assertRaisesRegex(LiveEvidenceError, "amd-vulkan"):
            aggregate_platform_suites([suite], ["apple-metal", "amd-vulkan"], ["windows-d3d12"])

    def test_passport_rejects_unsigned_receipt(self) -> None:
        aggregate = {
            "reportKind": "fawn-doe-cross-platform-suite",
            "corePlatformStatus": "pass",
            "platforms": {
                "apple-metal": {
                    "promotionReceipt": {"signatureStatus": "unsigned_review_required"},
                    "decisions": {"fawnShell": True},
                }
            },
        }
        with self.assertRaisesRegex(LiveEvidenceError, "unsigned"):
            validate_passport_candidate(aggregate)


def _file_path():
    from pathlib import Path
    return Path(__file__)


if __name__ == "__main__":
    unittest.main()
