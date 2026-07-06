#!/usr/bin/env python3
"""Tests for the Cerebras lane status snapshot reflector."""

from __future__ import annotations

import json
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[2]


class CerebrasStatusSnapshotTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "cerebras_status_snapshot",
            REPO_ROOT / "bench" / "tools" / "cerebras_status_snapshot.py",
        )
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)
        gate_spec = importlib.util.spec_from_file_location(
            "check_cerebras_no_hardware_readiness",
            REPO_ROOT
            / "bench"
            / "tools"
            / "check_cerebras_no_hardware_readiness.py",
        )
        cls.gate_module = importlib.util.module_from_spec(gate_spec)
        gate_spec.loader.exec_module(cls.gate_module)

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())

    def tearDown(self) -> None:
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _write(self, rel: str, payload: dict) -> Path:
        p = self.tmp / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(payload))
        return p

    def test_cross_model_parity_bound(self) -> None:
        self._write(
            self.module.CROSS_MODEL_PARITY,
            {"verdict": "bound", "issues": [], "requiredLanes": ["a", "b"]},
        )
        with mock.patch.object(self.module, "REPO_ROOT", self.tmp):
            row = self.module.cross_model_parity_row()
        self.assertEqual(row["verdict"], "bound")
        self.assertIsNone(row["blocker"])
        self.assertEqual(row["scope"], "requiredLanes=a,b")

    def test_cross_model_parity_with_issues(self) -> None:
        self._write(
            self.module.CROSS_MODEL_PARITY,
            {
                "verdict": "unbound",
                "issues": [{"class": "lane_missing", "detail": "qwen lane absent"}],
            },
        )
        with mock.patch.object(self.module, "REPO_ROOT", self.tmp):
            row = self.module.cross_model_parity_row()
        self.assertEqual(row["verdict"], "unbound")
        self.assertEqual(row["blocker"], "lane_missing")

    def test_per_kernel_summary_blocked_when_any_kernel_unbound(self) -> None:
        dir_rel = self.module.GEMMA_PER_KERNEL_DIR
        self._write(
            f"{dir_rel}/summary.json",
            {
                "kernels": [
                    {"name": "sample", "verdict": "bound"},
                    {"name": "lm_head_prefill", "verdict": "blocked"},
                ],
            },
        )
        self._write(
            f"{dir_rel}/sample.json",
            {"verdict": "bound", "blocker": None},
        )
        self._write(
            f"{dir_rel}/lm_head_prefill.json",
            {"verdict": "blocked", "blocker": "shape_exceeds_d2h_limit"},
        )
        with mock.patch.object(self.module, "REPO_ROOT", self.tmp):
            rows = self.module.per_kernel_rows("gemma", dir_rel)
        summary_row = next(r for r in rows if r["lane"].endswith("summary"))
        self.assertEqual(summary_row["verdict"], "blocked")
        self.assertIn("lm_head_prefill", summary_row["blocker"])
        sample_row = next(r for r in rows if r["lane"].endswith("sample"))
        self.assertEqual(sample_row["verdict"], "bound")
        lm_row = next(r for r in rows if r["lane"].endswith("lm_head_prefill"))
        self.assertEqual(lm_row["verdict"], "blocked")
        self.assertEqual(lm_row["blocker"], "shape_exceeds_d2h_limit")

    def test_per_kernel_dispatch_timed_out_annotation(self) -> None:
        dir_rel = self.module.GEMMA_PER_KERNEL_DIR
        self._write(f"{dir_rel}/summary.json", {"kernels": []})
        self._write(
            f"{dir_rel}/gemv.json",
            {"verdict": "blocked", "blocker": "dispatch_timed_out", "dispatchTimedOut": True},
        )
        with mock.patch.object(self.module, "REPO_ROOT", self.tmp):
            rows = self.module.per_kernel_rows("gemma", dir_rel)
        gemv_row = next(r for r in rows if r["lane"].endswith("gemv"))
        self.assertIn("dispatchTimedOut", gemv_row["blocker"])

    def test_phase7_in_progress_when_last_complete_advances(self) -> None:
        progress_rel = f"{self.module.GEMMA_PHASE7_SESSION_DIR}/progress.jsonl"
        events = [
            {"phase": "hostplan_launch_complete", "launchIndex": 25, "target": "rmsnorm_prefill", "status": "succeeded"},
            {"phase": "hostplan_launch_complete", "launchIndex": 26, "target": "tiled_31b", "status": "succeeded"},
            {"phase": "hostplan_launch_start", "launchIndex": 27, "target": "rope"},
        ]
        p = self.tmp / progress_rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("\n".join(json.dumps(e) for e in events) + "\n")
        with mock.patch.object(self.module, "REPO_ROOT", self.tmp):
            row = self.module.phase7_row()
        self.assertEqual(row["verdict"], "in_progress")
        self.assertIn("lastCompleteLaunch=26", row["blocker"])

    def test_phase7_blocked_when_block_after_last_complete(self) -> None:
        progress_rel = f"{self.module.GEMMA_PHASE7_SESSION_DIR}/progress.jsonl"
        events = [
            {"phase": "hostplan_launch_complete", "launchIndex": 25, "target": "rmsnorm_prefill", "status": "succeeded"},
            {"phase": "hostplan_launch_blocked", "launchIndex": 26, "target": "tiled_31b", "error": "tiled_q4k_gemv_runtime_failed"},
        ]
        p = self.tmp / progress_rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text("\n".join(json.dumps(e) for e in events) + "\n")
        with mock.patch.object(self.module, "REPO_ROOT", self.tmp):
            row = self.module.phase7_row()
        self.assertEqual(row["verdict"], "blocked")
        self.assertIn("launch[26]", row["blocker"])
        self.assertIn("tiled_q4k_gemv_runtime_failed", row["blocker"])

    def test_qwen_multi_token_decode_blocked_when_partial(self) -> None:
        self._write(
            self.module.QWEN_MULTI_TOKEN_DECODE,
            {"boundKernelCount": 0, "kernelCompileDirs": ["a", "b", "c"]},
        )
        with mock.patch.object(self.module, "REPO_ROOT", self.tmp):
            row = self.module.qwen_multi_token_decode_row()
        self.assertEqual(row["verdict"], "blocked")
        self.assertEqual(row["blocker"], "boundKernelCount=0/3")

    def test_qwen_selected_logit_splice_bound(self) -> None:
        self._write(
            self.module.QWEN_SELECTED_LOGIT_SPLICE,
            {
                "verdict": "pass",
                "blockers": [],
                "splicePoint": {
                    "kind": "selected_lm_head_logit",
                    "layerIndex": 63,
                    "promptTokenCount": 18,
                    "selectedTokenId": 760,
                },
                "cslRun": {"logitAbsDiff": 0.01332855},
            },
        )
        with mock.patch.object(self.module, "REPO_ROOT", self.tmp):
            row = self.module.qwen_selected_logit_splice_row()
        self.assertEqual(row["verdict"], "bound")
        self.assertIsNone(row["blocker"])
        self.assertIn("layer=63", row["scope"])
        self.assertIn("token=760", row["scope"])

    def test_qwen_selected_logit_splice_summarizes_topk(self) -> None:
        self._write(
            self.module.QWEN_SELECTED_LOGIT_SPLICE,
            {
                "comparisonMode": "argmax_decision_bound",
                "verdict": "pass",
                "blockers": [],
                "splicePoint": {
                    "kind": "selected_lm_head_logit",
                    "layerIndex": 63,
                    "promptTokenCount": 18,
                    "selectedTokenId": 760,
                    "topK": 5,
                },
                "cslRun": {
                    "topK": 5,
                    "tailKernels": ["final_norm_f16", "lm_head_prefill"],
                    "finalNorm": {
                        "maxAbsDiffVsHostF16": 0.001953125,
                    },
                    "maxLogitAbsDiff": 0.048595428466796875,
                    "decisionMarginLowerBound": 3.5590591430664062,
                },
            },
        )
        with mock.patch.object(self.module, "REPO_ROOT", self.tmp):
            row = self.module.qwen_selected_logit_splice_row()
        self.assertEqual(row["verdict"], "bound")
        self.assertIn("topK=5", row["scope"])
        self.assertIn("tail=final_norm_f16+lm_head_prefill", row["scope"])
        self.assertIn("finalNormMaxAbs=0.00195312", row["scope"])
        self.assertIn("maxLogitAbsDiff=0.0485954", row["scope"])
        self.assertIn("decisionMarginLowerBound=3.55906", row["scope"])
        self.assertIn("mode=argmax_decision_bound", row["scope"])

    def test_qwen_hardware_path_missing_until_returned_trace(self) -> None:
        with mock.patch.object(self.module, "REPO_ROOT", self.tmp):
            row = self.module.qwen_hardware_path_row()
        self.assertEqual(row["verdict"], "hardware_required")
        self.assertEqual(row["blocker"], "hardware_endpoint_required")
        self.assertIn("run_qwen3_6_27b_af16_hardware_path.sh", row["scope"])

    def test_qwen_hardware_path_bound_from_output_ready_trace(self) -> None:
        self._write(
            self.module.QWEN_HARDWARE_TRACE,
            {"status": "output_ready", "blockers": []},
        )
        with mock.patch.object(self.module, "REPO_ROOT", self.tmp):
            row = self.module.qwen_hardware_path_row()
        self.assertEqual(row["verdict"], "bound")
        self.assertIsNone(row["blocker"])

    def test_qwen_frozen_reference_validation_absent_is_typed(self) -> None:
        with mock.patch.object(self.module, "REPO_ROOT", self.tmp):
            row = self.module.qwen_frozen_reference_validation_row()
        self.assertEqual(row["verdict"], "missing")
        self.assertEqual(
            row["blocker"],
            "frozen_reference_validation_receipt_absent",
        )

    def test_qwen_frozen_reference_validation_blocker_class(self) -> None:
        self._write(
            self.module.QWEN_FROZEN_REFERENCE_VALIDATION,
            {
                "verdict": "not_attempted",
                "bound": False,
                "blocker": {"class": "qwen_frozen_reference_fixture_absent"},
            },
        )
        with mock.patch.object(self.module, "REPO_ROOT", self.tmp):
            row = self.module.qwen_frozen_reference_validation_row()
        self.assertEqual(row["verdict"], "not_attempted")
        self.assertEqual(row["blocker"], "qwen_frozen_reference_fixture_absent")

    def test_qwen_local_simfabric_ceiling_row(self) -> None:
        self._write(
            self.module.QWEN_LOCAL_SIMFABRIC_CEILING,
            {
                "verdict": "blocked",
                "blocker": "qwen_prefill_q4k_gemv_blocked",
                "lastPhaseReached": "hostplan_launch_blocked",
            },
        )
        with mock.patch.object(self.module, "REPO_ROOT", self.tmp):
            row = self.module.qwen_local_simfabric_ceiling_row()
        self.assertEqual(row["verdict"], "blocked")
        self.assertEqual(row["blocker"], "qwen_prefill_q4k_gemv_blocked")
        self.assertEqual(row["scope"], "hostplan_launch_blocked")

    def test_bounded_smoke_blocker_count(self) -> None:
        self._write(
            self.module.GEMMA_BOUNDED_SMOKE,
            {
                "status": "blocked",
                "blockers": [
                    {"class": "inference_evidence_gate.dispatch_evidence_lm_head_unbound"},
                    {"class": "manifest_kernel_dispatch_not_bound"},
                    {"class": "real_session_runtime_blocked"},
                ],
            },
        )
        with mock.patch.object(self.module, "REPO_ROOT", self.tmp):
            row = self.module.bounded_smoke_row()
        self.assertEqual(row["verdict"], "blocked")
        self.assertIn("inference_evidence_gate.dispatch_evidence_lm_head_unbound", row["blocker"])
        self.assertIn("(+2 more)", row["blocker"])

    def test_local_simfabric_ceiling_row(self) -> None:
        self._write(
            self.module.GEMMA_LOCAL_SIMFABRIC_CEILING,
            {
                "verdict": "blocked",
                "blocker": "simfabric_d2h_copyback_stall_after_launch_complete",
                "lastPhaseReached": "memcpy_d2h_start",
            },
        )
        with mock.patch.object(self.module, "REPO_ROOT", self.tmp):
            row = self.module.gemma_local_simfabric_ceiling_row()
        self.assertEqual(row["verdict"], "blocked")
        self.assertEqual(
            row["blocker"],
            "simfabric_d2h_copyback_stall_after_launch_complete",
        )
        self.assertEqual(row["scope"], "memcpy_d2h_start")

    def test_qwen_no_hardware_readiness_classified(self) -> None:
        rows = [
            {
                "lane": "compile.cross_model_parity",
                "artifact": "a.json",
                "verdict": "bound",
                "blocker": None,
            },
            {
                "lane": "qwen.doppler_csl_splice.selected_logit",
                "artifact": "b.json",
                "verdict": "bound",
                "blocker": None,
            },
            {
                "lane": "qwen.simfabric_cells",
                "artifact": "c.json",
                "verdict": "pass_with_documented_canary_constraints",
                "blocker": None,
            },
            {
                "lane": "qwen.frozen_reference_validation",
                "artifact": "d.json",
                "verdict": "not_attempted",
                "blocker": "qwen_frozen_reference_fixture_absent",
            },
            {
                "lane": "qwen.per_kernel.summary",
                "artifact": "e.json",
                "verdict": "blocked",
                "blocker": "21/22 kernels not bound",
            },
            {
                "lane": "qwen.local_simfabric_ceiling",
                "artifact": "f.json",
                "verdict": "blocked",
                "blocker": "embed_roi_launch_timeout",
            },
            {
                "lane": "qwen.multi_token_decode",
                "artifact": "g.json",
                "verdict": "blocked",
                "blocker": "boundKernelCount=0/3",
            },
            {
                "lane": "qwen.hardware_full_prompt",
                "artifact": "h.json",
                "verdict": "hardware_required",
                "blocker": "hardware_endpoint_required",
            },
        ]
        readiness = self.module.build_qwen_no_hardware_readiness(rows)
        self.assertEqual(readiness["verdict"], "classified")
        self.assertTrue(readiness["notHardwareClaim"])
        self.assertEqual(readiness["errors"], [])
        self.assertEqual(len(readiness["typedLocalBlockers"]), 4)
        self.assertEqual(len(readiness["hardwareRequiredRows"]), 1)
        self.assertTrue(readiness["nextCommands"])

    def test_no_hardware_gate_accepts_classified_snapshot(self) -> None:
        readiness = {
            "schemaVersion": 1,
            "lane": "qwen.no_hardware_readiness",
            "scope": "qwen3_6_27b_af16_pre_hardware",
            "verdict": "classified",
            "summary": "classified",
            "notHardwareClaim": True,
            "acceptedLocalRows": [
                {"lane": "compile.cross_model_parity"},
                {"lane": "qwen.doppler_csl_splice.selected_logit"},
                {"lane": "qwen.simfabric_cells"},
            ],
            "typedLocalBlockers": [
                {"lane": "qwen.frozen_reference_validation"},
                {"lane": "qwen.per_kernel.summary"},
                {"lane": "qwen.local_simfabric_ceiling"},
                {"lane": "qwen.multi_token_decode"},
            ],
            "hardwareRequiredRows": [
                {
                    "lane": "qwen.hardware_full_prompt",
                    "blocker": "hardware_endpoint_required",
                },
            ],
            "nextCommands": [
                {
                    "lane": "qwen.doppler_csl_splice.selected_logit",
                    "command": "python3 selected.py",
                    "purpose": "refresh selected logit",
                    "hardwareRequired": False,
                },
                {
                    "lane": "qwen.frozen_reference_validation",
                    "command": "python3 frozen.py",
                    "purpose": "refresh frozen reference",
                    "hardwareRequired": False,
                },
                {
                    "lane": "qwen.simfabric_cells",
                    "command": "python3 simfabric.py",
                    "purpose": "refresh simfabric cells",
                    "hardwareRequired": False,
                },
                {
                    "lane": "qwen.no_hardware_readiness",
                    "command": "python3 snapshot.py",
                    "purpose": "refresh snapshot",
                    "hardwareRequired": False,
                },
                {
                    "lane": "qwen.hardware_full_prompt",
                    "command": "run_hardware.sh --cmaddr endpoint",
                    "purpose": "run hardware path",
                    "hardwareRequired": True,
                },
            ],
            "errors": [],
        }
        errors = self.gate_module.validate_readiness(
            {"localReadiness": readiness}
        )
        self.assertEqual(errors, [])

    def test_render_markdown_contains_marker(self) -> None:
        rows = [
            {"lane": "x", "artifact": "a/b.json", "verdict": "bound", "blocker": None, "artifactMtime": "t"},
            {"lane": "y", "artifact": "a/c.json", "verdict": "blocked", "blocker": "z", "artifactMtime": "t"},
        ]
        readiness = {
            "lane": "qwen.no_hardware_readiness",
            "verdict": "classified",
            "scope": "qwen3_6_27b_af16_pre_hardware",
            "summary": "classified",
            "typedLocalBlockers": [
                {
                    "lane": "qwen.per_kernel.summary",
                    "verdict": "blocked",
                    "blocker": "dry_run",
                    "artifact": "a/d.json",
                },
            ],
            "hardwareRequiredRows": [
                {
                    "lane": "qwen.hardware_full_prompt",
                    "verdict": "hardware_required",
                    "blocker": "hardware_endpoint_required",
                    "artifact": "a/e.json",
                },
            ],
            "nextCommands": [
                {
                    "lane": "qwen.no_hardware_readiness",
                    "command": "python3 snapshot.py",
                    "purpose": "refresh",
                    "hardwareRequired": False,
                },
            ],
        }
        md = self.module.render_markdown(rows, "now", readiness)
        self.assertIn("✅ bound", md)
        self.assertIn("❌ blocked", md)
        self.assertIn("Local pre-hardware readiness", md)
        self.assertIn("qwen.no_hardware_readiness", md)
        self.assertIn("Next Commands", md)
        self.assertIn("Gap Rows", md)
        self.assertIn("| Lane | Verdict | Scope | Blocker |", md)
        self.assertIn("`a/b.json`", md)


if __name__ == "__main__":
    unittest.main()
