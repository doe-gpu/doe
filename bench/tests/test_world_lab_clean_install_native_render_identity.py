from __future__ import annotations

import hashlib
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HARNESS = ROOT / "bench/external-projects/world-lab-runtime-webgpu"
PLAN = HARNESS / "package-native-render-identity-clean-install-qm5.plan.json"
FAILURE = HARNESS / "failures/render-completion-boundary.failure.json"
RESULT = (
    ROOT
    / "bench/out/external-projects/world-lab-runtime-webgpu"
    / "world-lab-package-native-render-identity-clean-install-qm5-v1-retry1/result.json"
)
Q4_RESULT = (
    ROOT
    / "bench/out/external-projects/world-lab-runtime-webgpu"
    / "world-lab-package-native-render-identity-clean-install-qm4-v1/result.json"
)
REPORT = (
    ROOT
    / "reports/ecosystem/world-lab-runtime-webgpu"
    / "world-lab-native-render-identity-clean-install-amd-vulkan-2026-08-16-diagnostic.json"
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class WorldLabCleanInstallNativeRenderIdentityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.plan = json.loads(PLAN.read_text())
        cls.result = json.loads(RESULT.read_text())
        cls.q4_result = json.loads(Q4_RESULT.read_text())
        cls.failure = json.loads(FAILURE.read_text())
        cls.report = json.loads(REPORT.read_text())
        cls.registry = json.loads(
            (ROOT / "config/ecosystem-registry.json").read_text()
        )

    def test_q5_is_a_correction_only_successor_to_the_preserved_q4_failure(self) -> None:
        predecessor = self.plan["predecessor"]
        self.assertEqual(
            predecessor["planId"],
            "world-lab-package-native-render-identity-clean-install-qm4-v1",
        )
        self.assertEqual(predecessor["status"], "failed")
        self.assertEqual(predecessor["failureClass"], "contract-model mismatch")
        self.assertFalse(
            self.plan["frozenWork"]["scientificParametersChangedFromQm4"]
        )
        self.assertEqual(self.q4_result["status"], "failed")
        self.assertEqual(
            self.q4_result["lanes"]["D0"]["nativeIdentity"]["validationErrors"],
            [
                "render draw lacks later submission: 648458/1",
                "render draw lacks later submission: 648458/2",
            ],
        )

    def test_compute_and_render_identity_are_joined_to_successful_completion(self) -> None:
        self.assertEqual(self.result["status"], "passed")
        self.assertTrue(self.result["lanes"]["W0"]["success"])
        self.assertTrue(self.result["lanes"]["D0"]["success"])
        native = self.result["lanes"]["D0"]["nativeIdentity"]
        self.assertTrue(native["valid"])
        self.assertEqual(native["validationErrors"], [])
        self.assertTrue(native["dispatchIdentityMatches"])
        self.assertTrue(native["renderIdentityMatches"])
        self.assertTrue(native["renderCompletionIdentityMatches"])
        self.assertEqual(native["dispatchCount"], 3)
        self.assertEqual(native["renderDrawCount"], 2)
        self.assertEqual(native["submissionCount"], 3)
        self.assertEqual(native["rowCount"], 8)

        rows = [
            json.loads(line)
            for line in Path(native["trace"]["path"]).read_text().splitlines()
            if line.strip()
        ]
        render_rows = [row for row in rows if row["event"] == "render_draw_executed"]
        self.assertEqual(len(render_rows), 2)
        self.assertTrue(
            all(
                row["completion"] == "internal_submit_and_wait_succeeded"
                for row in render_rows
            )
        )

    def test_clean_install_and_all_materialized_artifacts_are_hash_bound(self) -> None:
        installation = self.result["installation"]
        install_root = Path(installation["root"]).resolve()
        for record in installation["installed"].values():
            path = Path(record["path"]).resolve()
            self.assertTrue(path.is_relative_to(install_root))
            self.assertEqual(record["sha256"], sha256(path))
        for package in installation["packages"].values():
            self.assertEqual(package["sha256"], sha256(Path(package["tarball"])))

        native = self.result["lanes"]["D0"]["nativeIdentity"]
        self.assertEqual(native["trace"]["sha256"], sha256(Path(native["trace"]["path"])))
        self.assertEqual(native["runtime"]["sha256"], sha256(Path(native["runtime"]["path"])))
        self.assertEqual(
            {artifact["stage"] for artifact in native["artifacts"]},
            {"compute", "vertex", "fragment"},
        )
        for artifact in native["artifacts"]:
            self.assertEqual(artifact["sha256"], sha256(Path(artifact["path"])))
            self.assertTrue(artifact["spirvValPassed"])

    def test_failure_record_binds_rejection_and_correction(self) -> None:
        self.assertEqual(self.failure["status"], "fixed-regression-protected")
        references = self.failure["failureEvidence"]
        self.assertEqual(references[0]["sha256"], sha256(Q4_RESULT))
        self.assertEqual(references[1]["sha256"], sha256(RESULT))

    def test_credit_boundary_remains_closed(self) -> None:
        adjudication = self.result["adjudication"]
        self.assertTrue(adjudication["nativeRenderIdentity"])
        self.assertTrue(adjudication["nativeRenderCompletionIdentity"])
        for field in (
            "runtimeOwnershipDecisionReopened",
            "runtimeOwnershipCredit",
            "performanceCredit",
            "promotionCredit",
            "releaseCredit",
        ):
            self.assertFalse(adjudication[field])

    def test_reviewed_report_and_registry_bind_q5_evidence(self) -> None:
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
        self.assertIn(
            "bench/external-projects/world-lab-runtime-webgpu/failures/render-completion-boundary.failure.json",
            actor["failureRecords"],
        )


if __name__ == "__main__":
    unittest.main()
