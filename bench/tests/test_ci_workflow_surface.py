#!/usr/bin/env python3
"""Repository-level contracts for the GitHub Actions surface."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
WORKFLOW_ROOT = REPO_ROOT / ".github" / "workflows"

AUTOMATIC_WORKFLOWS = {
    "agent-sync.yml": {"pull_request", "push", "workflow_dispatch"},
    "doe-gpu-native-freshness.yml": {"pull_request", "push", "workflow_dispatch"},
    "lean-check.yml": {"pull_request", "push", "workflow_dispatch"},
    "nightly-quirk-mining.yml": {"schedule", "workflow_dispatch"},
    "publication-hygiene.yml": {"pull_request", "push"},
    "webgpu-package-surface.yml": {"pull_request", "push", "workflow_dispatch"},
    "wgsl-compiler.yml": {"pull_request", "push", "workflow_dispatch"},
}

MANUAL_WORKFLOWS = {
    "amd-vulkan-smoke.yml",
    "dropin-compat.yml",
    "macos-browser-refresh.yml",
    "release-claim-trends.yml",
    "release-gates.yml",
}

STALE_PATH_PATTERNS = {
    r"\bcd zig\b": "runtime/zig must be the workflow working directory",
    r"(?<!runtime/)\bzig/zig-out": "runtime artifacts live under runtime/zig/zig-out",
    r"\bbench/run_": "benchmark runners live under bench/runners",
    r"\bbench/dropin_gate\.py": "the drop-in gate lives under bench/drop-in",
    r"\bbench/bootstrap_dawn\.py": "Dawn bootstrap lives under bench/tools",
    r"\bbench/browser_claim_gate\.py": "browser gates live under bench/browser",
    r"\bbench/cleanup_out\.py": "cleanup tooling lives under bench/tools",
    r"\bbench/build_test_inventory_dashboard\.py": "dashboard tooling lives under bench/tools",
    r"\bnursery/(?:chromium|webgpu)\b": "active browser and package surfaces left nursery",
}

WORKFLOW_ENTRYPOINTS = {
    "bench/browser/browser_claim_gate.py",
    "bench/drop-in/dropin_gate.py",
    "bench/native-compare/compare.config.amd.vulkan.release.json",
    "bench/native-compare/compare.config.amd.vulkan.smoke.gpu.json",
    "bench/runners/run_blocking_gates.py",
    "bench/runners/run_release_claim_windows.py",
    "bench/runners/run_release_pipeline.py",
    "bench/tools/bootstrap_dawn.py",
    "bench/tools/bootstrap_zig.py",
    "bench/tools/build_test_inventory_dashboard.py",
    "bench/tools/cleanup_out.py",
    "browser/chromium/scripts/cleanup-browser-artifacts.py",
    "config/toolchains.json",
    "packages/doe-gpu",
    "pipeline/lean/extract.sh",
    "pipeline/lean/test_proof_pipeline.py",
    "pipeline/upstream_intelligence/__main__.py",
    "runtime/zig",
}


def workflow_text(name: str) -> str:
    return (WORKFLOW_ROOT / name).read_text(encoding="utf-8")


def workflow_triggers(text: str) -> set[str]:
    lines = text.splitlines()
    try:
        start = lines.index("on:") + 1
    except ValueError as exc:
        raise AssertionError("workflow must use a block-style on section") from exc

    triggers: set[str] = set()
    for line in lines[start:]:
        if line and not line.startswith((" ", "\t")):
            break
        match = re.match(r"^  ([a-z_]+):", line)
        if match:
            triggers.add(match.group(1))
    return triggers


class CiWorkflowSurfaceTests(unittest.TestCase):
    def test_workflow_inventory_is_intentional(self) -> None:
        actual = {path.name for path in WORKFLOW_ROOT.glob("*.yml")}
        expected = set(AUTOMATIC_WORKFLOWS) | MANUAL_WORKFLOWS
        self.assertEqual(actual, expected)

    def test_automatic_workflow_triggers_are_explicit(self) -> None:
        for name, expected in AUTOMATIC_WORKFLOWS.items():
            with self.subTest(workflow=name):
                self.assertEqual(workflow_triggers(workflow_text(name)), expected)

    def test_hardware_and_vendor_workflows_are_manual(self) -> None:
        for name in MANUAL_WORKFLOWS:
            with self.subTest(workflow=name):
                self.assertEqual(workflow_triggers(workflow_text(name)), {"workflow_dispatch"})

    def test_automatic_self_hosted_job_is_manual_only(self) -> None:
        text = workflow_text("doe-gpu-native-freshness.yml")
        self.assertIn("if: github.event_name == 'workflow_dispatch'", text)

    def test_native_freshness_enforces_node_bun_and_electron_clean_install(self) -> None:
        text = workflow_text("doe-gpu-native-freshness.yml")
        self.assertIn("uses: oven-sh/setup-bun@v2", text)
        self.assertIn('bun-version: "1.3.10"', text)
        self.assertIn('ELECTRON_VERSION: "43.4.0"', text)
        self.assertIn("DOE_ELECTRON_EXECUTABLE=$electron_executable", text)
        self.assertIn(
            "run: npm run test:integration:native-clean-install\n", text
        )
        self.assertIn(
            "run: npm run test:integration:native-clean-install:bun\n", text
        )
        self.assertIn(
            "run: npm run test:integration:native-clean-install:electron\n", text
        )
        self.assertIn(
            "run: npm run test:integration:native-reliability\n", text
        )
        self.assertIn(
            "run: npm run test:integration:native-reliability:bun\n", text
        )
        self.assertIn(
            "run: npm run test:integration:native-reliability:electron\n", text
        )

    def test_package_surface_runs_complete_hosted_suite(self) -> None:
        text = workflow_text("webgpu-package-surface.yml")
        self.assertIn("run: npm test\n", text)
        self.assertIn("run: python3 bench/gates/tool_surface_gate.py\n", text)
        self.assertIn("run: npm pack --dry-run --json\n", text)

    def test_amd_smoke_declares_its_nonstandard_lane(self) -> None:
        text = workflow_text("amd-vulkan-smoke.yml")
        self.assertIn("--local-vulkan-lane vulkan_doe_comparable", text)

    def test_workflows_only_reference_current_repo_layout(self) -> None:
        for path in WORKFLOW_ROOT.glob("*.yml"):
            text = path.read_text(encoding="utf-8")
            for pattern, reason in STALE_PATH_PATTERNS.items():
                with self.subTest(workflow=path.name, pattern=pattern):
                    self.assertIsNone(re.search(pattern, text), reason)

    def test_workflow_entrypoints_exist(self) -> None:
        for relative_path in WORKFLOW_ENTRYPOINTS:
            with self.subTest(path=relative_path):
                self.assertTrue((REPO_ROOT / relative_path).exists())

    def test_official_actions_use_node_24_compatible_majors(self) -> None:
        combined = "\n".join(workflow_text(path.name) for path in WORKFLOW_ROOT.glob("*.yml"))
        expected_majors = {
            "actions/cache": "v4",
            "actions/checkout": "v7",
            "actions/setup-node": "v6",
            "actions/upload-artifact": "v7",
            "actions/download-artifact": "v8",
        }
        for action, expected in expected_majors.items():
            versions = set(re.findall(rf"{re.escape(action)}@(v\d+)", combined))
            with self.subTest(action=action):
                self.assertLessEqual(versions, {expected})


if __name__ == "__main__":
    unittest.main()
