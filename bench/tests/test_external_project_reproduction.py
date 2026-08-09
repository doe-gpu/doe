"""Tests for portable external-project preparation and reproduction plans."""

from __future__ import annotations

import unittest
from pathlib import Path

from bench.external_project_reproduction import reproduction_plan, resolve_selection


REPO_ROOT = Path(__file__).resolve().parents[2]


class ExternalProjectReproductionTest(unittest.TestCase):
    def test_cpp_ml_plan_bootstraps_pinned_zig_before_version_and_build(self) -> None:
        selection = resolve_selection(
            REPO_ROOT,
            "electronicarts-cpp-ml-intro",
            "mnist-webgpu-demo",
            run_id="portable-plan-test",
        )

        plan = reproduction_plan(selection)

        self.assertEqual(
            plan["bootstrapCommands"],
            [["python3", "bench/tools/bootstrap_zig.py"]],
        )
        self.assertIn(
            [".tooling/zig-0.15.2/zig", "version"],
            plan["versionCommands"],
        )
        self.assertIn(
            [
                "../../.tooling/zig-0.15.2/zig",
                "build",
                "dropin",
                "-Doptimize=ReleaseFast",
            ],
            plan["doeCommands"],
        )
        self.assertEqual(
            plan["upstreamRoot"],
            "bench/out/external-projects/electronicarts-cpp-ml-intro/upstream",
        )
        self.assertTrue(plan["workloadCommand"][-2:] == ["--run-id", "portable-plan-test"])


if __name__ == "__main__":
    unittest.main()
