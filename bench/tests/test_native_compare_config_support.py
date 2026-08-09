#!/usr/bin/env python3
"""Tests for native compare workload selection behavior."""

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

from bench.native_compare_modules import config_support


def _write_workloads(path: Path) -> None:
    payload = {
        "schemaVersion": 1,
        "workloads": [
            {
                "id": "alpha",
                "name": "alpha",
                "domain": "compute",
                "commandsPath": "examples/alpha.json",
                "quirksPath": "examples/quirks/noop.json",
                "vendor": "apple",
                "api": "metal",
                "family": "m3",
                "driver": "1.0.0",
                "extraArgs": [],
                "dawnFilter": "alpha",
                "comparable": True,
                "benchmarkClass": "comparable",
                "claimEligible": True,
                "cohorts": ["governed"],
            },
            {
                "id": "beta",
                "name": "beta",
                "domain": "compute",
                "commandsPath": "examples/beta.json",
                "quirksPath": "examples/quirks/noop.json",
                "vendor": "apple",
                "api": "metal",
                "family": "m3",
                "driver": "1.0.0",
                "extraArgs": [],
                "dawnFilter": "beta",
                "comparable": True,
                "benchmarkClass": "comparable",
                "claimEligible": True,
                "cohorts": ["governed"],
            },
            {
                "id": "gamma",
                "name": "gamma",
                "domain": "compute",
                "commandsPath": "examples/gamma.json",
                "quirksPath": "examples/quirks/noop.json",
                "vendor": "apple",
                "api": "metal",
                "family": "m3",
                "driver": "1.0.0",
                "extraArgs": [],
                "dawnFilter": "gamma",
                "comparable": True,
                "benchmarkClass": "comparable",
                "claimEligible": True,
                "cohorts": ["exploration"],
            },
        ],
    }
    path.write_text(json.dumps(payload), encoding="utf-8")


class NativeCompareConfigSupportTests(unittest.TestCase):
    def test_backend_smoke_configs_select_only_strict_comparable_rows(self) -> None:
        smoke_configs = [
            "compare.config.amd.vulkan.smoke.json",
            "compare.config.amd.vulkan.smoke.gpu.json",
            "compare.config.apple.metal.smoke.json",
            "compare.config.local.d3d12.smoke.json",
        ]
        policy = config_support.load_benchmark_methodology_policy(
            REPO_ROOT / "config" / "benchmark-methodology-thresholds.json"
        )
        self.assertEqual(policy.suspicious_speedup_ratio, 10.0)
        for config_name in smoke_configs:
            config_path = REPO_ROOT / "bench" / "native-compare" / config_name
            with self.subTest(config=config_name):
                config = json.loads(config_path.read_text(encoding="utf-8"))
                self.assertEqual(config["comparability"]["mode"], "strict")
                self.assertGreaterEqual(
                    config["run"]["iterations"],
                    policy.smoke_comparability_min_timed_samples,
                )
                workloads = config_support.load_workloads(
                    REPO_ROOT / config["workloads"],
                    config["run"].get("workloadFilter", ""),
                    include_noncomparable=bool(config["run"].get("includeNoncomparableWorkloads", False)),
                    include_extended=bool(config["run"].get("includeExtendedWorkloads", False)),
                    workload_cohort="all",
                    selector=config.get("selector"),
                )
                self.assertTrue(workloads)
                required_samples = (
                    policy.comparability_min_timed_samples
                    if any(workload.claim_eligible for workload in workloads)
                    else policy.smoke_comparability_min_timed_samples
                )
                self.assertGreaterEqual(
                    config["run"]["iterations"],
                    required_samples,
                )
                for workload in workloads:
                    self.assertTrue(workload.comparable, msg=workload.id)
                    self.assertEqual(workload.benchmark_class, "comparable", msg=workload.id)
                    self.assertFalse(workload.path_asymmetry, msg=workload.id)

    def test_load_workloads_preserves_ir_and_plan_paths(self) -> None:
        with tempfile.TemporaryDirectory(prefix="doe-native-compare-config-") as tmpdir:
            workloads_path = Path(tmpdir) / "workloads.json"
            payload = {
                "schemaVersion": 1,
                "workloads": [
                    {
                        "id": "alpha",
                        "name": "alpha",
                        "domain": "compute",
                        "commandsPath": "examples/alpha.json",
                        "irPath": "bench/ir/alpha.json",
                        "planPath": "bench/plans/alpha.json",
                        "quirksPath": "examples/quirks/noop.json",
                        "vendor": "apple",
                        "api": "metal",
                        "family": "m3",
                        "driver": "1.0.0",
                        "extraArgs": [],
                        "dawnFilter": "alpha",
                        "comparable": True,
                        "benchmarkClass": "comparable",
                        "claimEligible": True,
                        "cohorts": ["governed"],
                    }
                ],
            }
            workloads_path.write_text(json.dumps(payload), encoding="utf-8")
            workloads = config_support.load_workloads(
                workloads_path,
                "",
                include_noncomparable=False,
                include_extended=False,
                workload_cohort="all",
                selector=None,
            )
            self.assertEqual(len(workloads), 1)
            self.assertEqual(workloads[0].ir_path, "bench/ir/alpha.json")
            self.assertEqual(workloads[0].plan_path, "bench/plans/alpha.json")

    def test_workload_filter_intersects_selector_results(self) -> None:
        with tempfile.TemporaryDirectory(prefix="doe-native-compare-config-") as tmpdir:
            workloads_path = Path(tmpdir) / "workloads.json"
            _write_workloads(workloads_path)
            workloads = config_support.load_workloads(
                workloads_path,
                "beta",
                include_noncomparable=False,
                include_extended=False,
                workload_cohort="all",
                selector={"cohorts": ["governed"], "benchmarkClass": ["comparable"]},
            )
            self.assertEqual([workload.id for workload in workloads], ["beta"])

    def test_selector_still_applies_without_workload_filter(self) -> None:
        with tempfile.TemporaryDirectory(prefix="doe-native-compare-config-") as tmpdir:
            workloads_path = Path(tmpdir) / "workloads.json"
            _write_workloads(workloads_path)
            workloads = config_support.load_workloads(
                workloads_path,
                "",
                include_noncomparable=False,
                include_extended=False,
                workload_cohort="all",
                selector={"cohorts": ["governed"], "benchmarkClass": ["comparable"]},
            )
            self.assertEqual([workload.id for workload in workloads], ["alpha", "beta"])


if __name__ == "__main__":
    unittest.main()
