#!/usr/bin/env python3
"""Tests for browser claim gate artifact preservation."""

from __future__ import annotations

import json
import unittest
from pathlib import Path

from bench.browser.browser_claim_gate import (
    build_structural_receipts,
    chromium_patch_manifest_failures,
    extract_claim_rows,
    load_projection_manifest_rows,
    reuse_window_artifacts,
)


def test_reuse_window_artifacts_preserves_capability_artifact_paths(tmp_path: Path) -> None:
    for name in (
        "dawn-vs-doe.browser.playwright-smoke.diagnostic.json",
        "browser-cts-subset.json",
        "browser-recovery-parity.json",
        "browser-canvas-webgpu-fusion.json",
        "browser-media-path-probe.json",
        "browser-gpu-scheduler.json",
        "browser-webgpu-effect-experiment.json",
        "browser-gpu-flight-recorder.json",
        "browser-gpu-flight-replay.json",
        "browser-shader-links.json",
        "browser-local-ai-workloads.json",
        "browser-pipeline-cache-receipts.json",
        "browser-fallback-explanations.json",
        "dawn-vs-doe.browser-layered.superset.diagnostic.json",
        "dawn-vs-doe.browser-layered.superset.summary.json",
        "dawn-vs-doe.browser-layered.superset.check.json",
    ):
        (tmp_path / name).write_text("{}\n", encoding="utf-8")

    artifacts = reuse_window_artifacts(tmp_path)

    assert "smokeReport" in artifacts
    assert "ctsSubsetReport" in artifacts
    assert "recoveryParityReport" in artifacts
    assert "canvasWebgpuFusionReport" in artifacts
    assert "mediaPathProbeReport" in artifacts
    assert "gpuSchedulerReport" in artifacts
    assert "webgpuEffectExperimentReport" in artifacts
    assert "flightRecorderReport" in artifacts
    assert "flightReplayReport" in artifacts
    assert "shaderLinksReport" in artifacts
    assert "localAiWorkloadsReport" in artifacts
    assert "pipelineCacheReceiptsReport" in artifacts
    assert "fallbackExplanationsReport" in artifacts
    assert "layeredReport" in artifacts
    assert "summaryReport" in artifacts
    assert "checkReport" in artifacts


def test_chromium_patch_manifest_resolution_rejects_policy_path_escape(tmp_path: Path) -> None:
    policy_path = tmp_path / "chromium-fork-maintenance-policy.json"
    policy_path.write_text(
        '{"patchIsolation": {"patchManifestPath": "../outside/manifest.json"}}\n',
        encoding="utf-8",
    )

    assert chromium_patch_manifest_failures(policy_path, tmp_path) == [
        "chromium-patch-manifest: failed to resolve manifest path: "
        "patchIsolation.patchManifestPath must be repo-relative: ../outside/manifest.json"
    ]


class BrowserClaimGateStructuralReceiptTests(unittest.TestCase):
    def test_extract_claim_rows_uses_projection_manifest_browser_workload(self) -> None:
        layered_report = {
            "l1": {
                "rows": [
                    {
                        "sourceWorkloadId": "source_kernel",
                        "sourceWorkloadName": "source kernel",
                        "comparabilityExpectation": "strict",
                        "claimScope": "l1_strict_candidate",
                        "requiredStatus": "ok",
                    }
                ]
            }
        }
        projection_rows = {
            "source_kernel": {
                "sourceWorkloadId": "source_kernel",
                "browserWorkload": {
                    "computeProjection": "source_kernel_dispatch_v1",
                    "commandsPath": "bench/workloads/source_kernel.commands.json",
                    "commandsSha256": "a" * 64,
                    "kernelPath": "bench/workloads/source_kernel.wgsl",
                    "kernelSha256": "b" * 64,
                    "dispatchX": 4,
                    "dispatchY": 1,
                    "dispatchZ": 1,
                    "dispatchRepeat": 8,
                    "warmupDispatchCount": 2,
                },
            }
        }

        rows = extract_claim_rows(
            layered_report,
            {"l1_strict_candidate"},
            projection_rows,
        )

        self.assertEqual(
            rows["source_kernel"]["browserWorkload"]["computeProjection"],
            "source_kernel_dispatch_v1",
        )

    def test_load_projection_manifest_rows_rejects_duplicate_workload_ids(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as tmp_dir:
            manifest_path = Path(tmp_dir) / "browser_projection_manifest.json"
            manifest_path.write_text(
                json.dumps(
                    {
                        "rows": [
                            {
                                "sourceWorkloadId": "source_kernel",
                                "browserWorkload": {},
                            },
                            {
                                "sourceWorkloadId": "source_kernel",
                                "browserWorkload": {},
                            },
                        ]
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            rows, failures = load_projection_manifest_rows(manifest_path)

        self.assertEqual(list(rows), ["source_kernel"])
        self.assertEqual(
            failures,
            ["projection-manifest: duplicate sourceWorkloadId source_kernel"],
        )

    def test_build_structural_receipts_summarizes_source_kernel_dispatch(self) -> None:
        import tempfile

        with tempfile.TemporaryDirectory() as tmp_dir:
            tmp_path = Path(tmp_dir)
            check_report = tmp_path / "dawn-vs-doe.browser-layered.superset.check.json"
            check_report.write_text(
                json.dumps(
                    {
                        "ok": True,
                        "reportChecked": True,
                        "errorCount": 0,
                        "errors": [],
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            claim_rows = {
                "source_kernel": {
                    "browserWorkload": {
                        "computeProjection": "source_kernel_dispatch_v1",
                        "commandsPath": "bench/workloads/source_kernel.commands.json",
                        "commandsSha256": "a" * 64,
                        "kernelPath": "bench/workloads/source_kernel.wgsl",
                        "kernelSha256": "b" * 64,
                        "dispatchX": 4,
                        "dispatchY": 1,
                        "dispatchZ": 1,
                        "dispatchRepeat": 8,
                        "warmupDispatchCount": 2,
                    },
                    "runtimes": {
                        "dawn": {"status": "ok"},
                        "doe": {"status": "ok"},
                    },
                }
            }

            summary = build_structural_receipts(
                [{"checkReport": str(check_report)}],
                claim_rows,
            )

        self.assertEqual(summary["status"], "pass")
        self.assertIs(summary["sourceCommandIdentity"]["verified"], True)
        self.assertIs(summary["dispatchShapeParity"]["verified"], True)
        self.assertEqual(
            summary["checkerReports"],
            [{"path": str(check_report), "status": "pass", "errorCount": 0}],
        )
        self.assertEqual(summary["failureCodes"], [])


if __name__ == "__main__":
    unittest.main()
