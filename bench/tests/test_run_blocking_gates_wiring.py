from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = REPO_ROOT / "bench/runners/run_blocking_gates.py"


def _load_module() -> Any:
    spec = importlib.util.spec_from_file_location("run_blocking_gates", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load module: {MODULE_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class RunBlockingGatesWiringTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = _load_module()

    def test_compare_output_partition_gate_is_enabled_by_default(self) -> None:
        old_argv = sys.argv
        try:
            sys.argv = ["run_blocking_gates.py"]
            args = self.module.parse_args()
        finally:
            sys.argv = old_argv

        self.assertTrue(args.with_compare_output_partition_gate)
        self.assertTrue(args.with_claim_index_gate)
        self.assertTrue(args.with_dawn_replacement_frontier_gate)
        self.assertTrue(args.with_native_backend_coverage_matrix_gate)
        self.assertTrue(args.with_tool_surface_gate)

    def test_compare_output_partition_gate_can_be_disabled_for_diagnostics(self) -> None:
        old_argv = sys.argv
        try:
            sys.argv = [
                "run_blocking_gates.py",
                "--no-with-compare-output-partition-gate",
            ]
            args = self.module.parse_args()
        finally:
            sys.argv = old_argv

        self.assertFalse(args.with_compare_output_partition_gate)

    def test_claim_index_gate_can_be_disabled_for_diagnostics(self) -> None:
        old_argv = sys.argv
        try:
            sys.argv = [
                "run_blocking_gates.py",
                "--no-with-claim-index-gate",
            ]
            args = self.module.parse_args()
        finally:
            sys.argv = old_argv

        self.assertFalse(args.with_claim_index_gate)

    def test_tool_surface_gate_can_be_disabled_for_diagnostics(self) -> None:
        old_argv = sys.argv
        try:
            sys.argv = [
                "run_blocking_gates.py",
                "--no-with-tool-surface-gate",
            ]
            args = self.module.parse_args()
        finally:
            sys.argv = old_argv

        self.assertFalse(args.with_tool_surface_gate)

    def test_dawn_replacement_frontier_gate_can_be_disabled_for_diagnostics(self) -> None:
        old_argv = sys.argv
        try:
            sys.argv = [
                "run_blocking_gates.py",
                "--no-with-dawn-replacement-frontier-gate",
            ]
            args = self.module.parse_args()
        finally:
            sys.argv = old_argv

        self.assertFalse(args.with_dawn_replacement_frontier_gate)

    def test_native_backend_coverage_matrix_gate_can_be_disabled_for_diagnostics(self) -> None:
        old_argv = sys.argv
        try:
            sys.argv = [
                "run_blocking_gates.py",
                "--no-with-native-backend-coverage-matrix-gate",
            ]
            args = self.module.parse_args()
        finally:
            sys.argv = old_argv

        self.assertFalse(args.with_native_backend_coverage_matrix_gate)

    def test_standalone_artifact_checker_gates_are_wired(self) -> None:
        captured: list[tuple[str, list[str]]] = []
        old_argv = sys.argv
        old_run_gate = self.module.run_gate
        old_load_compare_report = self.module.artifacts_mod.load_compare_report
        old_ensure_release = self.module.artifacts_mod.ensure_release_strict_comparability

        def fake_run_gate(label: str, command: list[str]) -> None:
            captured.append((label, command))

        try:
            with tempfile.TemporaryDirectory() as tmp_dir:
                report = Path(tmp_dir) / "compare.json"
                report.write_text("{}", encoding="utf-8")
                sys.argv = [
                    "run_blocking_gates.py",
                    "--report",
                    str(report),
                    "--no-with-tracked-ignore-gate",
                    "--no-with-cross-model-parity-gate",
                    "--no-with-comparability-coherence-gate",
                    "--no-with-compare-output-partition-gate",
                    "--no-with-structural-equivalence-gate",
                    "--with-browser-claim-promotion-receipt-gate",
                    "--browser-claim-promotion-receipt-verify-files-root",
                    ".",
                    "--with-browser-release-artifact-bundle-gate",
                    "--browser-release-artifact-bundle-verify-files-root",
                    ".",
                    "--with-wgsl-lowering-link-receipt-gate",
                    "--wgsl-lowering-link-verify-files-root",
                    ".",
                    "--with-wgsl-minimization-receipt-gate",
                    "--wgsl-minimization-verify-files-root",
                    ".",
                    "--with-wgsl-cts-shader-subset-gate",
                    "--with-wgsl-corpus-materialization-gate",
                    "--wgsl-corpus-materialization-verify-files-root",
                    ".",
                    "--with-native-command-graph-replay-gate",
                    "--native-command-graph-verify-files-root",
                    ".",
                    "--with-native-no-fallback-gate",
                    "--native-no-fallback-verify-files-root",
                    ".",
                    "--with-native-backend-coverage-matrix-gate",
                    "--native-backend-coverage-evidence-root",
                    ".",
                    "--with-browser-capture-policy-gate",
                    "--with-browser-artifact-identity-coverage-gate",
                    "--with-browser-unsupported-reason-taxonomy-gate",
                    "--with-browser-responsibility-map-gate",
                    "--with-chromium-fork-maintenance-policy-gate",
                    "--with-chromium-patch-manifest-gate",
                    "--with-chromium-source-checkout-gate",
                    "--chromium-source-require-runtime-selector",
                    "--with-doe-chromium-proc-surface-gate",
                    "--doe-chromium-proc-surface-library",
                    "runtime/zig/zig-out/lib/libwebgpu_doe_full.dylib",
                    "--with-webgpu-integration-chromium-gate",
                    "--with-browser-runtime-selector-policy-gate",
                    "--with-browser-runtime-identity-gate",
                    "--with-browser-promotion-approvals-gate",
                    "--with-browser-workflow-manifest-gate",
                    "--with-browser-claim-policy-gate",
                    "--with-browser-ownership-gate",
                    "--with-browser-milestones-gate",
                    "--with-browser-smoke-report-gate",
                    "--with-browser-benchmark-superset-gate",
                    "--with-browser-canvas-webgpu-fusion-gate",
                    "--with-browser-cts-subset-gate",
                    "--with-browser-fallback-explanations-gate",
                    "--with-browser-gpu-flight-recorder-replay-gate",
                    "--browser-gpu-flight-replay-out",
                    str(Path(tmp_dir) / "browser-gpu-flight-replay.json"),
                    "--with-browser-gpu-scheduler-gate",
                    "--with-browser-local-ai-workloads-gate",
                    "--with-browser-media-path-probe-gate",
                    "--with-browser-pipeline-cache-receipts-gate",
                    "--with-browser-recovery-parity-gate",
                    "--with-browser-shader-links-gate",
                    "--browser-shader-links-verify-lowering-root",
                    ".",
                    "--with-browser-webgpu-effect-experiment-gate",
                    "--with-native-pipeline-cache-receipts-gate",
                    "--with-native-resource-reuse-receipts-gate",
                    "--with-native-upload-path-receipts-gate",
                    "--with-wgsl-diagnostic-fixtures-gate",
                    "--with-wgsl-robustness-fixtures-gate",
                ]
                self.module.run_gate = fake_run_gate
                self.module.artifacts_mod.load_compare_report = lambda _path: {
                    "comparabilityPolicy": {"mode": "strict"}
                }
                self.module.artifacts_mod.ensure_release_strict_comparability = (
                    lambda _payload, _path, *, surface: None
                )

                self.assertEqual(self.module.main(), 0)
        finally:
            sys.argv = old_argv
            self.module.run_gate = old_run_gate
            self.module.artifacts_mod.load_compare_report = old_load_compare_report
            self.module.artifacts_mod.ensure_release_strict_comparability = old_ensure_release

        commands_by_label = {label: command for label, command in captured}
        self.assertIn("claim-index", commands_by_label)
        self.assertIn("dawn-replacement-frontier", commands_by_label)
        self.assertIn("tool-surface", commands_by_label)
        self.assertIn("browser-claim-promotion-receipt", commands_by_label)
        self.assertIn("browser-release-artifact-bundle", commands_by_label)
        self.assertIn("wgsl-lowering-link-receipt", commands_by_label)
        self.assertIn("wgsl-minimization-receipt", commands_by_label)
        self.assertIn("wgsl-cts-shader-subset", commands_by_label)
        self.assertIn("wgsl-corpus-materialization", commands_by_label)
        self.assertIn("native-command-graph-replay", commands_by_label)
        self.assertIn("native-no-fallback", commands_by_label)
        self.assertIn("native-backend-coverage-matrix", commands_by_label)
        self.assertIn("browser-capture-policy", commands_by_label)
        self.assertIn("browser-artifact-identity-coverage", commands_by_label)
        self.assertIn("browser-unsupported-reason-taxonomy", commands_by_label)
        self.assertIn("browser-responsibility-map", commands_by_label)
        self.assertIn("chromium-fork-maintenance-policy", commands_by_label)
        self.assertIn("chromium-patch-manifest", commands_by_label)
        self.assertIn("chromium-source-checkout", commands_by_label)
        self.assertIn("doe-chromium-proc-surface", commands_by_label)
        self.assertIn("webgpu-integration-chromium", commands_by_label)
        self.assertIn("browser-runtime-selector-policy", commands_by_label)
        self.assertIn("browser-runtime-identity", commands_by_label)
        self.assertIn("browser-promotion-approvals", commands_by_label)
        self.assertIn("browser-workflow-manifest", commands_by_label)
        self.assertIn("browser-claim-policy", commands_by_label)
        self.assertIn("browser-ownership", commands_by_label)
        self.assertIn("browser-milestones", commands_by_label)
        self.assertIn("browser-smoke-report", commands_by_label)
        self.assertIn("browser-benchmark-superset", commands_by_label)
        self.assertIn("browser-canvas-webgpu-fusion", commands_by_label)
        self.assertIn("browser-cts-subset", commands_by_label)
        self.assertIn("browser-fallback-explanations", commands_by_label)
        self.assertIn("browser-gpu-flight-recorder-replay", commands_by_label)
        self.assertIn("browser-gpu-scheduler", commands_by_label)
        self.assertIn("browser-local-ai-workloads", commands_by_label)
        self.assertIn("browser-media-path-probe", commands_by_label)
        self.assertIn("browser-pipeline-cache-receipts", commands_by_label)
        self.assertIn("browser-recovery-parity", commands_by_label)
        self.assertIn("browser-shader-links", commands_by_label)
        self.assertIn("browser-webgpu-effect-experiment", commands_by_label)
        self.assertIn("native-pipeline-cache-receipts", commands_by_label)
        self.assertIn("native-resource-reuse-receipts", commands_by_label)
        self.assertIn("native-upload-path-receipts", commands_by_label)
        self.assertIn("wgsl-diagnostic-fixtures", commands_by_label)
        self.assertIn("wgsl-robustness-fixtures", commands_by_label)

        self.assertIn(
            "bench/gates/claim_index_gate.py",
            commands_by_label["claim-index"][1],
        )
        self.assertIn(
            "bench/gates/dawn_replacement_frontier_gate.py",
            commands_by_label["dawn-replacement-frontier"][1],
        )
        self.assertIn(
            "bench/gates/tool_surface_gate.py",
            commands_by_label["tool-surface"][1],
        )
        self.assertIn(
            "bench/tools/check_browser_claim_promotion_receipt.py",
            commands_by_label["browser-claim-promotion-receipt"][1],
        )
        self.assertIn(
            "--verify-files-root",
            commands_by_label["browser-claim-promotion-receipt"],
        )
        self.assertIn(
            "bench/tools/check_browser_release_artifact_bundle.py",
            commands_by_label["browser-release-artifact-bundle"][1],
        )
        self.assertIn(
            "bench/tools/check_wgsl_lowering_link_receipt.py",
            commands_by_label["wgsl-lowering-link-receipt"][1],
        )
        self.assertIn(
            "--verify-files-root",
            commands_by_label["wgsl-lowering-link-receipt"],
        )
        self.assertIn(
            "--verify-files-root",
            commands_by_label["wgsl-minimization-receipt"],
        )
        self.assertIn(
            "bench/tools/replay_native_command_graph_receipt.py",
            commands_by_label["native-command-graph-replay"][1],
        )
        self.assertIn(
            "--verify-files-root",
            commands_by_label["native-command-graph-replay"],
        )
        self.assertIn(
            "--verify-evidence-root",
            commands_by_label["native-backend-coverage-matrix"],
        )
        self.assertIn(
            "browser/chromium/scripts/check-browser-runtime-selector-policy.py",
            commands_by_label["browser-runtime-selector-policy"][1],
        )
        self.assertIn(
            "bench/tools/check_webgpu_integration_chromium.py",
            commands_by_label["webgpu-integration-chromium"][1],
        )
        self.assertIn(
            "bench/tools/check_chromium_patch_manifest.py",
            commands_by_label["chromium-patch-manifest"][1],
        )
        self.assertIn(
            "--manifest",
            commands_by_label["chromium-patch-manifest"],
        )
        self.assertIn(
            "--root",
            commands_by_label["chromium-patch-manifest"],
        )
        self.assertIn(
            "--overlay",
            commands_by_label["webgpu-integration-chromium"],
        )
        self.assertIn(
            "--verify-artifact-root",
            commands_by_label["webgpu-integration-chromium"],
        )
        self.assertIn(
            "browser/chromium/scripts/check-browser-runtime-identity.py",
            commands_by_label["browser-runtime-identity"][1],
        )
        self.assertIn(
            "--identity",
            commands_by_label["browser-runtime-identity"],
        )
        self.assertIn(
            "browser/chromium/scripts/check-browser-promotion-approvals.py",
            commands_by_label["browser-promotion-approvals"][1],
        )
        self.assertIn(
            "--approvals",
            commands_by_label["browser-promotion-approvals"],
        )
        self.assertIn(
            "--workflows",
            commands_by_label["browser-promotion-approvals"],
        )
        self.assertIn(
            "browser/chromium/scripts/check-browser-workflow-manifest.py",
            commands_by_label["browser-workflow-manifest"][1],
        )
        self.assertIn(
            "--manifest",
            commands_by_label["browser-workflow-manifest"],
        )
        self.assertIn(
            "bench/tools/check_browser_claim_policy.py",
            commands_by_label["browser-claim-policy"][1],
        )
        self.assertIn(
            "--require-ready",
            commands_by_label["chromium-source-checkout"],
        )
        self.assertIn(
            "--require-runtime-selector",
            commands_by_label["chromium-source-checkout"],
        )
        self.assertIn(
            "bench/tools/check_doe_chromium_proc_surface.py",
            commands_by_label["doe-chromium-proc-surface"][1],
        )
        self.assertIn(
            "--require-ready",
            commands_by_label["doe-chromium-proc-surface"],
        )
        self.assertIn(
            "--library",
            commands_by_label["doe-chromium-proc-surface"],
        )
        self.assertIn(
            "--coverage",
            commands_by_label["browser-artifact-identity-coverage"],
        )
        self.assertIn(
            "--taxonomy",
            commands_by_label["browser-unsupported-reason-taxonomy"],
        )
        self.assertIn(
            "--policy",
            commands_by_label["browser-claim-policy"],
        )
        self.assertIn(
            "bench/tools/check_browser_ownership.py",
            commands_by_label["browser-ownership"][1],
        )
        self.assertIn(
            "--ownership",
            commands_by_label["browser-ownership"],
        )
        self.assertIn(
            "browser/chromium/scripts/check-browser-milestones.py",
            commands_by_label["browser-milestones"][1],
        )
        self.assertIn(
            "--manifest",
            commands_by_label["browser-milestones"],
        )
        self.assertIn(
            "browser/chromium/scripts/check-browser-smoke-report.py",
            commands_by_label["browser-smoke-report"][1],
        )
        self.assertIn(
            "browser/chromium/scripts/replay-browser-gpu-flight-recorder.py",
            commands_by_label["browser-gpu-flight-recorder-replay"][1],
        )
        self.assertIn(
            "--capture-policy",
            commands_by_label["browser-gpu-flight-recorder-replay"],
        )
        self.assertIn(
            "--responsibility-map-root",
            commands_by_label["browser-gpu-flight-recorder-replay"],
        )
        self.assertIn(
            "--out",
            commands_by_label["browser-gpu-flight-recorder-replay"],
        )
        self.assertIn(
            "--require-modes",
            commands_by_label["browser-smoke-report"],
        )
        self.assertIn(
            "--capture-policy-root",
            commands_by_label["browser-media-path-probe"],
        )
        self.assertIn(
            "--taxonomy-root",
            commands_by_label["browser-fallback-explanations"],
        )
        for label in (
            "browser-canvas-webgpu-fusion",
            "browser-fallback-explanations",
            "browser-gpu-scheduler",
            "browser-local-ai-workloads",
            "browser-media-path-probe",
            "browser-pipeline-cache-receipts",
            "browser-webgpu-effect-experiment",
        ):
            self.assertIn("--runtime-identity-root", commands_by_label[label])
        self.assertIn(
            "--verify-workloads-root",
            commands_by_label["browser-pipeline-cache-receipts"],
        )
        self.assertIn(
            "bench/tools/check_wgsl_diagnostic_fixtures.py",
            commands_by_label["wgsl-diagnostic-fixtures"][1],
        )
        self.assertIn(
            "--verify-lowering-root",
            commands_by_label["browser-shader-links"],
        )
        self.assertIn(
            "--verify-flight-recorder-root",
            commands_by_label["browser-shader-links"],
        )


if __name__ == "__main__":
    unittest.main()
