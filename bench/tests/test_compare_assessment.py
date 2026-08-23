#!/usr/bin/env python3
"""Tests for per-workload compare assessment obligations."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
if str(BENCH_ROOT) not in sys.path:
    sys.path.insert(0, str(BENCH_ROOT))

from native_compare_modules.comparability import (  # noqa: E402
    CANONICAL_COMPARABILITY_OBLIGATION_IDS,
    compare_assessment,
)


def _sample(*, backend: str, command_replay_ns: int) -> dict:
    return {
        "runIndex": 0,
        "measuredMs": 1.0,
        "timingSource": "doe-execution-total-ns",
        "timingClass": "operation",
        "timing": {
            "traceMetaSource": "doe-execution-total-ns",
        },
        "traceMeta": {
            "executionBackend": backend,
            "executionTotalNs": 10_000_000,
            "executionSetupTotalNs": 2_000_000,
            "executionEncodeTotalNs": 1_000_000,
            "executionSubmitWaitTotalNs": 7_000_000,
            "executionDispatchCount": 1,
            "executionSubmitCount": 1,
            "executionRowCount": 3,
            "executionSuccessCount": 3,
            "queueSyncMode": "per-command",
            "packageStepBreakdownNs": {
                "submitAddonCommandReplayTotalNs": command_replay_ns,
                "submitAddonFlushTotalNs": 0,
                "submitQueueWaitTotalNs": 0,
            },
            "shaderSourceReceiptsHash": "a" * 64,
            "shaderSourceReceipts": [
                {
                    "moduleId": "main",
                    "sourceKind": "path",
                    "path": "bench/kernels/main.wgsl",
                    "entryPoint": "main",
                    "byteLength": 1,
                    "sha256": "b" * 64,
                }
            ],
            "adapterInfo": {
                "vendor": "apple",
                "device": "Apple M3",
                "architecture": "M3",
                "description": "Apple M3",
            },
        },
    }


def _wall_coverage_sample(
    *,
    backend: str,
    measured_ms: float,
    elapsed_ms: float,
) -> dict:
    sample = _sample(backend=backend, command_replay_ns=0)
    sample["measuredMs"] = measured_ms
    sample["elapsedMs"] = elapsed_ms
    sample["timing"]["workloadUnitNormalizationDivisor"] = 1.0
    return sample


def _provider_result_sample(*, backend: str, digest: str) -> dict:
    return {
        "runIndex": 0,
        "measuredMs": 100.0,
        "elapsedMs": 100.0,
        "timingSource": "wall-time",
        "timingClass": "process-wall",
        "timing": {
            "workloadUnitNormalizationDivisor": 1.0,
        },
        "traceMeta": {
            "executionBackend": backend,
            "executionRowCount": 1,
            "executionSuccessCount": 1,
            "executionErrorCount": 0,
            "processWallMs": 100.0,
            "workloadUnitWallSource": "trace-meta-process-wall",
            "resultSummary": {
                "generatedTextLength": 5,
                "generatedTextSha256": digest,
            },
        },
    }


class CompareAssessmentTests(unittest.TestCase):
    def test_result_output_mismatch_blocks_strict_provider_compare(self) -> None:
        result = compare_assessment(
            workload_id="doppler_provider_compare",
            workload_comparable=True,
            workload_domain="compute",
            workload_api="webgpu",
            workload_commands_path="",
            workload_path_asymmetry=False,
            workload_path_asymmetry_note="",
            baseline_command_repeat=1,
            comparison_command_repeat=1,
            baseline={
                "commandSamples": [
                    _provider_result_sample(
                        backend="doppler_node_webgpu_doe",
                        digest="a" * 64,
                    )
                ],
            },
            comparison={
                "commandSamples": [
                    _provider_result_sample(
                        backend="doppler_node_webgpu_incumbent",
                        digest="b" * 64,
                    )
                ],
            },
            required_timing_class="process-wall",
            allow_baseline_no_execution=False,
            resource_probe="none",
            comparability_mode="strict",
            resource_sample_target_count=0,
        )

        self.assertFalse(result["comparable"])
        self.assertIn(
            "baseline_comparison_result_output_match",
            result["blockingFailedObligations"],
        )
        emitted_ids = [item["id"] for item in result["obligations"]]
        self.assertEqual(
            [],
            [
                obligation_id
                for obligation_id in emitted_ids
                if obligation_id not in CANONICAL_COMPARABILITY_OBLIGATION_IDS
            ],
        )

    def test_submit_scope_mismatch_blocks_strict_package_totals(self) -> None:
        result = compare_assessment(
            workload_id="package_upload_readback",
            workload_comparable=True,
            workload_domain="upload-readback",
            workload_api="webgpu",
            workload_commands_path="",
            workload_path_asymmetry=False,
            workload_path_asymmetry_note="",
            baseline_command_repeat=1,
            comparison_command_repeat=1,
            baseline={
                "commandSamples": [
                    _sample(backend="doe_node_webgpu", command_replay_ns=2_000_000)
                    for _ in range(7)
                ],
            },
            comparison={
                "commandSamples": [
                    _sample(backend="node_webgpu_package", command_replay_ns=0)
                    for _ in range(7)
                ],
            },
            required_timing_class="operation",
            allow_baseline_no_execution=False,
            resource_probe="none",
            comparability_mode="strict",
            resource_sample_target_count=0,
        )

        self.assertFalse(result["comparable"])
        self.assertIn(
            "baseline_comparison_submit_scope_match",
            result["blockingFailedObligations"],
        )
        self.assertNotIn(
            "baseline_comparison_submit_scope_match",
            result["advisoryFailedObligations"],
        )

    def test_timing_plausibility_allows_symmetric_low_operation_coverage(self) -> None:
        result = compare_assessment(
            workload_id="package_image_rgba_invert_1024",
            workload_comparable=True,
            workload_domain="surface",
            workload_api="webgpu",
            workload_commands_path="",
            workload_path_asymmetry=False,
            workload_path_asymmetry_note="",
            baseline_command_repeat=1,
            comparison_command_repeat=1,
            baseline={
                "commandSamples": [
                    _wall_coverage_sample(
                        backend="doe_bun_package",
                        measured_ms=0.05,
                        elapsed_ms=10.0,
                    )
                    for _ in range(7)
                ],
            },
            comparison={
                "commandSamples": [
                    _wall_coverage_sample(
                        backend="bun_webgpu_package",
                        measured_ms=0.06,
                        elapsed_ms=12.0,
                    )
                    for _ in range(7)
                ],
            },
            required_timing_class="operation",
            allow_baseline_no_execution=False,
            resource_probe="none",
            comparability_mode="strict",
            resource_sample_target_count=0,
        )

        self.assertTrue(result["comparable"], result["reasons"])
        self.assertNotIn(
            "baseline_comparison_timing_plausibility",
            result["blockingFailedObligations"],
        )

    def test_timing_plausibility_blocks_asymmetric_low_operation_coverage(self) -> None:
        result = compare_assessment(
            workload_id="package_image_rgba_invert_1024",
            workload_comparable=True,
            workload_domain="surface",
            workload_api="webgpu",
            workload_commands_path="",
            workload_path_asymmetry=False,
            workload_path_asymmetry_note="",
            baseline_command_repeat=1,
            comparison_command_repeat=1,
            baseline={
                "commandSamples": [
                    _wall_coverage_sample(
                        backend="doe_bun_package",
                        measured_ms=0.05,
                        elapsed_ms=10.0,
                    )
                    for _ in range(7)
                ],
            },
            comparison={
                "commandSamples": [
                    _wall_coverage_sample(
                        backend="bun_webgpu_package",
                        measured_ms=0.75,
                        elapsed_ms=12.0,
                    )
                    for _ in range(7)
                ],
            },
            required_timing_class="operation",
            allow_baseline_no_execution=False,
            resource_probe="none",
            comparability_mode="strict",
            resource_sample_target_count=0,
        )

        self.assertFalse(result["comparable"])
        self.assertIn(
            "baseline_comparison_timing_plausibility",
            result["blockingFailedObligations"],
        )

    def test_timing_plausibility_blocks_selected_timing_above_normalized_wall(self) -> None:
        result = compare_assessment(
            workload_id="inference_gemma3_270m_prefill_64tok_decode_64tok",
            workload_comparable=True,
            workload_domain="compute",
            workload_api="webgpu",
            workload_commands_path="",
            workload_path_asymmetry=False,
            workload_path_asymmetry_note="",
            baseline_command_repeat=1,
            comparison_command_repeat=1,
            baseline={
                "commandSamples": [
                    _wall_coverage_sample(
                        backend="doe_node_webgpu",
                        measured_ms=105.0,
                        elapsed_ms=0.09,
                    )
                    for _ in range(7)
                ],
            },
            comparison={
                "commandSamples": [
                    _wall_coverage_sample(
                        backend="node_webgpu_package",
                        measured_ms=125.0,
                        elapsed_ms=0.11,
                    )
                    for _ in range(7)
                ],
            },
            required_timing_class="operation",
            allow_baseline_no_execution=False,
            resource_probe="none",
            comparability_mode="strict",
            resource_sample_target_count=0,
        )

        self.assertFalse(result["comparable"])
        self.assertIn(
            "baseline_comparison_timing_plausibility",
            result["blockingFailedObligations"],
        )
        obligation = next(
            item
            for item in result["obligations"]
            if item["id"] == "baseline_comparison_timing_plausibility"
        )
        self.assertTrue(obligation["details"]["baselineSelectedTimingExceedsWall"])
        self.assertTrue(obligation["details"]["comparisonSelectedTimingExceedsWall"])

    def test_submit_count_mismatch_blocks_execution_shape_match(self) -> None:
        baseline_sample = _sample(backend="doe_vulkan", command_replay_ns=0)
        comparison_sample = _sample(backend="dawn_delegate", command_replay_ns=0)
        baseline_sample["traceMeta"]["executionDispatchCount"] = 100
        comparison_sample["traceMeta"]["executionDispatchCount"] = 100
        baseline_sample["traceMeta"]["executionSubmitCount"] = 2
        comparison_sample["traceMeta"]["executionSubmitCount"] = 1

        result = compare_assessment(
            workload_id="compute_matvec_32768x2048_f32",
            workload_comparable=True,
            workload_domain="compute",
            workload_api="vulkan",
            workload_commands_path="examples/matrix_vector_mul_32768x2048_commands.json",
            workload_path_asymmetry=False,
            workload_path_asymmetry_note="",
            baseline_command_repeat=1,
            comparison_command_repeat=1,
            baseline={"commandSamples": [baseline_sample]},
            comparison={"commandSamples": [comparison_sample]},
            required_timing_class="operation",
            allow_baseline_no_execution=False,
            resource_probe="none",
            comparability_mode="strict",
            resource_sample_target_count=0,
        )

        self.assertFalse(result["comparable"])
        self.assertIn(
            "baseline_comparison_execution_shape_match",
            result["blockingFailedObligations"],
        )

    def test_shader_source_receipt_mismatch_blocks_strict_package_compare(self) -> None:
        baseline_sample = _sample(backend="doe_node_webgpu", command_replay_ns=0)
        comparison_sample = _sample(backend="node_webgpu_package", command_replay_ns=0)
        comparison_sample["traceMeta"]["shaderSourceReceiptsHash"] = "c" * 64

        result = compare_assessment(
            workload_id="inference_gemma3_270m_prefill_64tok_decode_64tok",
            workload_comparable=True,
            workload_domain="compute",
            workload_api="webgpu",
            workload_commands_path="bench/plans/generated/compat/inference_commands.json",
            workload_path_asymmetry=False,
            workload_path_asymmetry_note="",
            baseline_command_repeat=1,
            comparison_command_repeat=1,
            baseline={"commandSamples": [baseline_sample]},
            comparison={"commandSamples": [comparison_sample]},
            required_timing_class="operation",
            allow_baseline_no_execution=False,
            resource_probe="none",
            comparability_mode="strict",
            resource_sample_target_count=0,
        )

        self.assertFalse(result["comparable"])
        self.assertIn(
            "baseline_comparison_shader_source_receipts_match",
            result["blockingFailedObligations"],
        )


if __name__ == "__main__":
    unittest.main()
