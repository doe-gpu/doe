#!/usr/bin/env python3
"""Regression tests for the canonical backend workload catalog."""

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
GENERATOR_PATH = REPO_ROOT / "bench" / "tools" / "generate_backend_workloads.py"


def load_generator_module():
    spec = importlib.util.spec_from_file_location("generate_backend_workloads", GENERATOR_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load generator module from {GENERATOR_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_json(path: Path) -> dict:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"invalid JSON object: {path}")
    return payload


class BackendWorkloadCatalogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.generator = load_generator_module()
        cls.catalog = load_json(REPO_ROOT / "bench" / "workloads" / "metadata" / "backend-workload-catalog.json")

    def test_write_json_skips_unchanged_content(self) -> None:
        payload = {"schemaVersion": 1, "workloads": [{"id": "alpha"}]}
        with tempfile.TemporaryDirectory(prefix="fawn-backend-workload-catalog-") as tmpdir:
            path = Path(tmpdir) / "out.json"
            first = self.generator.write_json(path, payload)
            second = self.generator.write_json(path, payload)
            self.assertTrue(first)
            self.assertFalse(second)
            self.assertEqual(path.read_text(encoding="utf-8"), self.generator.json_text(payload))

    def test_d3d12_generated_views_match_catalog(self) -> None:
        smoke = self.generator.materialize_lane(self.catalog, "local_d3d12_smoke")
        full = self.generator.materialize_lane(self.catalog, "local_d3d12")
        self.assertEqual(
            smoke,
            load_json(REPO_ROOT / "bench" / "workloads" / "workloads.local.d3d12.smoke.json"),
        )
        self.assertEqual(
            full,
            load_json(REPO_ROOT / "bench" / "workloads" / "workloads.local.d3d12.json"),
        )

    def test_expected_d3d12_workload_id_sets(self) -> None:
        smoke = self.generator.materialize_lane(self.catalog, "local_d3d12_smoke")
        full = self.generator.materialize_lane(self.catalog, "local_d3d12")
        metal_full = self.generator.materialize_lane(self.catalog, "apple_metal")
        vulkan_full = self.generator.materialize_lane(self.catalog, "amd_vulkan")
        self.assertEqual(
            [row["id"] for row in smoke["workloads"]],
            [
                "compute_workgroup_atomic_1024",
                "pipeline_compile_stress",
                "upload_write_buffer_64kb",
            ],
        )
        metal_ids = {row["id"] for row in metal_full["workloads"]}
        vulkan_ids = {row["id"] for row in vulkan_full["workloads"]}
        extended_ids = [row["id"] for row in full["workloads"]]
        self.assertEqual(
            set(extended_ids),
            metal_ids & vulkan_ids,
        )
        self.assertEqual(len(extended_ids), len(metal_ids & vulkan_ids))

    def test_expected_d3d12_governed_workload_id_set(self) -> None:
        comparable = self.generator.materialize_lane(self.catalog, "local_d3d12")
        governed_ids = [
            row["id"]
            for row in comparable["workloads"]
            if row.get("comparable") and "governed" in row.get("cohorts", [])
        ]
        self.assertEqual(
            sorted(governed_ids),
            sorted(
                [
                "compute_concurrent_execution_single",
                "compute_workgroup_atomic_1024",
                "compute_workgroup_non_atomic_1024",
                "compute_zero_initialize_workgroup_memory_256",
                "pipeline_compile_stress",
                "upload_write_buffer_16mb",
                "upload_write_buffer_1kb",
                "upload_write_buffer_1mb",
                "upload_write_buffer_4mb",
                "upload_write_buffer_64kb",
                "resource_lifecycle",
                ]
            ),
        )

    def test_governed_rows_are_comparable_for_all_profiles(self) -> None:
        for lane_id in ("amd_vulkan", "apple_metal", "local_d3d12"):
            materialized = self.generator.materialize_lane(self.catalog, lane_id)
            for row in materialized["workloads"]:
                if "governed" not in row.get("cohorts", []):
                    continue
                self.assertTrue(
                    row.get("comparable"),
                    msg=f"{row['id']} must be comparable in the governed cohort for {lane_id}",
                )
                self.assertEqual(
                    row.get("benchmarkClass"),
                    "comparable",
                    msg=f"{row['id']} must have benchmarkClass=comparable in the governed cohort for {lane_id}",
                )

    def test_amd_vulkan_path_asymmetric_upload_rows_are_diagnostic(self) -> None:
        materialized = self.generator.materialize_lane(self.catalog, "amd_vulkan")
        for row in materialized["workloads"]:
            if row.get("domain") != "upload":
                continue
            if not row.get("pathAsymmetry", False):
                continue
            self.assertFalse(
                row.get("comparable"),
                msg=f"{row['id']} cannot be comparable while its upload path is asymmetric",
            )
            self.assertFalse(row.get("claimEligible"))
            self.assertEqual(row.get("benchmarkClass"), "directional")
            self.assertEqual(row.get("directionalReason"), "hardware_path_asymmetry")
            self.assertNotIn("governed", row.get("cohorts", []))

    def test_amd_vulkan_non_vetted_non_app_domains_remain_directional(self) -> None:
        materialized = self.generator.materialize_lane(self.catalog, "amd_vulkan")
        non_apples_domains = {
            "pipeline-async",
            "p1-capability",
            "p1-resource-table",
            "p1-capability-macro",
            "p2-lifecycle",
            "p2-lifecycle-macro",
            "p0-resource",
            "p0-compute",
            "p0-render",
            "surface",
        }
        for row in materialized["workloads"]:
            if row.get("domain") not in non_apples_domains:
                continue
            if row.get("applesToApplesVetted", False):
                continue
            self.assertFalse(
                row.get("comparable", False),
                msg=f"{row['id']} must stay directional in amd_vulkan until applesToApplesVetted=true",
            )

    def test_d3d12_governed_rows_are_comparable(self) -> None:
        comparable = self.generator.materialize_lane(self.catalog, "local_d3d12")
        for row in comparable["workloads"]:
            if "governed" not in row.get("cohorts", []):
                continue
            self.assertTrue(
                row.get("comparable"),
                msg=f"{row['id']} must be comparable in the governed D3D12 cohort",
            )
            self.assertEqual(
                row.get("benchmarkClass"),
                "comparable",
                msg=f"{row['id']} must have benchmarkClass=comparable in the governed D3D12 cohort",
            )

    def test_d3d12_compare_config_invariants(self) -> None:
        config_path = (
            REPO_ROOT
            / "bench"
            / "native-compare"
            / "compare.config.local.d3d12.compare.json"
        )
        if not config_path.exists():
            self.skipTest("governed D3D12 compare config is not present")
        config = load_json(config_path)
        self.assertEqual(config["workloads"], "bench/workloads/workloads.local.d3d12.json")
        self.assertEqual(config["comparability"]["mode"], "strict")
        self.assertEqual(config["comparability"]["requireTimingClass"], "operation")
        self.assertFalse(config["comparability"]["allowBaselineNoExecution"])
        self.assertIn("--backend-lane d3d12_doe_comparable", config["baseline"]["commandTemplate"])
        self.assertIn("--backend-lane d3d12_dawn_release", config["comparison"]["commandTemplate"])
        self.assertEqual(config["claimability"]["mode"], "local")
        self.assertGreaterEqual(config["claimability"]["minTimedSamples"], 7)
        self.assertEqual(config["selector"]["cohorts"], ["governed"])
        self.assertEqual(config["selector"]["benchmarkClass"], ["comparable"])

    def test_expected_apple_metal_additional_directional_ids(self) -> None:
        metal = self.generator.materialize_lane(self.catalog, "apple_metal")
        workload_ids = [row["id"] for row in metal["workloads"]]
        self.assertIn("compute_dispatch_fallback", workload_ids)
        self.assertIn("compute_dispatch_grid", workload_ids)
        self.assertIn("copy_buffer_to_texture", workload_ids)
        self.assertIn("copy_protocol", workload_ids)
        self.assertIn("copy_texture_to_buffer", workload_ids)
        self.assertIn("copy_texture_to_texture", workload_ids)
        self.assertIn("surface_full_presentation", workload_ids)
        self.assertIn("upload_write_buffer_64kb", workload_ids)
        self.assertIn("upload_write_buffer_64kb_staged", workload_ids)
        self.assertIn("upload_write_buffer_1gb", workload_ids)
        self.assertIn("upload_write_buffer_1gb_staged", workload_ids)

    def test_apple_metal_compilation_rows_include_real_inference_kernels(self) -> None:
        metal = self.generator.materialize_lane(self.catalog, "apple_metal")
        rows = {row["id"]: row for row in metal["workloads"]}
        expected = {
            "compilation_inference_attention_decode_msl": "bench/inference-pipeline/kernels/attention-decode.wgsl",
            "compilation_inference_attention_prefill_msl": "bench/inference-pipeline/kernels/attention-prefill.wgsl",
            "compilation_inference_matmul_gemv_msl": "bench/inference-pipeline/kernels/matmul-gemv.wgsl",
            "compilation_inference_matmul_tiled_msl": "bench/inference-pipeline/kernels/matmul-tiled.wgsl",
            "compilation_inference_rmsnorm_msl": "bench/inference-pipeline/kernels/rmsnorm.wgsl",
            "compilation_inference_rope_msl": "bench/inference-pipeline/kernels/rope.wgsl",
        }
        for workload_id, shader_path in expected.items():
            self.assertIn(workload_id, rows)
            self.assertEqual(rows[workload_id]["runnerType"], "compilation")
            self.assertEqual(rows[workload_id]["shaderPath"], shader_path)
            self.assertEqual(rows[workload_id]["compilationTarget"], "msl")

    def test_apple_metal_runtime_rows_include_gemma_shaped_inference_sequences(self) -> None:
        metal = self.generator.materialize_lane(self.catalog, "apple_metal")
        rows = {row["id"]: row for row in metal["workloads"]}
        expected = {
            "inference_gemma3_270m_prefill_32tok": (
                "bench/ir/gemma3_270m.json",
                "bench/plans/generated/inference_gemma3_270m_prefill_32tok.plan.json",
                "bench/plans/generated/compat/inference_gemma3_270m_prefill_32tok_commands.json",
                35,
                7,
                10,
                18,
                {"regression"},
            ),
            "inference_gemma3_270m_decode_1tok": (
                "bench/ir/gemma3_270m.json",
                "bench/plans/generated/inference_gemma3_270m_decode_1tok.plan.json",
                "bench/plans/generated/compat/inference_gemma3_270m_decode_1tok_commands.json",
                37,
                6,
                13,
                18,
                {"regression"},
            ),
            "inference_gemma3_270m_prefill_64tok_decode_64tok": (
                "bench/ir/gemma3_270m.json",
                "bench/plans/generated/inference_gemma3_270m_prefill_64tok_decode_64tok.plan.json",
                "bench/plans/generated/compat/inference_gemma3_270m_prefill_64tok_decode_64tok_commands.json",
                1583,
                391,
                22,
                1170,
                {"regression"},
            ),
            "inference_gemma3_270m_literal_prefill_32tok_decode_1tok": (
                "bench/ir/gemma3_270m_literal.json",
                "bench/plans/generated/inference_gemma3_270m_literal_prefill_32tok_decode_1tok.plan.json",
                "bench/plans/generated/compat/inference_gemma3_270m_literal_prefill_32tok_decode_1tok_commands.json",
                69,
                13,
                20,
                36,
                {"exploration"},
            ),
            "inference_gemma3_1b_prefill_32tok": (
                "bench/ir/gemma3_1b.json",
                "bench/plans/generated/inference_gemma3_1b_prefill_32tok.plan.json",
                "bench/plans/generated/compat/inference_gemma3_1b_prefill_32tok_commands.json",
                35,
                7,
                10,
                18,
                {"exploration"},
            ),
            "inference_gemma3_1b_decode_1tok": (
                "bench/ir/gemma3_1b.json",
                "bench/plans/generated/inference_gemma3_1b_decode_1tok.plan.json",
                "bench/plans/generated/compat/inference_gemma3_1b_decode_1tok_commands.json",
                37,
                6,
                13,
                18,
                {"exploration"},
            ),
            "inference_gemma3_1b_prefill_64tok_decode_64tok": (
                "bench/ir/gemma3_1b.json",
                "bench/plans/generated/inference_gemma3_1b_prefill_64tok_decode_64tok.plan.json",
                "bench/plans/generated/compat/inference_gemma3_1b_prefill_64tok_decode_64tok_commands.json",
                1583,
                391,
                22,
                1170,
                {"exploration"},
            ),
        }
        for workload_id, (
            ir_path,
            plan_path,
            commands_path,
            command_count,
            buffer_write_count,
            buffer_load_count,
            dispatch_count,
            required_cohorts,
        ) in expected.items():
            self.assertIn(workload_id, rows)
            self.assertEqual(rows[workload_id]["irPath"], ir_path)
            self.assertEqual(rows[workload_id]["irScenario"], workload_id)
            self.assertEqual(rows[workload_id]["planPath"], plan_path)
            self.assertEqual(rows[workload_id]["commandsPath"], commands_path)
            self.assertEqual(rows[workload_id]["planSchemaVersion"], 1)
            self.assertEqual(rows[workload_id]["planCommandCount"], command_count)
            self.assertEqual(rows[workload_id]["planBufferWriteCount"], buffer_write_count)
            self.assertEqual(rows[workload_id]["planBufferLoadCount"], buffer_load_count)
            self.assertEqual(rows[workload_id]["planDispatchCount"], dispatch_count)
            self.assertRegex(rows[workload_id]["planHash"], r"^[0-9a-f]{64}$")
            self.assertRegex(rows[workload_id]["sourceIrSha256"], r"^[0-9a-f]{64}$")
            self.assertRegex(rows[workload_id]["compatibilityCommandHash"], r"^[0-9a-f]{64}$")
            self.assertEqual(rows[workload_id]["extraArgs"], ["--kernel-root", "bench/inference-pipeline/kernels"])
            self.assertEqual(rows[workload_id]["benchmarkClass"], "comparable")
            self.assertTrue(rows[workload_id]["comparable"])
            self.assertTrue(rows[workload_id]["claimEligible"])
            for cohort in required_cohorts:
                self.assertIn(cohort, rows[workload_id]["cohorts"])
            self.assertEqual(rows[workload_id]["runnerType"], "zig-runtime")

            generated_plan = load_json(REPO_ROOT / plan_path)
            generated_commands = json.loads((REPO_ROOT / commands_path).read_text(encoding="utf-8"))
            legacy_commands = json.loads(
                (REPO_ROOT / "examples" / f"{workload_id}_commands.json").read_text(encoding="utf-8")
            )
            self.assertEqual(generated_commands, legacy_commands)
            self.assertEqual(generated_plan["commands"], generated_commands)
            self.assertEqual(generated_plan["workloadId"], workload_id)
            self.assertEqual(generated_plan["commandCount"], command_count)
            self.assertEqual(generated_plan["bufferWriteCount"], buffer_write_count)
            self.assertEqual(generated_plan["dispatchCount"], dispatch_count)

    def test_gemma_runtime_rows_are_ir_backed_in_the_catalog(self) -> None:
        gemma_ids = {
            "inference_gemma3_270m_prefill_32tok",
            "inference_gemma3_270m_decode_1tok",
            "inference_gemma3_270m_prefill_64tok_decode_64tok",
            "inference_gemma3_270m_literal_prefill_32tok_decode_1tok",
            "inference_gemma3_1b_prefill_32tok",
            "inference_gemma3_1b_decode_1tok",
            "inference_gemma3_1b_prefill_64tok_decode_64tok",
        }
        rows = {item["id"]: item for item in self.catalog["workloads"] if item["id"] in gemma_ids}
        self.assertEqual(set(rows), gemma_ids)
        for workload_id, item in rows.items():
            shared = item["shared"]
            lane = item["lanes"]["apple_metal_extended"]
            if "_1b_" in workload_id:
                expected_ir_path = "bench/ir/gemma3_1b.json"
            elif "_literal_" in workload_id:
                expected_ir_path = "bench/ir/gemma3_270m_literal.json"
            else:
                expected_ir_path = "bench/ir/gemma3_270m.json"
            self.assertEqual(shared["irPath"], expected_ir_path)
            self.assertEqual(shared["irScenario"], workload_id)
            self.assertNotIn("commandsPath", lane)
            self.assertNotIn("commandsPath", shared)

    def test_package_inference_manifest_matches_ir_materialized_plans(self) -> None:
        manifests = [
            REPO_ROOT / "bench" / "workloads" / "workloads.package.inference.json",
            REPO_ROOT / "bench" / "workloads" / "workloads.package.inference.prepared.json",
        ]
        for manifest_path in manifests:
            package_manifest = load_json(manifest_path)
            for row in package_manifest["workloads"]:
                ir_path = row.get("irPath")
                ir_scenario = row.get("irScenario")
                if not ir_path:
                    continue
                artifacts = self.generator.benchmark_ir_mod.materialize_plan_artifacts(
                    REPO_ROOT / ir_path,
                    ir_scenario,
                )
                self.assertEqual(row["planPath"], artifacts["planPath"])
                self.assertEqual(row["commandsPath"], artifacts["commandsPath"])
                self.assertEqual(row["planHash"], artifacts["planSha256"])
                self.assertEqual(row["sourceIrSha256"], artifacts["sourceIrSha256"])
                self.assertEqual(
                    row["compatibilityCommandHash"],
                    artifacts["compatibilityCommandsSha256"],
                )
                self.assertEqual(row["planCommandCount"], artifacts["commandCount"])
                self.assertEqual(row["planDispatchCount"], artifacts["dispatchCount"])
                self.assertEqual(row["planBufferWriteCount"], artifacts["bufferWriteCount"])
                self.assertEqual(row["planBufferLoadCount"], artifacts["bufferLoadCount"])

    def test_no_js_pipeline_workloads_remain(self) -> None:
        for lane_id in self.catalog["laneOutputs"]:
            materialized = self.generator.materialize_lane(self.catalog, lane_id)
            for row in materialized["workloads"]:
                self.assertNotEqual(
                    row.get("runnerType"),
                    "js-pipeline",
                    msg=f"{row['id']} lane={lane_id} should not materialize a synthetic js-pipeline workload",
                )

    def test_comparable_rows_are_symmetric(self) -> None:
        defaults = {
            "baselineCommandRepeat": 1,
            "comparisonCommandRepeat": 1,
            "baselineIgnoreFirstOps": 0,
            "comparisonIgnoreFirstOps": 0,
            "baselineUploadSubmitEvery": 1,
            "comparisonUploadSubmitEvery": 1,
            "baselineTimingDivisor": 1.0,
            "comparisonTimingDivisor": 1.0,
            "baselineUploadBufferUsage": None,
            "comparisonUploadBufferUsage": None,
        }
        pairs = (
            ("baselineCommandRepeat", "comparisonCommandRepeat"),
            ("baselineIgnoreFirstOps", "comparisonIgnoreFirstOps"),
            ("baselineUploadSubmitEvery", "comparisonUploadSubmitEvery"),
            ("baselineTimingDivisor", "comparisonTimingDivisor"),
            ("baselineUploadBufferUsage", "comparisonUploadBufferUsage"),
        )
        for lane_id in self.catalog["laneOutputs"]:
            materialized = self.generator.materialize_lane(self.catalog, lane_id)
            for row in materialized["workloads"]:
                if not row.get("comparable"):
                    continue
                for left_key, right_key in pairs:
                    self.assertEqual(
                        row.get(left_key, defaults[left_key]),
                        row.get(right_key, defaults[right_key]),
                        msg=f"{row['id']} lane={lane_id} should keep comparable symmetry for {left_key}/{right_key}",
                    )

    def test_catalog_validation_rejects_asymmetric_comparable_workload(self) -> None:
        mutated = json.loads(json.dumps(self.catalog))
        target = next(
            item
            for item in mutated["workloads"]
            if item["id"] == "render_uniform_buffer_update_writebuffer_partial_single"
        )
        target["lanes"]["apple_metal_extended"]["comparisonCommandRepeat"] = 777
        with self.assertRaisesRegex(ValueError, "comparable workload contract asymmetry detected"):
            self.generator.validate_catalog(mutated)

    def test_d3d12_config_and_policy_invariants(self) -> None:
        smoke_path = REPO_ROOT / "bench" / "native-compare" / "compare.config.local.d3d12.smoke.json"
        comparable_path = REPO_ROOT / "bench" / "native-compare" / "compare.config.local.d3d12.compare.json"
        release_path = REPO_ROOT / "bench" / "native-compare" / "compare.config.local.d3d12.release.json"
        if not smoke_path.exists() or not comparable_path.exists() or not release_path.exists():
            self.skipTest("local D3D12 compare configs are not present in this checkout")
        smoke_config = load_json(smoke_path)
        comparable_config = load_json(comparable_path)
        release_config = load_json(release_path)
        runtime_policy = load_json(REPO_ROOT / "config" / "backend-runtime-policy.json")
        governed_lanes = load_json(REPO_ROOT / "config" / "governed-lanes.json")
        cube_policy = load_json(REPO_ROOT / "config" / "benchmark-cube-policy.json")

        self.assertEqual(smoke_config["workloads"], "bench/workloads/workloads.local.d3d12.smoke.json")
        self.assertEqual(comparable_config["workloads"], "bench/workloads/workloads.local.d3d12.json")
        self.assertEqual(release_config["workloads"], "bench/workloads/workloads.local.d3d12.json")

        self.assertEqual(smoke_config["baseline"]["name"], "doe")
        self.assertIn("--backend-lane d3d12_doe_comparable", smoke_config["baseline"]["commandTemplate"])
        self.assertIn("--backend-lane d3d12_dawn_release", smoke_config["comparison"]["commandTemplate"])
        self.assertIn("--backend-lane d3d12_doe_comparable", comparable_config["baseline"]["commandTemplate"])
        self.assertIn("--backend-lane d3d12_dawn_release", comparable_config["comparison"]["commandTemplate"])
        self.assertIn("--backend-lane d3d12_doe_release", release_config["baseline"]["commandTemplate"])
        self.assertIn("--backend-lane d3d12_dawn_release", release_config["comparison"]["commandTemplate"])
        self.assertEqual(release_config["claimability"]["mode"], "release")
        self.assertEqual(release_config["claimability"]["minTimedSamples"], 15)

        for lane_id in ("d3d12_doe_comparable", "d3d12_doe_release"):
            lane = runtime_policy["lanes"][lane_id]
            self.assertEqual(lane["defaultBackend"], "doe_d3d12")
            self.assertEqual(lane["uploadPathPolicy"], "staged_copy_only")
            self.assertTrue(lane["strictNoFallback"])

        lane_map = {lane["id"]: lane for lane in governed_lanes["lanes"]}
        for lane_id in ("d3d12_doe_comparable", "d3d12_doe_release", "d3d12_dawn_release"):
            lane = lane_map[lane_id]
            self.assertIn("windows_d3d12", lane["hostProfiles"])
            self.assertTrue(lane["cubeEligible"])
            self.assertEqual(lane["surface"], "backend_native")

        backend_surface = next(
            item for item in cube_policy["surfaces"] if item["id"] == "backend_native"
        )
        self.assertIn("windows_d3d12", backend_surface["expectedHostProfiles"])

    def test_apple_metal_config_and_policy_invariants(self) -> None:
        smoke_path = REPO_ROOT / "bench" / "native-compare" / "compare.config.apple.metal.smoke.json"
        compare_path = REPO_ROOT / "bench" / "native-compare" / "compare.config.apple.metal.compare.json"
        release_path = REPO_ROOT / "bench" / "native-compare" / "compare.config.apple.metal.release.json"
        explore_path = REPO_ROOT / "bench" / "native-compare" / "compare.config.apple.metal.explore.json"
        breadth_path = REPO_ROOT / "bench" / "native-compare" / "compare.config.apple.metal.breadth.json"
        smoke_config = load_json(smoke_path)
        compare_config = load_json(compare_path)
        release_config = load_json(release_path)
        explore_config = load_json(explore_path)
        breadth_config = load_json(breadth_path)
        runtime_policy = load_json(REPO_ROOT / "config" / "backend-runtime-policy.json")

        self.assertEqual(smoke_config["workloads"], "bench/workloads/workloads.apple.metal.smoke.json")
        self.assertEqual(compare_config["workloads"], "bench/workloads/workloads.apple.metal.json")
        self.assertEqual(release_config["workloads"], "bench/workloads/workloads.apple.metal.json")
        self.assertIn("--backend-lane metal_doe_comparable", smoke_config["baseline"]["commandTemplate"])
        self.assertIn("--backend-lane metal_doe_directional", explore_config["baseline"]["commandTemplate"])
        self.assertIn("--backend-lane metal_doe_directional", breadth_config["baseline"]["commandTemplate"])
        self.assertIn("--backend-lane metal_doe_comparable", compare_config["baseline"]["commandTemplate"])
        self.assertIn("--backend-lane metal_doe_release", release_config["baseline"]["commandTemplate"])

        for lane_id in ("metal_doe_comparable", "metal_doe_release"):
            lane = runtime_policy["lanes"][lane_id]
            self.assertEqual(lane["defaultBackend"], "doe_metal")
            self.assertEqual(lane["uploadPathPolicy"], "staged_copy_only")
            self.assertTrue(lane["strictNoFallback"])

        directional_lane = runtime_policy["lanes"]["metal_doe_directional"]
        self.assertEqual(directional_lane["uploadPathPolicy"], "allow_mapped_shortcuts")

    def test_workload_origin_report_is_complete_and_consistent(self) -> None:
        report = self.generator.build_workload_origin_report(self.catalog)
        self.assertEqual(report["schemaVersion"], 1)
        self.assertEqual(report["source"], "bench/workloads/metadata/backend-workload-catalog.json")
        self.assertEqual(len(report["workloads"]), len(self.catalog["workloads"]))
        rows_by_id = {row["id"]: row for row in report["workloads"]}
        for item in self.catalog["workloads"]:
            report_row = rows_by_id[item["id"]]
            self.assertEqual(
                report_row["laneOrigins"],
                self.generator.build_workload_origin_matrix(item),
            )
            self.assertEqual(
                report_row["effectiveOrigin"],
                self.generator.workload_effective_origin(item),
            )
        workload_count = len(self.catalog["workloads"])
        self.assertEqual(
            sum(report["counts"].values()),
            workload_count,
        )
        for key in (
            "dawn_benchmark",
            "dawn_autodiscovered",
            "doe_contract_with_dawn_mapping",
            "doe_specific",
            "hybrid",
        ):
            self.assertIn(key, report["counts"])

    def test_comparable_workloads_are_not_pure_doe_specific(self) -> None:
        for item in self.catalog["workloads"]:
            for lane_id in item["lanes"]:
                comparable = self.generator.effective_field(
                    item,
                    lane_id,
                    "comparable",
                    False,
                )
                origin = self.generator.resolve_workload_origin(item, lane_id)
                if comparable:
                    self.assertNotEqual(
                        origin,
                        "doe_specific",
                        msg=f"{item['id']} lane={lane_id} has comparable=true but provenance='doe_specific'",
                    )

    def test_origin_taxonomy_covers_autodiscovered_contract_and_benchmark_cases(self) -> None:
        rows = {item["id"]: item for item in self.catalog["workloads"]}
        self.assertEqual(
            self.generator.resolve_workload_origin(rows["compute_workgroup_atomic_1024"], "apple_metal_extended"),
            "dawn_autodiscovered",
        )
        self.assertEqual(
            self.generator.resolve_workload_origin(rows["compute_workgroup_atomic_1024"], "generic"),
            "dawn_benchmark",
        )
        self.assertEqual(
            self.generator.resolve_workload_origin(rows["copy_buffer_to_texture"], "apple_metal_extended"),
            "doe_contract_with_dawn_mapping",
        )
        self.assertEqual(
            self.generator.resolve_workload_origin(rows["compute_dispatch_fallback"], "apple_metal_extended"),
            "doe_contract_with_dawn_mapping",
        )
        self.assertEqual(
            self.generator.workload_effective_origin(rows["render_draw_throughput_baseline"]),
            "hybrid",
        )

    def test_catalog_validation_rejects_explicit_doe_specific_comparable(self) -> None:
        mutated = json.loads(json.dumps(self.catalog))
        target = next(
            item
            for item in mutated["workloads"]
            if item["id"] == "compute_matvec_32768x2048_f32"
        )
        target["lanes"]["amd_vulkan_extended"]["workloadOrigin"] = "doe_specific"
        with self.assertRaisesRegex(
            ValueError,
            r"comparable lanes must not be provenance='doe_specific'",
        ):
            self.generator.validate_catalog(mutated)


if __name__ == "__main__":
    unittest.main(verbosity=2)
