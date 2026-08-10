#!/usr/bin/env python3
"""Tests for benchmark IR loading and normalized plan materialization."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from bench.lib import benchmark_ir


class BenchmarkIrTests(unittest.TestCase):
    def test_materialize_plan_expands_repeat_and_counts_commands(self) -> None:
        payload = {
            "schemaVersion": 1,
            "kind": "benchmark_ir",
            "description": "test ir",
            "scenarios": [
                {
                    "id": "alpha",
                    "description": "alpha scenario",
                    "irPath": "bench/ir/test.json",
                    "planPath": "bench/plans/generated/alpha.plan.json",
                    "commandsPath": "bench/plans/generated/compat/alpha_commands.json",
                    "commands": [
                        {"kind": "buffer_write", "handle": 1, "bufferSize": 16, "data": [1, 2, 3, 4]},
                        {
                            "kind": "repeat",
                            "count": 2,
                            "commands": [
                                {
                                    "kind": "kernel_dispatch",
                                    "kernel": "rmsnorm.wgsl",
                                    "x": 1,
                                    "y": 1,
                                    "z": 1,
                                    "bindings": [],
                                }
                            ],
                        },
                    ],
                }
            ],
        }
        with tempfile.TemporaryDirectory(prefix="doe-benchmark-ir-") as tmpdir:
            ir_path = Path(tmpdir) / "test_ir.json"
            ir_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
            plan = benchmark_ir.materialize_plan(ir_path, "alpha")

        self.assertEqual(plan["workloadId"], "alpha")
        self.assertEqual(plan["commandCount"], 3)
        self.assertEqual(plan["bufferWriteCount"], 1)
        self.assertEqual(plan["dispatchCount"], 2)
        self.assertEqual(
            [command["kind"] for command in plan["commands"]],
            ["buffer_write", "kernel_dispatch", "kernel_dispatch"],
        )
        self.assertTrue(plan["planSha256"])
        self.assertTrue(plan["compatibilityCommandsSha256"])

    def test_scenario_output_oracle_binds_final_expanded_dispatch(self) -> None:
        oracle = {
            "schema_version": 2,
            "scope": "command_graph",
            "reference_class": "independent_v1",
            "kind": "sha256_exact_v1",
            "initialization": "zero_fill_v1",
            "binding_group": 0,
            "binding": 0,
            "dispatch_count": 1,
            "expected_sha256": "a" * 64,
            "reference_id": "unit-test",
        }
        payload = {
            "schemaVersion": 1,
            "kind": "benchmark_ir",
            "scenarios": [
                {
                    "id": "alpha",
                    "description": "alpha scenario",
                    "planPath": "bench/plans/generated/alpha.plan.json",
                    "commandsPath": (
                        "bench/plans/generated/compat/alpha_commands.json"
                    ),
                    "outputOracle": oracle,
                    "commands": [
                        {
                            "kind": "repeat",
                            "count": 2,
                            "commands": [
                                {
                                    "kind": "kernel_dispatch",
                                    "kernel": "alpha.wgsl",
                                    "x": 1,
                                    "y": 1,
                                    "z": 1,
                                    "bindings": [],
                                }
                            ],
                        }
                    ],
                }
            ],
        }
        with tempfile.TemporaryDirectory(prefix="doe-benchmark-ir-") as tmpdir:
            ir_path = Path(tmpdir) / "test_ir.json"
            ir_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
            plan = benchmark_ir.materialize_plan(ir_path, "alpha")

        self.assertNotIn("output_oracle", plan["commands"][0])
        self.assertEqual(plan["commands"][1]["output_oracle"], oracle)

    def test_materialize_plan_injects_deterministic_buffer_loads_for_readonly_weights(self) -> None:
        payload = {
            "schemaVersion": 1,
            "kind": "benchmark_ir",
            "description": "test ir",
            "shared": {
                "syntheticReadonlyBufferPolicy": {
                    "cacheNamespace": "unit_test",
                    "generator": "splitmix64_f32_nonzero_v1",
                    "seed": 7,
                    "scale": 0.125,
                }
            },
            "scenarios": [
                {
                    "id": "alpha",
                    "description": "alpha scenario",
                    "irPath": "bench/ir/test.json",
                    "planPath": "bench/plans/generated/alpha.plan.json",
                    "commandsPath": "bench/plans/generated/compat/alpha_commands.json",
                    "commands": [
                        {"kind": "buffer_write", "handle": 10, "bufferSize": 16, "data": [1, 2, 3, 4]},
                        {
                            "kind": "kernel_dispatch",
                            "kernel": "alpha.wgsl",
                            "x": 1,
                            "y": 1,
                            "z": 1,
                            "bindings": [
                                {"binding": 0, "resource_handle": 10, "buffer_size": 16, "buffer_type": "uniform"},
                                {"binding": 1, "resource_handle": 20, "buffer_size": 64, "buffer_type": "readonly"},
                                {"binding": 2, "resource_handle": 21, "buffer_size": 64, "buffer_type": "storage"},
                            ],
                        },
                    ],
                }
            ],
        }
        with tempfile.TemporaryDirectory(prefix="doe-benchmark-ir-") as tmpdir:
            ir_path = Path(tmpdir) / "test_ir.json"
            ir_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
            plan = benchmark_ir.materialize_plan(ir_path, "alpha")

        self.assertEqual(plan["commandCount"], 3)
        self.assertEqual(plan["bufferWriteCount"], 1)
        self.assertEqual(plan["bufferLoadCount"], 1)
        self.assertEqual(plan["dispatchCount"], 1)
        self.assertEqual(
            [command["kind"] for command in plan["commands"]],
            ["buffer_write", "buffer_load", "kernel_dispatch"],
        )
        buffer_load = plan["commands"][1]
        self.assertEqual(buffer_load["handle"], 20)
        self.assertEqual(buffer_load["bufferSize"], 64)
        self.assertEqual(buffer_load["byteLength"], 64)
        self.assertEqual(buffer_load["cacheNamespace"], "unit_test")
        self.assertEqual(buffer_load["generator"], "splitmix64_f32_nonzero_v1")
        self.assertTrue(buffer_load["cacheKey"])

    def test_materialize_plan_rejects_partial_gemv_dispatch(self) -> None:
        payload = {
            "schemaVersion": 1,
            "kind": "benchmark_ir",
            "description": "test ir",
            "scenarios": [
                {
                    "id": "alpha",
                    "description": "alpha scenario",
                    "irPath": "bench/ir/test.json",
                    "planPath": "bench/plans/generated/alpha.plan.json",
                    "commandsPath": "bench/plans/generated/compat/alpha_commands.json",
                    "commands": [
                        {"kind": "buffer_write", "handle": 1, "bufferSize": 16, "data": [64, 16, 0, 0]},
                        {
                            "kind": "kernel_dispatch",
                            "kernel": "matmul-gemv.wgsl",
                            "x": 1,
                            "y": 1,
                            "z": 1,
                            "bindings": [
                                {"binding": 0, "resource_handle": 1, "buffer_size": 16, "buffer_type": "uniform"},
                                {"binding": 1, "resource_handle": 2, "buffer_size": 4096, "buffer_type": "readonly"},
                                {"binding": 2, "resource_handle": 3, "buffer_size": 64, "buffer_type": "readonly"},
                                {"binding": 3, "resource_handle": 4, "buffer_size": 256, "buffer_type": "storage"},
                            ],
                        },
                    ],
                }
            ],
        }
        with tempfile.TemporaryDirectory(prefix="doe-benchmark-ir-") as tmpdir:
            ir_path = Path(tmpdir) / "test_ir.json"
            ir_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, r"dispatch must be \[rows,1,1\]"):
                benchmark_ir.materialize_plan(ir_path, "alpha")

    def test_materialize_plan_applies_row2_helper_exact_gemv_variant(self) -> None:
        payload = {
            "schemaVersion": 1,
            "kind": "benchmark_ir",
            "description": "test ir",
            "scenarios": [
                {
                    "id": "alpha",
                    "description": "alpha scenario",
                    "irPath": "bench/ir/test.json",
                    "planPath": "bench/plans/generated/alpha.plan.json",
                    "commandsPath": "bench/plans/generated/compat/alpha_commands.json",
                    "matmulGemvVariant": "row2_helper_exact",
                    "commands": [
                        {"kind": "buffer_write", "handle": 1, "bufferSize": 16, "data": [64, 16, 0, 0]},
                        {
                            "kind": "kernel_dispatch",
                            "kernel": "matmul-gemv.wgsl",
                            "x": 64,
                            "y": 1,
                            "z": 1,
                            "bindings": [
                                {"binding": 0, "resource_handle": 1, "buffer_size": 16, "buffer_type": "uniform"},
                                {"binding": 1, "resource_handle": 2, "buffer_size": 4096, "buffer_type": "readonly"},
                                {"binding": 2, "resource_handle": 3, "buffer_size": 64, "buffer_type": "readonly"},
                                {"binding": 3, "resource_handle": 4, "buffer_size": 256, "buffer_type": "storage"},
                            ],
                        },
                    ],
                }
            ],
        }
        with tempfile.TemporaryDirectory(prefix="doe-benchmark-ir-") as tmpdir:
            ir_path = Path(tmpdir) / "test_ir.json"
            ir_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
            plan = benchmark_ir.materialize_plan(ir_path, "alpha")

        dispatch = plan["commands"][1]
        self.assertEqual(plan["matmulGemvVariant"], "row2_helper_exact")
        self.assertEqual(dispatch["kernel"], "matmul_gemv_row2_helper_exact.wgsl")
        self.assertEqual(dispatch["x"], 32)
        self.assertEqual(dispatch["y"], 1)
        self.assertEqual(dispatch["z"], 1)

    def test_materialize_plan_rejects_row2_helper_exact_odd_rows(self) -> None:
        payload = {
            "schemaVersion": 1,
            "kind": "benchmark_ir",
            "description": "test ir",
            "scenarios": [
                {
                    "id": "alpha",
                    "description": "alpha scenario",
                    "irPath": "bench/ir/test.json",
                    "planPath": "bench/plans/generated/alpha.plan.json",
                    "commandsPath": "bench/plans/generated/compat/alpha_commands.json",
                    "matmulGemvVariant": "row2_helper_exact",
                    "commands": [
                        {"kind": "buffer_write", "handle": 1, "bufferSize": 16, "data": [63, 16, 0, 0]},
                        {
                            "kind": "kernel_dispatch",
                            "kernel": "matmul-gemv.wgsl",
                            "x": 63,
                            "y": 1,
                            "z": 1,
                            "bindings": [
                                {"binding": 0, "resource_handle": 1, "buffer_size": 16, "buffer_type": "uniform"},
                                {"binding": 1, "resource_handle": 2, "buffer_size": 4032, "buffer_type": "readonly"},
                                {"binding": 2, "resource_handle": 3, "buffer_size": 64, "buffer_type": "readonly"},
                                {"binding": 3, "resource_handle": 4, "buffer_size": 252, "buffer_type": "storage"},
                            ],
                        },
                    ],
                }
            ],
        }
        with tempfile.TemporaryDirectory(prefix="doe-benchmark-ir-") as tmpdir:
            ir_path = Path(tmpdir) / "test_ir.json"
            ir_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, r"requires even rows"):
                benchmark_ir.materialize_plan(ir_path, "alpha")

    def test_materialize_plan_rejects_row2_helper_exact_non_vec4_cols(self) -> None:
        payload = {
            "schemaVersion": 1,
            "kind": "benchmark_ir",
            "description": "test ir",
            "scenarios": [
                {
                    "id": "alpha",
                    "description": "alpha scenario",
                    "irPath": "bench/ir/test.json",
                    "planPath": "bench/plans/generated/alpha.plan.json",
                    "commandsPath": "bench/plans/generated/compat/alpha_commands.json",
                    "matmulGemvVariant": "row2_helper_exact",
                    "commands": [
                        {"kind": "buffer_write", "handle": 1, "bufferSize": 16, "data": [64, 18, 0, 0]},
                        {
                            "kind": "kernel_dispatch",
                            "kernel": "matmul-gemv.wgsl",
                            "x": 64,
                            "y": 1,
                            "z": 1,
                            "bindings": [
                                {"binding": 0, "resource_handle": 1, "buffer_size": 16, "buffer_type": "uniform"},
                                {"binding": 1, "resource_handle": 2, "buffer_size": 4608, "buffer_type": "readonly"},
                                {"binding": 2, "resource_handle": 3, "buffer_size": 72, "buffer_type": "readonly"},
                                {"binding": 3, "resource_handle": 4, "buffer_size": 256, "buffer_type": "storage"},
                            ],
                        },
                    ],
                }
            ],
        }
        with tempfile.TemporaryDirectory(prefix="doe-benchmark-ir-") as tmpdir:
            ir_path = Path(tmpdir) / "test_ir.json"
            ir_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, r"requires cols divisible by 4"):
                benchmark_ir.materialize_plan(ir_path, "alpha")


if __name__ == "__main__":
    unittest.main()
