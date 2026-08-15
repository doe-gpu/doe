from __future__ import annotations

import hashlib
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
REPORT = (
    ROOT
    / "reports/benchmarks/amd-vulkan/20260815T202652Z"
    / "doe-gpu-native-clean-install-diagnostic.json"
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class DoeGpuNativeCleanInstallTests(unittest.TestCase):
    def test_reviewed_artifact_preserves_package_claim_boundary(self) -> None:
        report = json.loads(REPORT.read_text())
        self.assertEqual(report["status"], "passed")
        self.assertEqual(report["tuple"], {"platform": "linux", "arch": "x64"})
        self.assertEqual(
            report["decision"]["nativePackageCleanInstall"],
            "authorized-for-declared-tuple",
        )
        self.assertFalse(report["decision"]["runtimeOwnershipCredit"])
        self.assertFalse(report["decision"]["performanceCredit"])
        self.assertFalse(report["decision"]["applicationPromotionCredit"])
        self.assertFalse(report["installation"]["workspaceLibraryResolution"])

    def test_reviewed_artifact_binds_current_tracked_inputs(self) -> None:
        report = json.loads(REPORT.read_text())
        for field in ("runner", "wrapperManifest", "platformManifest"):
            reference = report["implementation"][field]
            self.assertEqual(reference["sha256"], sha256(ROOT / reference["path"]))
        for field in ("stagedAddon", "stagedBuildMetadata"):
            reference = report["implementation"][field]
            path = ROOT / reference["path"]
            if path.exists():
                self.assertEqual(reference["sha256"], sha256(path))

    def test_installed_native_runtime_and_oracle_are_exact(self) -> None:
        report = json.loads(REPORT.read_text())
        provider = report["receipt"]["provider"]
        self.assertTrue(provider["loaded"])
        self.assertTrue(provider["doeNative"])
        self.assertEqual(provider["buildMetadataSource"], "prebuild")
        self.assertIn("/node_modules/doe-gpu-linux-x64/", provider["doeLibraryPath"])
        self.assertEqual(
            report["receipt"]["result"]["output"],
            [2, 4, 6, 8, 10, 12, 14, 16],
        )
        self.assertEqual(
            report["receipt"]["result"]["outputSha256"],
            "9d42cad41af4aaf3ae973e5a48d96f61e4708edc57bf7dd29a497ebd96f506cf",
        )


if __name__ == "__main__":
    unittest.main()
