#!/usr/bin/env python3
"""Tests for explicit compare executor ids."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in sys.path:
        sys.path.insert(0, _path_entry)

from bench.native_compare_modules.executor_registry import (
    resolve_executor_boundary,
    resolve_executor_command_template,
)


class ExecutorRegistryTests(unittest.TestCase):
    def test_resolves_doe_direct_executor(self) -> None:
        template = resolve_executor_command_template("doe_direct_metal")
        self.assertIn("doe-zig-runtime", template)
        self.assertIn("--backend-lane metal_doe_comparable", template)
        self.assertIn("--no-pipeline-cache", template)
        self.assertEqual(resolve_executor_boundary("doe_direct_metal"), "commands")

    def test_resolves_cache_opt_in_metal_executors(self) -> None:
        doe_template = resolve_executor_command_template("doe_direct_metal_cache")
        dawn_template = resolve_executor_command_template("dawn_delegate_metal_cache")
        self.assertIn("--backend-lane metal_doe_comparable", doe_template)
        self.assertIn("--backend-lane metal_dawn_release", dawn_template)
        self.assertNotIn("--no-pipeline-cache", doe_template)
        self.assertNotIn("--no-pipeline-cache", dawn_template)
        self.assertEqual(resolve_executor_boundary("doe_direct_metal_cache"), "commands")
        self.assertEqual(resolve_executor_boundary("dawn_delegate_metal_cache"), "commands")

    def test_resolves_doe_direct_plan_executor(self) -> None:
        template = resolve_executor_command_template("doe_direct_plan_metal")
        self.assertIn("doe-plan-executor", template)
        self.assertIn("--plan {plan}", template)
        self.assertIn("--backend-lane metal_doe_comparable", template)
        self.assertEqual(resolve_executor_boundary("doe_direct_plan_metal"), "plan")

    def test_resolves_doe_direct_plan_vulkan_executor(self) -> None:
        template = resolve_executor_command_template("doe_direct_plan_vulkan")
        self.assertIn("doe-plan-executor", template)
        self.assertIn("--plan {plan}", template)
        self.assertIn("--backend-lane vulkan_doe_comparable", template)
        self.assertEqual(resolve_executor_boundary("doe_direct_plan_vulkan"), "plan")

    def test_resolves_node_webgpu_executor(self) -> None:
        template = resolve_executor_command_template("node_webgpu_package")
        self.assertIn("run-node-webgpu-plan.js", template)
        self.assertIn("--plan {plan}", template)
        self.assertIn("--provider node-webgpu", template)
        self.assertNotIn("DOE_WEBGPU_SUBMIT_BREAKDOWN=1", template)
        self.assertEqual(resolve_executor_boundary("node_webgpu_package"), "plan")

    def test_resolves_doe_node_webgpu_executor(self) -> None:
        template = resolve_executor_command_template("doe_node_webgpu")
        self.assertIn("run-node-webgpu-plan.js", template)
        self.assertIn("--plan {plan}", template)
        self.assertIn("--provider doe", template)
        self.assertNotIn("DOE_WEBGPU_SUBMIT_BREAKDOWN=1", template)
        self.assertEqual(resolve_executor_boundary("doe_node_webgpu"), "plan")

    def test_resolves_prepared_node_webgpu_executors(self) -> None:
        dawn_template = resolve_executor_command_template("node_webgpu_package_prepared")
        doe_template = resolve_executor_command_template("doe_node_webgpu_prepared")
        self.assertIn("--provider node-webgpu", dawn_template)
        self.assertIn("--provider doe", doe_template)
        self.assertIn("--prepared-session", dawn_template)
        self.assertIn("--prepared-session", doe_template)
        self.assertNotIn("DOE_WEBGPU_SUBMIT_BREAKDOWN=1", dawn_template)
        self.assertNotIn("DOE_WEBGPU_SUBMIT_BREAKDOWN=1", doe_template)
        self.assertEqual(resolve_executor_boundary("node_webgpu_package_prepared"), "plan")
        self.assertEqual(resolve_executor_boundary("doe_node_webgpu_prepared"), "plan")

    def test_resolves_doe_prepared_without_dispatch_prewarm(self) -> None:
        template = resolve_executor_command_template(
            "doe_node_webgpu_prepared_no_dispatch_prewarm"
        )
        self.assertIn("--provider doe", template)
        self.assertIn("--prepared-session", template)
        self.assertIn("--skip-dispatch-prewarm", template)
        self.assertEqual(
            resolve_executor_boundary(
                "doe_node_webgpu_prepared_no_dispatch_prewarm"
            ),
            "plan",
        )

    def test_resolves_resident_buffer_load_node_webgpu_executors(self) -> None:
        executor_ids = (
            "node_webgpu_package_prepared_resident_buffer_loads",
            "doe_node_webgpu_prepared_resident_buffer_loads",
            "doe_node_native_direct_prepared_resident_buffer_loads",
        )
        for executor_id in executor_ids:
            with self.subTest(executor_id=executor_id):
                template = resolve_executor_command_template(executor_id)
                self.assertIn("run-node-webgpu-plan.js", template)
                self.assertIn("--prepared-session", template)
                self.assertIn("--resident-buffer-loads", template)
                self.assertIn("--command-repeat {command_repeat}", template)
                self.assertEqual(resolve_executor_boundary(executor_id), "plan")

    def test_resolves_bun_webgpu_executors(self) -> None:
        bun_template = resolve_executor_command_template("bun_webgpu_package")
        doe_template = resolve_executor_command_template("doe_bun_package")
        doe_ffi_template = resolve_executor_command_template("doe_bun_package_ffi")
        self.assertIn("run-bun-webgpu-plan.js", bun_template)
        self.assertIn("run-bun-webgpu-plan.js", doe_template)
        self.assertIn("run-bun-webgpu-plan.js", doe_ffi_template)
        self.assertIn("--provider bun-webgpu", bun_template)
        self.assertIn("--provider doe", doe_template)
        self.assertIn("--provider doe-ffi", doe_ffi_template)
        self.assertNotIn("DOE_WEBGPU_SUBMIT_BREAKDOWN=1", bun_template)
        self.assertNotIn("DOE_WEBGPU_SUBMIT_BREAKDOWN=1", doe_template)
        self.assertNotIn("DOE_WEBGPU_SUBMIT_BREAKDOWN=1", doe_ffi_template)
        self.assertEqual(resolve_executor_boundary("bun_webgpu_package"), "plan")
        self.assertEqual(resolve_executor_boundary("doe_bun_package"), "plan")
        self.assertEqual(resolve_executor_boundary("doe_bun_package_ffi"), "plan")

    def test_resolves_prepared_bun_webgpu_executors(self) -> None:
        bun_template = resolve_executor_command_template("bun_webgpu_package_prepared")
        doe_template = resolve_executor_command_template("doe_bun_package_prepared")
        doe_ffi_template = resolve_executor_command_template("doe_bun_package_ffi_prepared")
        self.assertIn("--provider bun-webgpu", bun_template)
        self.assertIn("--provider doe", doe_template)
        self.assertIn("--provider doe-ffi", doe_ffi_template)
        self.assertIn("--prepared-session", bun_template)
        self.assertIn("--prepared-session", doe_template)
        self.assertIn("--prepared-session", doe_ffi_template)
        self.assertNotIn("DOE_WEBGPU_SUBMIT_BREAKDOWN=1", bun_template)
        self.assertNotIn("DOE_WEBGPU_SUBMIT_BREAKDOWN=1", doe_template)
        self.assertNotIn("DOE_WEBGPU_SUBMIT_BREAKDOWN=1", doe_ffi_template)
        self.assertEqual(resolve_executor_boundary("bun_webgpu_package_prepared"), "plan")
        self.assertEqual(resolve_executor_boundary("doe_bun_package_prepared"), "plan")
        self.assertEqual(resolve_executor_boundary("doe_bun_package_ffi_prepared"), "plan")

    def test_resolves_resident_buffer_load_bun_webgpu_executors(self) -> None:
        executor_ids = (
            "bun_webgpu_package_prepared_resident_buffer_loads",
            "doe_bun_package_prepared_resident_buffer_loads",
            "doe_bun_package_ffi_prepared_resident_buffer_loads",
        )
        for executor_id in executor_ids:
            with self.subTest(executor_id=executor_id):
                template = resolve_executor_command_template(executor_id)
                self.assertIn("run-bun-webgpu-plan.js", template)
                self.assertIn("--prepared-session", template)
                self.assertIn("--resident-buffer-loads", template)
                self.assertIn("--command-repeat {command_repeat}", template)
                self.assertEqual(resolve_executor_boundary(executor_id), "plan")
        self.assertIn(
            "--provider doe-ffi",
            resolve_executor_command_template("doe_bun_package_ffi_prepared_resident_buffer_loads"),
        )

    def test_resolves_direct_dawn_executor(self) -> None:
        template = resolve_executor_command_template("dawn_direct_metal")
        self.assertIn("webgpu-plan-executor", template)
        self.assertIn("--plan {plan}", template)
        self.assertIn("--trace-meta {trace_meta}", template)
        self.assertEqual(resolve_executor_boundary("dawn_direct_metal"), "plan")

    def test_resolves_dawn_delegate_plan_vulkan_executor(self) -> None:
        template = resolve_executor_command_template("dawn_delegate_plan_vulkan")
        self.assertIn("doe-plan-executor", template)
        self.assertIn("--plan {plan}", template)
        self.assertIn("--backend-lane vulkan_dawn_release", template)
        self.assertEqual(resolve_executor_boundary("dawn_delegate_plan_vulkan"), "plan")

    def test_resolves_native_ort_doe_ep_executor(self) -> None:
        template = resolve_executor_command_template("ort_native_doe_ep")
        self.assertIn("run-native-ort-ep-bench.py", template)
        self.assertIn("--scenario {commands}", template)
        self.assertEqual(resolve_executor_boundary("ort_native_doe_ep"), "commands")

    def test_resolves_native_ort_webgpu_incumbent_executor(self) -> None:
        template = resolve_executor_command_template("ort_native_webgpu_incumbent")
        self.assertIn("run-native-ort-incumbent-bench.py", template)
        self.assertIn("--scenario {commands}", template)
        self.assertEqual(resolve_executor_boundary("ort_native_webgpu_incumbent"), "commands")

    def test_resolves_tjs_ort_node_doe_executor(self) -> None:
        template = resolve_executor_command_template('tjs_ort_node_doe')
        self.assertIn('run-node-tjs-ort-webgpu.js', template)
        self.assertIn('--provider doe', template)
        self.assertIn('--scenario {commands}', template)
        self.assertEqual(resolve_executor_boundary('tjs_ort_node_doe'), 'commands')

    def test_resolves_tjs_ort_node_webgpu_package_executor(self) -> None:
        template = resolve_executor_command_template('tjs_ort_node_webgpu_package')
        self.assertIn('run-node-tjs-ort-webgpu.js', template)
        self.assertIn('--provider node-webgpu', template)
        self.assertIn('--scenario {commands}', template)
        self.assertEqual(resolve_executor_boundary('tjs_ort_node_webgpu_package'), 'commands')

    def test_resolves_tjs_ort_bun_doe_executor(self) -> None:
        template = resolve_executor_command_template('tjs_ort_bun_doe')
        self.assertIn('run-bun-tjs-ort-webgpu.js', template)
        self.assertIn('--provider doe', template)
        self.assertIn('--scenario {commands}', template)
        self.assertEqual(resolve_executor_boundary('tjs_ort_bun_doe'), 'commands')

    def test_resolves_tjs_ort_bun_webgpu_package_executor(self) -> None:
        template = resolve_executor_command_template('tjs_ort_bun_webgpu_package')
        self.assertIn('run-bun-tjs-ort-webgpu.js', template)
        self.assertIn('--provider bun-webgpu', template)
        self.assertIn('--scenario {commands}', template)
        self.assertEqual(resolve_executor_boundary('tjs_ort_bun_webgpu_package'), 'commands')

    def test_resolves_browser_ort_webgpu_executors(self) -> None:
        dawn_template = resolve_executor_command_template("browser_ort_webgpu_dawn")
        doe_template = resolve_executor_command_template("browser_ort_webgpu_doe")
        self.assertIn("run-browser-ort-bench.py", dawn_template)
        self.assertIn("run-browser-ort-bench.py", doe_template)
        self.assertIn("--mode dawn", dawn_template)
        self.assertIn("--mode doe", doe_template)
        self.assertEqual(resolve_executor_boundary("browser_ort_webgpu_dawn"), "commands")
        self.assertEqual(resolve_executor_boundary("browser_ort_webgpu_doe"), "commands")

    def test_resolves_doppler_node_doe_executor(self) -> None:
        template = resolve_executor_command_template('doppler_node_doe')
        self.assertIn('run-node-doppler-ort-bench.js', template)
        self.assertIn('--scenario {commands}', template)
        self.assertEqual(resolve_executor_boundary('doppler_node_doe'), 'commands')

    def test_rejects_unknown_executor(self) -> None:
        with self.assertRaises(ValueError):
            resolve_executor_command_template("unknown_executor")


if __name__ == "__main__":
    unittest.main()
