#!/usr/bin/env python3
"""Regression coverage for kernel prewarm timing in native compare claims."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
if str(BENCH_ROOT) not in sys.path:
    sys.path.insert(0, str(BENCH_ROOT))

from native_compare_modules.comparability import assess_timing_phase_equivalence
from native_compare_modules.timing_selection import pick_measured_timing_ms


def _sample(
    *,
    source: str,
    execution_total_ns: int,
    setup_ns: int,
    host_kernel_prewarm_ns: int,
) -> dict:
    return {
        "timingSource": source,
        "timing": {"traceMetaSource": source},
        "traceMeta": {
            "executionTotalNs": execution_total_ns,
            "executionSetupTotalNs": setup_ns,
            "executionEncodeTotalNs": 1_000_000,
            "executionSubmitWaitTotalNs": max(0, execution_total_ns - setup_ns - 1_000_000),
            "hostKernelPrewarmTotalNs": host_kernel_prewarm_ns,
        },
    }


class KernelPrewarmTimingTests(unittest.TestCase):
    def test_render_timing_selects_encode_when_encode_share_is_small(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            trace_path = Path(tmpdir) / "trace.ndjson"
            trace_path.write_text('{"command":"render_draw"}\n', encoding="utf-8")
            measured_ms, source, meta = pick_measured_timing_ms(
                wall_ms=20.0,
                trace_meta={
                    "timingMs": 10.0,
                    "timingSource": "doe-execution-total-ns",
                    "executionTotalNs": 10_000_000,
                    "executionSetupTotalNs": 4_900_000,
                    "executionEncodeTotalNs": 100_000,
                    "executionSubmitWaitTotalNs": 5_000_000,
                    "executionDispatchCount": 2_000,
                    "executionRowCount": 1,
                    "executionSuccessCount": 1,
                },
                trace_jsonl=trace_path,
                required_timing_class="operation",
                benchmark_policy=None,
                workload_domain="render",
            )

        self.assertEqual(measured_ms, 0.1)
        self.assertEqual(source, "doe-execution-encode-ns")
        self.assertEqual(meta["timingSelectionPolicy"], "render-encode-preferred")

    def test_operation_timing_keeps_host_kernel_prewarm_outside_selected_timing(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            trace_path = Path(tmpdir) / "trace.ndjson"
            trace_path.write_text('{"command":"kernel_dispatch"}\n', encoding="utf-8")
            measured_ms, source, meta = pick_measured_timing_ms(
                wall_ms=20.0,
                trace_meta={
                    "timingMs": 10.0,
                    "timingSource": "doe-execution-total-ns",
                    "executionTotalNs": 10_000_000,
                    "executionSetupTotalNs": 0,
                    "executionEncodeTotalNs": 1_000_000,
                    "executionSubmitWaitTotalNs": 9_000_000,
                    "executionDispatchCount": 1,
                    "executionRowCount": 1,
                    "executionSuccessCount": 1,
                    "hostKernelPrewarmTotalNs": 2_000_000,
                },
                trace_jsonl=trace_path,
                required_timing_class="operation",
                benchmark_policy=None,
                workload_domain="compute",
            )

        self.assertEqual(measured_ms, 10.0)
        self.assertEqual(source, "doe-execution-total-ns")
        self.assertEqual(meta["hostKernelPrewarmTotalNs"], 2_000_000)
        self.assertEqual(meta["hostKernelPrewarmScope"], "outside-selected-execution-timing")
        self.assertNotIn("operationTotalWithHostKernelPrewarmNs", meta)

    def test_operation_timing_ignores_empty_kernel_prewarm_loop(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            trace_path = Path(tmpdir) / "trace.ndjson"
            trace_path.write_text('{"command":"copy_buffer_to_texture"}\n', encoding="utf-8")
            measured_ms, source, meta = pick_measured_timing_ms(
                wall_ms=20.0,
                trace_meta={
                    "timingMs": 10.0,
                    "timingSource": "doe-execution-total-ns",
                    "executionTotalNs": 10_000_000,
                    "executionSetupTotalNs": 100_000,
                    "executionEncodeTotalNs": 1_000_000,
                    "executionSubmitWaitTotalNs": 8_900_000,
                    "executionRowCount": 1,
                    "executionSuccessCount": 1,
                    "hostKernelPrewarmTotalNs": 2_000_000,
                },
                trace_jsonl=trace_path,
                required_timing_class="operation",
                benchmark_policy=None,
                workload_domain="copy",
            )

        self.assertEqual(measured_ms, 10.0)
        self.assertEqual(source, "doe-execution-total-ns")
        self.assertNotIn("operationTotalWithHostKernelPrewarmNs", meta)

    def test_phase_equivalence_counts_folded_prewarm_as_setup(self) -> None:
        left = [
            _sample(
                source="doe-execution-total-ns+host-kernel-prewarm",
                execution_total_ns=10_000_000,
                setup_ns=0,
                host_kernel_prewarm_ns=2_000_000,
            )
            for _ in range(3)
        ]
        right = [
            _sample(
                source="doe-execution-total-ns",
                execution_total_ns=12_000_000,
                setup_ns=2_000_000,
                host_kernel_prewarm_ns=0,
            )
            for _ in range(3)
        ]

        applies, passes, details, reason = assess_timing_phase_equivalence(
            left_command_samples=left,
            right_command_samples=right,
        )

        self.assertTrue(applies)
        self.assertTrue(passes, reason)
        self.assertEqual(details["phaseMismatchCount"], 0)

    def test_phase_equivalence_rejects_unfolded_prewarm(self) -> None:
        left = [
            _sample(
                source="doe-execution-total-ns",
                execution_total_ns=10_000_000,
                setup_ns=0,
                host_kernel_prewarm_ns=2_000_000,
            )
            for _ in range(3)
        ]
        right = [
            _sample(
                source="doe-execution-total-ns",
                execution_total_ns=12_000_000,
                setup_ns=2_000_000,
                host_kernel_prewarm_ns=0,
            )
            for _ in range(3)
        ]

        applies, passes, details, reason = assess_timing_phase_equivalence(
            left_command_samples=left,
            right_command_samples=right,
        )

        self.assertTrue(applies)
        self.assertFalse(passes)
        self.assertEqual(details["phaseMismatchCount"], 1)
        self.assertIn("executionSetupTotalNs", reason)


if __name__ == "__main__":
    unittest.main()
