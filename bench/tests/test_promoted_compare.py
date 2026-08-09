#!/usr/bin/env python3
"""Tests for promoted compare wrapper resolution."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in sys.path:
        sys.path.insert(0, _path_entry)

from bench.native_compare_modules.promoted_compare import (  # noqa: E402
    DEFAULT_COMPARE_CLI,
    default_mode_for_surface,
    load_catalog,
    resolve_entry,
    build_run_config_argvs,
    filter_selection_passthrough,
)


class PromotedCompareTests(unittest.TestCase):
    def test_default_mode_by_surface(self) -> None:
        self.assertEqual(default_mode_for_surface("backend"), "default")
        self.assertEqual(default_mode_for_surface("plan"), "default")
        self.assertEqual(default_mode_for_surface("package"), "cold")

    def test_resolve_backend_entry_by_preset(self) -> None:
        entries = load_catalog(REPO_ROOT / "config" / "promoted-compare-catalog.json")
        entry = resolve_entry(
            entries,
            backend="apple-metal",
            surface="backend",
            preset="compare",
        )
        self.assertEqual(entry.id, "apple-metal-backend-compare")
        self.assertEqual(entry.boundary, "backend_native")
        self.assertEqual(entry.runtime_host, "none")
        self.assertEqual(entry.temperature, "default")
        self.assertEqual(entry.comparison_view, "doe_vs_dawn_delegate")
        self.assertEqual(entry.provider_set, "backend_native_providers")
        self.assertEqual(entry.baseline_executor_id, "doe_direct_metal")
        self.assertEqual(entry.comparison_executor_id, "dawn_delegate_metal")

    def test_resolve_plan_entry_by_workload(self) -> None:
        entries = load_catalog(REPO_ROOT / "config" / "promoted-compare-catalog.json")
        entry = resolve_entry(
            entries,
            backend="apple-metal",
            surface="plan",
            workload="gemma270m-literal",
        )
        self.assertEqual(entry.id, "apple-metal-gemma270m-literal-plan")
        self.assertEqual(entry.baseline_executor_id, "doe_direct_plan_metal")
        self.assertEqual(entry.comparison_executor_id, "dawn_direct_metal")

    def test_resolve_package_warm_entry_by_workload(self) -> None:
        entries = load_catalog(REPO_ROOT / "config" / "promoted-compare-catalog.json")
        entry = resolve_entry(
            entries,
            backend="apple-metal",
            surface="package",
            workload="gemma64",
            mode="warm",
        )
        self.assertEqual(entry.id, "apple-metal-gemma64-package-warm")
        self.assertEqual(entry.package_runtime, "node")
        self.assertEqual(entry.runtime_host, "node")
        self.assertEqual(entry.temperature, "warm")
        self.assertEqual(entry.comparison_view, "doe_vs_dawn_node_webgpu_package")
        self.assertEqual(entry.baseline_executor_id, "doe_node_webgpu_prepared")
        self.assertEqual(entry.comparison_executor_id, "node_webgpu_package_prepared")

    def test_resolve_bun_package_warm_entry_by_workload(self) -> None:
        entries = load_catalog(REPO_ROOT / "config" / "promoted-compare-catalog.json")
        entry = resolve_entry(
            entries,
            backend="apple-metal",
            surface="package",
            workload="gemma64",
            mode="warm",
            package_runtime="bun",
        )
        self.assertEqual(entry.id, "apple-metal-gemma64-bun-package-warm")
        self.assertEqual(entry.package_runtime, "bun")
        self.assertEqual(entry.runtime_host, "bun")
        self.assertEqual(entry.comparison_view, "doe_vs_dawn_bun_webgpu_package")
        self.assertEqual(entry.baseline_executor_id, "doe_bun_package_prepared")
        self.assertEqual(entry.comparison_executor_id, "bun_webgpu_package_prepared")

    def test_native_direct_package_entry_uses_native_direct_provider_set(self) -> None:
        entries = load_catalog(REPO_ROOT / "config" / "promoted-compare-catalog.json")
        entry = resolve_entry(
            entries,
            profile_id="apple-metal-gemma270m-node-native-direct-decode-warm",
        )
        self.assertEqual(entry.comparison_view, "doe_native_direct_vs_dawn_node_webgpu_package")
        self.assertEqual(entry.provider_set, "package_node_native_direct_providers")
        self.assertEqual(entry.providers, ("doe-direct", "node-webgpu"))
        argvs = build_run_config_argvs(entry)
        for argv in argvs:
            self.assertIn("--provider-set", argv)
            self.assertEqual(
                argv[argv.index("--provider-set") + 1],
                "package_node_native_direct_providers",
            )

    def test_resolve_resident_buffer_load_package_entries_by_workload(self) -> None:
        entries = load_catalog(REPO_ROOT / "config" / "promoted-compare-catalog.json")
        node_entry = resolve_entry(
            entries,
            backend="apple-metal",
            surface="package",
            workload="gemma270m-decode-resident",
            mode="warm",
        )
        self.assertEqual(
            node_entry.id,
            "apple-metal-gemma270m-node-native-direct-decode-resident-warm",
        )
        self.assertEqual(
            node_entry.baseline_executor_id,
            "doe_node_native_direct_prepared_resident_buffer_loads",
        )
        self.assertEqual(
            node_entry.comparison_executor_id,
            "node_webgpu_package_prepared_resident_buffer_loads",
        )

        bun_entry = resolve_entry(
            entries,
            backend="apple-metal",
            surface="package",
            workload="gemma270m-decode-resident",
            mode="warm",
            package_runtime="bun",
        )
        self.assertEqual(
            bun_entry.id,
            "apple-metal-gemma270m-bun-package-decode-resident-warm",
        )
        self.assertEqual(
            bun_entry.baseline_executor_id,
            "doe_bun_package_prepared_resident_buffer_loads",
        )
        self.assertEqual(
            bun_entry.comparison_executor_id,
            "bun_webgpu_package_prepared_resident_buffer_loads",
        )

    def test_node_package_provider_sets_match_comparison_view(self) -> None:
        entries = load_catalog(REPO_ROOT / "config" / "promoted-compare-catalog.json")
        for entry in entries:
            if entry.comparison_view == "doe_native_direct_vs_dawn_node_webgpu_package":
                self.assertEqual(entry.provider_set, "package_node_native_direct_providers", entry.id)
                self.assertEqual(entry.providers, ("doe-direct", "node-webgpu"), entry.id)
            elif entry.comparison_view == "doe_vs_dawn_node_webgpu_package":
                self.assertEqual(entry.provider_set, "package_node_providers", entry.id)
                self.assertEqual(entry.providers, ("doe", "node-webgpu"), entry.id)

    def test_resolve_entry_by_profile_id(self) -> None:
        entries = load_catalog(REPO_ROOT / "config" / "promoted-compare-catalog.json")
        entry = resolve_entry(entries, profile_id="apple-metal-gemma1b-plan")
        self.assertEqual(entry.workload, "gemma1b")
        self.assertEqual(entry.surface, "plan")

    def test_resolve_backend_entry_by_profile_id(self) -> None:
        entries = load_catalog(REPO_ROOT / "config" / "promoted-compare-catalog.json")
        entry = resolve_entry(entries, profile_id="amd-vulkan-backend-release")
        self.assertEqual(entry.surface, "backend")
        self.assertEqual(entry.preset, "release")

    def test_build_run_config_argvs_use_canonical_cli(self) -> None:
        entries = load_catalog(REPO_ROOT / "config" / "promoted-compare-catalog.json")
        entry = resolve_entry(entries, profile_id="apple-metal-gemma64-package-cold")
        argvs = build_run_config_argvs(entry, passthrough=["--iterations", "20"])
        self.assertEqual(len(argvs), 2)
        for argv in argvs:
            self.assertEqual(argv[0], sys.executable)
            self.assertEqual(argv[1], str(DEFAULT_COMPARE_CLI))
            self.assertEqual(argv[2], "run-config")
            self.assertIn("--config", argv)
            self.assertIn("--boundary", argv)
            self.assertIn("package_surface", argv)
            self.assertIn("--runtime-host", argv)
            self.assertIn("node", argv)
            self.assertIn("--temperature", argv)
            self.assertIn("cold", argv)
            self.assertIn("--comparison-view", argv)
            self.assertIn("doe_vs_dawn_node_webgpu_package", argv)
            self.assertIn("--iterations", argv)
            self.assertIn("20", argv)
            self.assertIn(
                str(REPO_ROOT / "bench/native-compare/compare.config.apple.metal.gemma64.node-package.ir.json"),
                argv,
            )
        self.assertEqual(argvs[0][-2:], ["--side", "baseline"])
        self.assertEqual(argvs[1][-2:], ["--side", "comparison"])

    def test_workload_id_passthrough_uses_run_config_option(self) -> None:
        passthrough = filter_selection_passthrough(
            ["--workload-id", "compute_kernel", "--iterations", "3"]
        )
        self.assertEqual(
            passthrough,
            ["--workload-filter", "compute_kernel", "--iterations", "3"],
        )

    def test_build_run_config_argvs_resolve_config_relative_to_custom_catalog(self) -> None:
        with tempfile.TemporaryDirectory(prefix="doe-promoted-compare-") as tmpdir:
            tmp = Path(tmpdir)
            catalog_path = tmp / "catalog.json"
            config_path = tmp / "custom.compare.json"
            config_path.write_text("{}", encoding="utf-8")
            catalog_path.write_text(
                json.dumps({
                    "schemaVersion": 4,
                    "entries": [
                        {
                            "id": "custom-backend-compare",
                            "backend": "custom",
                            "surface": "backend",
                            "preset": "compare",
                            "mode": "default",
                            "benchmarkClass": "backend-runtime-preset",
                            "baselineExecutorId": "doe_direct_metal",
                            "comparisonExecutorId": "dawn_delegate_metal",
                            "configPath": "custom.compare.json",
                            "description": "custom entry",
                        }
                    ],
                }),
                encoding="utf-8",
            )
            entries = load_catalog(catalog_path)
            entry = resolve_entry(entries, profile_id="custom-backend-compare")
            argvs = build_run_config_argvs(entry, catalog_path=catalog_path)
            self.assertEqual(Path(argvs[0][4]).resolve(), config_path.resolve())

    def test_missing_workload_raises_clear_error(self) -> None:
        entries = load_catalog(REPO_ROOT / "config" / "promoted-compare-catalog.json")
        with self.assertRaises(ValueError):
            resolve_entry(
                entries,
                backend="apple-metal",
                boundary="package_surface",
                workload="gemma270m-literal",
            )

    def test_package_runtime_is_rejected_for_non_package_surface(self) -> None:
        entries = load_catalog(REPO_ROOT / "config" / "promoted-compare-catalog.json")
        with self.assertRaises(ValueError):
            resolve_entry(
                entries,
                backend="apple-metal",
                surface="plan",
                workload="gemma64",
                package_runtime="bun",
            )

    def test_preset_and_workload_cannot_both_be_set(self) -> None:
        entries = load_catalog(REPO_ROOT / "config" / "promoted-compare-catalog.json")
        with self.assertRaises(ValueError):
            resolve_entry(
                entries,
                backend="apple-metal",
                surface="plan",
                preset="compare",
                workload="gemma64",
            )


if __name__ == "__main__":
    unittest.main()
