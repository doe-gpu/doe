from __future__ import annotations

import hashlib
import json
import unittest
from pathlib import Path

import jsonschema


ROOT = Path(__file__).resolve().parents[2]
REPORT_DIR = (
    ROOT / "reports/benchmarks/amd-vulkan/20260828T152721Z"
)
SCHEMA_PATH = ROOT / "config/doe-gpu-native-release-candidate.schema.json"
REPORTS = {
    runtime: REPORT_DIR / f"doe-gpu-{runtime}-native-release-candidate.json"
    for runtime in ("node", "bun", "electron")
}
EXPECTED_OUTPUT_SHA256 = (
    "sha256:9d42cad41af4aaf3ae973e5a48d96f61e4708edc57bf7dd29a497ebd96f506cf"
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class DoeGpuNativeReleaseCandidateTests(unittest.TestCase):
    def test_candidates_validate_and_preserve_tuple_authority(self) -> None:
        schema = json.loads(SCHEMA_PATH.read_text())
        for runtime, path in REPORTS.items():
            with self.subTest(runtime=runtime):
                report = json.loads(path.read_text())
                jsonschema.validate(report, schema)
                self.assertEqual(report["runtime"]["host"], runtime)
                self.assertEqual(
                    report["tuple"], {"platform": "linux", "arch": "x64"}
                )
                self.assertEqual(report["host"]["platform"], "linux")
                self.assertEqual(report["host"]["arch"], "x64")
                self.assertEqual(report["packages"]["wrapper"]["id"], "doe-gpu@0.5.0")
                self.assertEqual(
                    report["packages"]["platform"]["id"],
                    "doe-gpu-linux-x64@0.5.0",
                )
                self.assertEqual(
                    report["decision"]["packageReleaseCandidate"],
                    "eligible-for-declared-runtime-tuple",
                )
                self.assertFalse(report["decision"]["registryPublicationCredit"])
                self.assertFalse(report["decision"]["runtimeOwnershipCredit"])
                self.assertFalse(report["decision"]["performanceCredit"])
                self.assertFalse(report["decision"]["applicationPromotionCredit"])

    def test_candidates_bind_adapter_output_lifecycle_and_replay(self) -> None:
        for runtime, path in REPORTS.items():
            with self.subTest(runtime=runtime):
                report = json.loads(path.read_text())
                governed = report["governedReplay"]
                self.assertTrue(all(governed["matches"].values()))
                self.assertEqual(governed["outputSha256"], EXPECTED_OUTPUT_SHA256)
                adapter = governed["adapterInfo"]
                self.assertEqual(adapter["vendor"], "AMD")
                self.assertEqual(adapter["architecture"], "vulkan")
                if "isFallbackAdapter" in adapter:
                    self.assertFalse(adapter["isFallbackAdapter"])
                self.assertGreater(adapter["vendorID"], 0)
                self.assertGreater(adapter["deviceID"], 0)
                self.assertGreater(adapter["driverVersion"], 0)
                primary = governed["primaryReceipt"]
                replay = governed["replayReceipt"]
                self.assertEqual(primary["replay"], replay["replay"])
                self.assertEqual(primary["adapterInfo"], replay["adapterInfo"])
                self.assertEqual(primary["oracle"], replay["oracle"])
                for receipt in (primary, replay):
                    self.assertEqual(receipt["status"], "pass")
                    self.assertEqual(receipt["checkpoint"], "release-complete")
                    self.assertEqual(receipt["oracle"]["status"], "pass")
                    self.assertEqual(
                        receipt["oracle"]["actualOutputSha256"],
                        EXPECTED_OUTPUT_SHA256,
                    )
                    self.assertEqual(receipt["lifecycle"]["status"], "release-complete")
                    self.assertTrue(receipt["lifecycle"]["globalsRestored"])

    def test_candidates_bind_fresh_reliability_evidence_and_inputs(self) -> None:
        for runtime, path in REPORTS.items():
            with self.subTest(runtime=runtime):
                report = json.loads(path.read_text())
                reliability_ref = report["reliabilityEvidence"]
                reliability_path = ROOT / reliability_ref["path"]
                self.assertEqual(reliability_ref["sha256"], sha256(reliability_path))
                reliability = json.loads(reliability_path.read_text())
                self.assertEqual(reliability["tuple"]["runtime"], runtime)
                self.assertEqual(reliability["status"], "passed")
                self.assertEqual(
                    reliability["packages"]["wrapper"]["sha256"],
                    report["packages"]["wrapper"]["sha256"],
                )
                self.assertEqual(
                    reliability["packages"]["platform"]["sha256"],
                    report["packages"]["platform"]["sha256"],
                )
                self.assertEqual(
                    reliability["decision"]["boundedCleanProcessReliability"],
                    "authorized-for-declared-runtime-tuple",
                )
                self.assertEqual(
                    reliability["decision"]["boundedSameProcessLifecycle"],
                    "authorized-for-declared-runtime-tuple",
                )
                self.assertEqual(
                    reliability["decision"]["deliberateDestroyLossSemantics"],
                    "authorized-for-declared-runtime-tuple",
                )
                for reference in report["implementation"].values():
                    self.assertEqual(reference["sha256"], sha256(ROOT / reference["path"]))


if __name__ == "__main__":
    unittest.main()
