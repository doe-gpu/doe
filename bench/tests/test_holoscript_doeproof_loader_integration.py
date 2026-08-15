from __future__ import annotations

import hashlib
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HARNESS = ROOT / "bench/external-projects/holoscript-snn-webgpu"
REPORT = (
    ROOT
    / "reports/benchmarks/amd-vulkan/20260815T193900Z"
    / "holoscript-doeproof-loader-diagnostic.json"
)
CLI_REPORT = (
    ROOT
    / "reports/benchmarks/amd-vulkan/20260815T200358Z"
    / "holoscript-doeproof-cli-diagnostic.json"
)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class HoloScriptDoeProofLoaderIntegrationTests(unittest.TestCase):
    def test_frozen_plan_preserves_zero_credit_boundary(self) -> None:
        plan = json.loads(
            (HARNESS / "doeproof-loader-integration.plan.json").read_text()
        )
        self.assertEqual(
            plan["planId"], "holoscript-tropical-spmv-doeproof-loader-qm0-v1"
        )
        self.assertEqual(set(plan["lanes"]), {"W0", "D0"})
        self.assertEqual(
            plan["expectedComparableSha256"],
            "51cda2a94da7edad85499240ac8cc5744598fb4227f4f38535a8c97880f585f4",
        )
        self.assertIn("runtime-ownership credit", plan["nonGoals"])
        self.assertIn("performance interpretation", plan["nonGoals"])
        self.assertIn(
            "reinterpretation of the terminal HoloScript ownership decision",
            plan["nonGoals"],
        )

    def test_public_loader_is_the_only_webgpu_substitution_seam(self) -> None:
        runner = (HARNESS / "run-doeproof-loader-integration.mjs").read_text()
        self.assertIn("packages/doe-gpu/src/node-webgpu-loader.js", runner)
        self.assertIn("runGovernedNodeWebGPUProcess", runner)
        self.assertIn("validateGovernedNodeWebGPUProcessReceipt", runner)
        self.assertNotIn("node:child_process", runner)
        self.assertNotIn("provider-loader.mjs", runner)

    def test_reviewed_diagnostic_binds_current_frozen_sources(self) -> None:
        report = json.loads(REPORT.read_text())
        self.assertEqual(report["status"], "passed")
        self.assertEqual(report["decision"]["publicDoeProofLoader"], "authorized")
        self.assertEqual(report["decision"]["publicDoeProofProcess"], "authorized")
        self.assertFalse(report["decision"]["runtimeOwnershipCredit"])
        self.assertFalse(report["decision"]["performanceCredit"])
        self.assertFalse(report["decision"]["releaseCredit"])
        self.assertEqual(
            report["plan"]["sha256"],
            sha256(ROOT / report["plan"]["path"]),
        )
        for field in ("publicLoader", "governedProcessRunner", "runner"):
            reference = report["implementation"][field]
            self.assertEqual(reference["sha256"], sha256(ROOT / reference["path"]))
        evidence_path = ROOT / report["evidence"]["path"]
        if evidence_path.exists():
            self.assertEqual(report["evidence"]["sha256"], sha256(evidence_path))

    def test_cli_plan_and_reviewed_diagnostic_preserve_boundary(self) -> None:
        plan = json.loads(
            (HARNESS / "doeproof-cli-integration.plan.json").read_text()
        )
        self.assertEqual(
            plan["planId"], "holoscript-tropical-spmv-doeproof-cli-qm0-v1"
        )
        self.assertEqual(
            set(plan["commands"]), {"run", "verify", "inspect", "compare", "replay"}
        )
        self.assertIn("runtime-ownership credit", plan["nonGoals"])

        report = json.loads(CLI_REPORT.read_text())
        self.assertEqual(report["status"], "passed")
        self.assertEqual(report["decision"]["publicDoeProofCli"], "authorized")
        self.assertFalse(report["comparison"]["performanceInterpretable"])
        self.assertFalse(report["comparison"]["runtimeOwnershipCredit"])
        self.assertFalse(report["decision"]["runtimeOwnershipCredit"])
        self.assertFalse(report["decision"]["releaseCredit"])
        self.assertEqual(
            report["plan"]["sha256"], sha256(ROOT / report["plan"]["path"])
        )
        for reference in report["implementation"].values():
            self.assertEqual(reference["sha256"], sha256(ROOT / reference["path"]))
        evidence_path = ROOT / report["evidence"]["path"]
        if evidence_path.exists():
            self.assertEqual(report["evidence"]["sha256"], sha256(evidence_path))


if __name__ == "__main__":
    unittest.main()
