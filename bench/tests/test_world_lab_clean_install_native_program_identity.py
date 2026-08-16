from __future__ import annotations

import hashlib
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PLAN = (
    ROOT
    / "bench/external-projects/world-lab-runtime-webgpu"
    / "package-native-identity-clean-install-qm3.plan.json"
)
PROVIDER = (
    ROOT
    / "bench/external-projects/world-lab-runtime-webgpu"
    / "package-observer-clean-install-provider.mjs"
)
RESULT = (
    ROOT
    / "bench/out/external-projects/world-lab-runtime-webgpu"
    / "world-lab-package-native-identity-clean-install-qm3-v1/result.json"
)
REPORT = (
    ROOT
    / "reports/ecosystem/world-lab-runtime-webgpu"
    / "world-lab-native-program-identity-clean-install-amd-vulkan-2026-08-16-diagnostic.json"
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class WorldLabCleanInstallNativeProgramIdentityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.plan = json.loads(PLAN.read_text())
        cls.result = json.loads(RESULT.read_text())
        cls.report = json.loads(REPORT.read_text())
        cls.registry = json.loads(
            (ROOT / "config/ecosystem-registry.json").read_text()
        )

    def test_successor_preserves_the_unchanged_application_contract(self) -> None:
        self.assertEqual(
            self.plan["predecessor"]["planId"],
            "world-lab-package-compilation-observer-qm2-v1",
        )
        frozen = self.plan["frozenWork"]
        self.assertTrue(frozen["applicationSourceUnchanged"])
        self.assertTrue(frozen["shaderSourceUnchanged"])
        self.assertFalse(frozen["scientificParametersChangedFromQm2"])
        self.assertEqual(frozen["installationScripts"], "disabled")
        self.assertEqual(frozen["optionalDependencies"], "omitted")

    def test_effective_doe_files_resolve_inside_the_clean_install(self) -> None:
        self.assertEqual(self.result["status"], "passed")
        installation = self.result["installation"]
        self.assertEqual(installation["mode"], "local-tarball-clean-install")
        install_root = Path(installation["root"]).resolve()
        for record in installation["installed"].values():
            path = Path(record["path"]).resolve()
            self.assertTrue(path.is_relative_to(install_root))
            self.assertEqual(record["sha256"], sha256(path))
        self.assertEqual(
            installation["providerTemplate"]["sha256"],
            sha256(PROVIDER),
        )
        self.assertEqual(
            installation["installed"]["provider"]["sha256"],
            installation["providerTemplate"]["sha256"],
        )
        for package in installation["packages"].values():
            self.assertEqual(package["sha256"], sha256(Path(package["tarball"])))

        native = self.result["lanes"]["D0"]["nativeIdentity"]
        self.assertTrue(native["runtimeInsideExpectedRoot"])
        self.assertEqual(
            native["runtime"]["sha256"],
            installation["installed"]["platformLibrary"]["sha256"],
        )

    def test_native_identity_and_application_oracle_remain_joined(self) -> None:
        self.assertTrue(self.result["lanes"]["W0"]["success"])
        self.assertTrue(self.result["lanes"]["D0"]["success"])
        native = self.result["lanes"]["D0"]["nativeIdentity"]
        self.assertTrue(native["valid"])
        self.assertEqual(native["validationErrors"], [])
        self.assertTrue(native["dispatchIdentityMatches"])
        self.assertEqual(native["dispatchCount"], 3)
        self.assertEqual(native["submissionCount"], 3)
        self.assertEqual(native["rowCount"], 6)
        self.assertEqual(native["trace"]["sha256"], sha256(Path(native["trace"]["path"])))
        for artifact in native["artifacts"]:
            self.assertEqual(artifact["sha256"], sha256(Path(artifact["path"])))
            self.assertTrue(artifact["spirvValPassed"])

    def test_installed_provider_uses_the_public_package_export(self) -> None:
        source = PROVIDER.read_text()
        self.assertIn("from 'doe-gpu/observe'", source)
        self.assertNotIn("../../../packages/doe-gpu", source)

    def test_credit_boundary_remains_closed(self) -> None:
        adjudication = self.result["adjudication"]
        self.assertTrue(adjudication["cleanInstallPackageIdentity"])
        for field in (
            "runtimeOwnershipDecisionReopened",
            "runtimeOwnershipCredit",
            "performanceCredit",
            "promotionCredit",
            "releaseCredit",
        ):
            self.assertFalse(adjudication[field])

    def test_reviewed_report_and_registry_bind_clean_install_evidence(self) -> None:
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
        self.assertGreaterEqual(
            int(self.registry["registryRevision"]),
            int(self.report["registryRevision"]),
        )
        self.assertEqual(actor["promotionStatus"], "not-promoted")


if __name__ == "__main__":
    unittest.main()
