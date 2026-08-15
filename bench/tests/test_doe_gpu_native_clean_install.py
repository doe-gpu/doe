from __future__ import annotations

import hashlib
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
REPORTS = {
    runtime: (
        ROOT
        / "reports/benchmarks/amd-vulkan/20260815T212055Z"
        / f"doe-gpu-{runtime}-native-clean-install-diagnostic.json"
    )
    for runtime in ("node", "bun")
}
RELIABILITY_REPORTS = {
    runtime: (
        ROOT
        / "reports/benchmarks/amd-vulkan/20260815T212055Z"
        / f"doe-gpu-{runtime}-native-clean-install-reliability-diagnostic.json"
    )
    for runtime in ("node", "bun")
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class DoeGpuNativeCleanInstallTests(unittest.TestCase):
    def test_reviewed_artifact_preserves_package_claim_boundary(self) -> None:
        for runtime, path in REPORTS.items():
            with self.subTest(runtime=runtime):
                report = json.loads(path.read_text())
                self.assertEqual(report["status"], "passed")
                self.assertEqual(
                    report["tuple"], {"platform": "linux", "arch": "x64"}
                )
                self.assertEqual(report["runtime"]["host"], runtime)
                self.assertEqual(
                    report["decision"]["nativePackageCleanInstall"],
                    "authorized-for-declared-runtime-tuple",
                )
                self.assertFalse(report["decision"]["runtimeOwnershipCredit"])
                self.assertFalse(report["decision"]["performanceCredit"])
                self.assertFalse(
                    report["decision"]["applicationPromotionCredit"]
                )
                self.assertFalse(
                    report["installation"]["workspaceLibraryResolution"]
                )

    def test_reviewed_artifact_binds_current_tracked_inputs(self) -> None:
        for runtime, path in REPORTS.items():
            with self.subTest(runtime=runtime):
                report = json.loads(path.read_text())
                for field in ("runner", "wrapperManifest", "platformManifest"):
                    reference = report["implementation"][field]
                    self.assertEqual(
                        reference["sha256"], sha256(ROOT / reference["path"])
                    )
                for field in ("stagedAddon", "stagedBuildMetadata"):
                    reference = report["implementation"][field]
                    implementation_path = ROOT / reference["path"]
                    if implementation_path.exists():
                        self.assertEqual(
                            reference["sha256"], sha256(implementation_path)
                        )

    def test_installed_native_runtime_and_oracle_are_exact(self) -> None:
        for runtime, path in REPORTS.items():
            with self.subTest(runtime=runtime):
                report = json.loads(path.read_text())
                provider = report["receipt"]["provider"]
                self.assertEqual(report["receipt"]["runtimeHost"], runtime)
                self.assertTrue(provider["loaded"])
                self.assertTrue(provider["doeNative"])
                self.assertEqual(provider["buildMetadataSource"], "prebuild")
                self.assertIn(
                    "/node_modules/doe-gpu-linux-x64/",
                    provider["doeLibraryPath"],
                )
                self.assertEqual(
                    report["receipt"]["result"]["output"],
                    [2, 4, 6, 8, 10, 12, 14, 16],
                )
                self.assertEqual(
                    report["receipt"]["result"]["outputSha256"],
                    "9d42cad41af4aaf3ae973e5a48d96f61e4708edc57bf7dd29a497ebd96f506cf",
                )

    def test_bounded_reliability_receipts_cover_fresh_and_concurrent_processes(
        self,
    ) -> None:
        for runtime, path in RELIABILITY_REPORTS.items():
            with self.subTest(runtime=runtime):
                report = json.loads(path.read_text())
                self.assertEqual(report["status"], "passed")
                self.assertEqual(
                    report["tuple"],
                    {"runtime": runtime, "platform": "linux", "arch": "x64"},
                )
                self.assertEqual(report["contract"]["sequentialTrials"], 3)
                self.assertEqual(report["contract"]["concurrentTrials"], 2)
                self.assertEqual(len(report["trials"]), 5)
                self.assertEqual(report["contract"]["lifecycleCycles"], 12)
                self.assertEqual(report["contract"]["lifecycleWarmupCycles"], 2)
                self.assertEqual(
                    [trial["mode"] for trial in report["trials"]].count(
                        "sequential"
                    ),
                    3,
                )
                self.assertEqual(
                    [trial["mode"] for trial in report["trials"]].count(
                        "concurrent"
                    ),
                    2,
                )
                for trial in report["trials"]:
                    self.assertEqual(trial["exitCode"], 0)
                    self.assertIsNone(trial["signal"])
                    self.assertFalse(trial["timedOut"])
                    self.assertFalse(trial["outputLimitExceeded"])
                    self.assertEqual(
                        trial["receipt"]["outputSha256"],
                        "9d42cad41af4aaf3ae973e5a48d96f61e4708edc57bf7dd29a497ebd96f506cf",
                    )
                self.assertEqual(
                    report["decision"]["boundedCleanProcessReliability"],
                    "authorized-for-declared-runtime-tuple",
                )
                self.assertEqual(
                    report["decision"]["boundedSameProcessLifecycle"],
                    "authorized-for-declared-runtime-tuple",
                )
                self.assertEqual(
                    report["decision"]["boundedRssGrowthDiagnostic"],
                    "authorized-for-declared-runtime-tuple",
                )
                lifecycle = report["sameProcessLifecycle"]
                self.assertEqual(lifecycle["exitCode"], 0)
                self.assertIsNone(lifecycle["signal"])
                self.assertFalse(lifecycle["timedOut"])
                self.assertFalse(lifecycle["outputLimitExceeded"])
                self.assertEqual(lifecycle["cycleCount"], 12)
                self.assertEqual(lifecycle["warmupCycles"], 2)
                self.assertLessEqual(
                    lifecycle["postWarmupRssSpanBytes"],
                    lifecycle["maxPostWarmupRssSpanBytes"],
                )
                self.assertEqual(len(lifecycle["samples"]), 12)
                for sample in lifecycle["samples"]:
                    self.assertTrue(sample["deviceDestroyed"])
                    self.assertEqual(sample["lostReason"], "destroyed")
                    self.assertTrue(sample["postDestroyRejected"])
                    self.assertIn(
                        "GPUDevice was destroyed", sample["postDestroyError"]
                    )
                    self.assertEqual(
                        sample["outputSha256"],
                        "9d42cad41af4aaf3ae973e5a48d96f61e4708edc57bf7dd29a497ebd96f506cf",
                    )
                self.assertFalse(report["decision"]["deviceLossCredit"])
                self.assertEqual(
                    report["decision"]["deliberateDestroyLossSemantics"],
                    "authorized-for-declared-runtime-tuple",
                )
                self.assertFalse(report["decision"]["memoryGrowthCredit"])
                self.assertFalse(report["decision"]["performanceCredit"])
                self.assertFalse(
                    report["decision"]["applicationPromotionCredit"]
                )
                for reference in report["implementation"].values():
                    self.assertEqual(
                        reference["sha256"], sha256(ROOT / reference["path"])
                    )


if __name__ == "__main__":
    unittest.main()
