from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = REPO_ROOT / "browser/chromium/scripts/score-browser-layered-report.py"
HASH_A = "a" * 64
HASH_B = "b" * 64


def _load_module() -> Any:
    spec = importlib.util.spec_from_file_location("score_browser_layered_report", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load module: {MODULE_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _mode_result(
    value: float,
    metric: str = "usPerOp",
    status: str = "ok",
    extra_metrics: dict[str, float] | None = None,
) -> dict[str, Any]:
    metrics = {metric: value, "elapsedMs": value / 1000.0}
    if extra_metrics:
        metrics.update(extra_metrics)
    return {
        "status": status,
        "statusCode": "ok" if status == "ok" else "scenario_runtime_error",
        "error": None if status == "ok" else "failed",
        "metrics": metrics,
    }


def _report() -> dict[str, Any]:
    return {
        "schemaVersion": 2,
        "reportKind": "browser-layered-diagnostic",
        "benchmarkClass": "directional",
        "comparisonStatus": "diagnostic",
        "claimStatus": "diagnostic",
        "timingClass": "scenario",
        "timingSource": "browser-performance-now",
        "projectionContractHash": HASH_A,
        "reportHash": HASH_B,
        "workloadIdentity": {
            "kind": "browser_layered_superset",
            "projectionContractHash": HASH_A,
        },
        "browserEnvironmentEvidence": {
            "pageTargetKind": "local_http",
        },
        "methodology": {
            "adapterRequest": {
                "powerPreference": "high-performance",
            },
        },
        "modeOrder": ["dawn", "doe"],
        "modeChromePaths": {
            "dawn": "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "doe": "browser/chromium/src/out/fawn_release/Chromium.app/Contents/MacOS/Chromium",
        },
        "modeRunDetails": [
            {
                "mode": "dawn",
                "hash": HASH_A,
                "previousHash": "0" * 64,
                "runtimeSelection": {
                    "selectedRuntime": "dawn",
                    "fallbackApplied": False,
                    "fallbackReasonCode": "",
                    "hiddenFallbackAllowed": False,
                    "selectorVersion": "browser-runtime-selector-v1",
                    "artifactIdentity": {
                        "browserExecutablePath": "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                        "browserExecutableSha256": HASH_A,
                        "dawnRuntimePath": "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                        "dawnRuntimeSha256": HASH_A,
                        "doeLibPath": None,
                        "doeLibSha256": None,
                    },
                },
                "shaderCompilerIdentity": {"compilerArtifactSha256": HASH_A},
                "runtimeProbe": {"adapterIdentity": {"adapterInfoSha256": HASH_A}},
            },
            {
                "mode": "doe",
                "hash": HASH_B,
                "previousHash": HASH_A,
                "runtimeSelection": {
                    "selectedRuntime": "doe",
                    "fallbackApplied": False,
                    "fallbackReasonCode": "",
                    "hiddenFallbackAllowed": False,
                    "selectorVersion": "browser-runtime-selector-v1",
                    "artifactIdentity": {
                        "browserExecutablePath": "browser/chromium/src/out/fawn_release/Chromium.app/Contents/MacOS/Chromium",
                        "browserExecutableSha256": HASH_B,
                        "dawnRuntimePath": "browser/chromium/src/out/fawn_release/Chromium.app/Contents/MacOS/Chromium",
                        "dawnRuntimeSha256": HASH_B,
                        "doeLibPath": "runtime/zig/zig-out/lib/libwebgpu_doe_full.dylib",
                        "doeLibSha256": HASH_B,
                    },
                },
                "shaderCompilerIdentity": {"compilerArtifactSha256": HASH_B},
                "runtimeProbe": {"adapterIdentity": {"adapterInfoSha256": HASH_B}},
            },
        ],
        "l1": {
            "rows": [
                {
                    "sourceWorkloadId": "compute_dispatch",
                    "domain": "compute",
                    "scenarioTemplate": "compute_dispatch_basic",
                    "runtimes": {
                        "dawn": _mode_result(10.0),
                        "doe": _mode_result(5.0),
                    },
                },
                {
                    "sourceWorkloadId": "render_triangle",
                    "domain": "render",
                    "scenarioTemplate": "render_triangle_readback",
                    "runtimes": {
                        "dawn": _mode_result(10.0, status="fail"),
                        "doe": _mode_result(5.0),
                    },
                },
            ]
        },
        "l2": {
            "rows": [
                {
                    "id": "queue_submit_burst",
                    "scenarioTemplate": "queue_submit_burst",
                    "runtimes": {
                        "dawn": _mode_result(8.0, "usPerSubmit"),
                        "doe": _mode_result(4.0, "usPerSubmit"),
                    },
                },
                {
                    "id": "fawn_visual_particle_trails",
                    "scenarioTemplate": "fawn_visual_resource",
                    "resourcePath": "browser/chromium/resources/fawn-heavy-particles.html",
                    "resourceSha256": HASH_A,
                    "runtimes": {
                        "dawn": _mode_result(16.0, "avgFrameMs"),
                        "doe": _mode_result(8.0, "avgFrameMs"),
                    },
                }
            ]
        },
    }


class BrowserLayeredScoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = _load_module()

    def test_score_uses_geomean_and_categories(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            report_path = Path(tmpdir) / "report.json"
            report_path.write_text(json.dumps(_report()), encoding="utf-8")
            score = self.module.build_score_report(
                _report(),
                report_path=report_path,
                baseline_mode="dawn",
                comparison_mode="doe",
            )

        self.assertEqual(score["reportKind"], "browser-layered-score")
        self.assertEqual(score["claimStatus"], "diagnostic")
        self.assertEqual(
            score["methodology"]["adapterRequest"]["powerPreference"],
            "high-performance",
        )
        self.assertAlmostEqual(score["overall"]["score"], 33.333333333333336)
        self.assertAlmostEqual(score["overall"]["legacyRatioScore"], 200.0)
        self.assertAlmostEqual(score["overall"]["baselineScore"], 33.333333333333336)
        self.assertAlmostEqual(score["overall"]["comparisonScore"], 66.66666666666667)
        self.assertAlmostEqual(score["overall"]["comparisonDeltaPercent"], -100.0)
        self.assertEqual(score["overall"]["rowCount"], 3)
        self.assertAlmostEqual(score["categoryBalancedOverall"]["score"], 33.333333333333336)
        self.assertAlmostEqual(score["categoryBalancedOverall"]["legacyRatioScore"], 200.0)
        self.assertAlmostEqual(score["categoryBalancedOverall"]["baselineScore"], 33.333333333333336)
        self.assertAlmostEqual(score["categoryBalancedOverall"]["comparisonScore"], 66.66666666666667)
        self.assertAlmostEqual(score["categoryBalancedOverall"]["comparisonDeltaPercent"], -100.0)
        self.assertEqual(score["categoryBalancedOverall"]["categoryCount"], 3)
        self.assertEqual(score["bottlenecks"]["slowerCategoryCount"], 3)
        self.assertEqual(score["bottlenecks"]["slowerRowCount"], 3)
        self.assertEqual(score["bottlenecks"]["slowerPhaseCount"], 0)
        self.assertEqual(
            [row["category"] for row in score["bottlenecks"]["worstCategories"]],
            ["compute", "queue", "visual"],
        )
        self.assertEqual(
            [row["rowId"] for row in score["bottlenecks"]["worstRows"]],
            ["compute_dispatch", "queue_submit_burst", "fawn_visual_particle_trails"],
        )
        self.assertEqual(score["bottlenecks"]["worstPhases"], [])
        categories = {row["category"]: row for row in score["categories"]}
        self.assertEqual(categories["compute"]["score"], 33.333333333333336)
        self.assertEqual(categories["compute"]["legacyRatioScore"], 200.0)
        self.assertEqual(categories["queue"]["score"], 33.333333333333336)
        self.assertEqual(categories["queue"]["legacyRatioScore"], 200.0)
        self.assertEqual(categories["visual"]["score"], 33.333333333333336)
        self.assertEqual(categories["visual"]["legacyRatioScore"], 200.0)
        visual_row = next(row for row in score["rows"] if row["category"] == "visual")
        self.assertEqual(visual_row["resourcePath"], "browser/chromium/resources/fawn-heavy-particles.html")
        self.assertEqual(visual_row["resourceSha256"], HASH_A)
        self.assertAlmostEqual(visual_row["baselineScore"], 33.333333333333336)
        self.assertAlmostEqual(visual_row["comparisonScore"], 66.66666666666667)
        self.assertAlmostEqual(visual_row["comparisonDeltaPercent"], -100.0)
        self.assertEqual(score["excludedRows"][0]["rowId"], "render_triangle")
        self.assertEqual(score["workloadIdentity"]["kind"], "browser_layered_superset")
        self.assertEqual(score["workloadFilter"], {"kind": "none", "categories": []})
        self.assertEqual(score["modeIdentities"]["comparison"]["doeRuntimeSha256"], HASH_B)
        self.assertEqual(score["modeIdentities"]["baseline"]["traceHash"], HASH_A)

    def test_selected_metric_distribution_preserves_order_balanced_samples(self) -> None:
        distribution = self.module.selected_metric_distribution(
            {
                "usPerOp": 11.0,
                "orderBalancedMetricSamples": {
                    "usPerOp": [10.0, 12.0, 9.0, 13.0],
                },
            },
            "usPerOp",
        )

        self.assertEqual(distribution["orderBalancedSampleCount"], 4)
        self.assertEqual(distribution["orderBalancedSamples"], [10.0, 12.0, 9.0, 13.0])

    def test_category_balanced_score_does_not_row_weight_categories(self) -> None:
        report = _report()
        report["l1"]["rows"] = [
            {
                "sourceWorkloadId": "compute_fast",
                "domain": "compute",
                "scenarioTemplate": "compute_fast",
                "runtimes": {
                    "dawn": _mode_result(40.0),
                    "doe": _mode_result(10.0),
                },
            },
            {
                "sourceWorkloadId": "compute_parity",
                "domain": "compute",
                "scenarioTemplate": "compute_parity",
                "runtimes": {
                    "dawn": _mode_result(10.0),
                    "doe": _mode_result(10.0),
                },
            },
        ]
        report["l2"]["rows"] = [
            {
                "id": "fawn_visual_particle_trails",
                "scenarioTemplate": "fawn_visual_resource",
                "resourcePath": "browser/chromium/resources/fawn-heavy-particles.html",
                "resourceSha256": HASH_A,
                "runtimes": {
                    "dawn": _mode_result(10.0, "avgFrameMs"),
                    "doe": _mode_result(20.0, "avgFrameMs"),
                },
            }
        ]

        with tempfile.TemporaryDirectory() as tmpdir:
            report_path = Path(tmpdir) / "report.json"
            report_path.write_text(json.dumps(report), encoding="utf-8")
            score = self.module.build_score_report(
                report,
                report_path=report_path,
                baseline_mode="dawn",
                comparison_mode="doe",
            )

        self.assertNotAlmostEqual(
            score["overall"]["score"],
            score["categoryBalancedOverall"]["score"],
        )
        self.assertAlmostEqual(score["overall"]["score"], 44.24933340244421)
        self.assertAlmostEqual(score["overall"]["legacyRatioScore"], 125.99210498948732)
        self.assertAlmostEqual(score["overall"]["comparisonDeltaPercent"], -25.99210498948732)
        self.assertAlmostEqual(score["categoryBalancedOverall"]["score"], 50.0)
        self.assertAlmostEqual(score["categoryBalancedOverall"]["legacyRatioScore"], 100.0)
        self.assertAlmostEqual(score["categoryBalancedOverall"]["baselineScore"], 50.0)
        self.assertAlmostEqual(score["categoryBalancedOverall"]["comparisonScore"], 50.0)
        self.assertAlmostEqual(score["categoryBalancedOverall"]["comparisonDeltaPercent"], 0.0)
        self.assertEqual(score["categoryBalancedOverall"]["categoryCount"], 2)
        self.assertEqual(score["categoryBalancedOverall"]["rowCount"], 3)

    def test_score_reports_worst_bottleneck_categories_and_rows(self) -> None:
        report = _report()
        report["l1"]["rows"] = [
            {
                "sourceWorkloadId": "texture_sampler_write_query_destroy",
                "domain": "texture-contract",
                "scenarioTemplate": "texture_write_query_destroy",
                "runtimes": {
                    "dawn": _mode_result(
                        10.0,
                        "textureMs",
                        extra_metrics={"waitMs": 4.0, "createViewMs": 1.0},
                    ),
                    "doe": _mode_result(
                        20.0,
                        "textureMs",
                        extra_metrics={"waitMs": 12.0, "createViewMs": 1.5},
                    ),
                },
            },
            {
                "sourceWorkloadId": "compute_fast",
                "domain": "compute",
                "scenarioTemplate": "compute_fast",
                "runtimes": {
                    "dawn": _mode_result(40.0),
                    "doe": _mode_result(10.0),
                },
            },
        ]
        report["l2"]["rows"] = [
            {
                "id": "queue_submit_burst",
                "scenarioTemplate": "queue_submit_burst",
                "runtimes": {
                    "dawn": _mode_result(12.0, "usPerSubmit"),
                    "doe": _mode_result(18.0, "usPerSubmit"),
                },
            }
        ]

        with tempfile.TemporaryDirectory() as tmpdir:
            report_path = Path(tmpdir) / "report.json"
            report_path.write_text(json.dumps(report), encoding="utf-8")
            score = self.module.build_score_report(
                report,
                report_path=report_path,
                baseline_mode="dawn",
                comparison_mode="doe",
        )

        bottlenecks = score["bottlenecks"]
        self.assertEqual(bottlenecks["slowerCategoryCount"], 1)
        self.assertEqual(bottlenecks["slowerRowCount"], 1)
        self.assertEqual(bottlenecks["slowerPhaseCount"], 0)
        self.assertEqual(
            [row["category"] for row in bottlenecks["worstCategories"]],
            ["compute"],
        )
        self.assertEqual(
            [row["rowId"] for row in bottlenecks["worstRows"]],
            ["compute_fast"],
        )
        self.assertEqual(bottlenecks["worstRows"][0]["metric"], "usPerOp")
        self.assertAlmostEqual(
            bottlenecks["worstRows"][0]["comparisonDeltaPercent"],
            -300.0,
        )
        self.assertEqual(bottlenecks["worstPhases"], [])
        self.assertEqual(score["rows"][0]["phaseMetrics"][0]["metric"], "createViewMs")

    def test_texture_metric_is_preferred_before_elapsed_time(self) -> None:
        report = _report()
        report["l1"]["rows"] = [
            {
                "sourceWorkloadId": "texture_sampler_write_query_destroy",
                "domain": "texture-contract",
                "scenarioTemplate": "texture_write_query_destroy",
                "runtimes": {
                    "dawn": {
                        "status": "ok",
                        "statusCode": "ok",
                        "error": None,
                        "metrics": {"textureMs": 12.0, "elapsedMs": 100.0},
                    },
                    "doe": {
                        "status": "ok",
                        "statusCode": "ok",
                        "error": None,
                        "metrics": {"textureMs": 6.0, "elapsedMs": 300.0},
                    },
                },
            }
        ]
        report["l2"]["rows"] = []

        with tempfile.TemporaryDirectory() as tmpdir:
            report_path = Path(tmpdir) / "report.json"
            report_path.write_text(json.dumps(report), encoding="utf-8")
            score = self.module.build_score_report(
                report,
                report_path=report_path,
                baseline_mode="dawn",
                comparison_mode="doe",
            )

        self.assertEqual(score["rows"][0]["metric"], "textureMs")
        self.assertAlmostEqual(score["rows"][0]["baselineValue"], 12.0)
        self.assertAlmostEqual(score["rows"][0]["comparisonValue"], 6.0)
        self.assertAlmostEqual(score["overall"]["comparisonDeltaPercent"], -100.0)

    def test_render_metric_is_preferred_before_elapsed_time(self) -> None:
        report = _report()
        report["l1"]["rows"] = [
            {
                "sourceWorkloadId": "render_draw_throughput_baseline",
                "domain": "render",
                "scenarioTemplate": "render_triangle_readback",
                "runtimes": {
                    "dawn": {
                        "status": "ok",
                        "statusCode": "ok",
                        "error": None,
                        "metrics": {"renderMs": 9.0, "elapsedMs": 100.0},
                    },
                    "doe": {
                        "status": "ok",
                        "statusCode": "ok",
                        "error": None,
                        "metrics": {"renderMs": 3.0, "elapsedMs": 300.0},
                    },
                },
            }
        ]
        report["l2"]["rows"] = []

        with tempfile.TemporaryDirectory() as tmpdir:
            report_path = Path(tmpdir) / "report.json"
            report_path.write_text(json.dumps(report), encoding="utf-8")
            score = self.module.build_score_report(
                report,
                report_path=report_path,
                baseline_mode="dawn",
                comparison_mode="doe",
            )

        self.assertEqual(score["rows"][0]["metric"], "renderMs")
        self.assertAlmostEqual(score["rows"][0]["baselineValue"], 9.0)
        self.assertAlmostEqual(score["rows"][0]["comparisonValue"], 3.0)
        self.assertAlmostEqual(score["overall"]["comparisonDeltaPercent"], -200.0)

    def test_score_keeps_filtered_cross_category_report_context(self) -> None:
        report = _report()
        report["workloadFilter"] = {
            "kind": "category",
            "categories": ["compute", "visual"],
            "l1RowsBeforeFilter": 2,
            "l1RowsAfterFilter": 1,
            "l2RowsBeforeFilter": 2,
            "l2RowsAfterFilter": 1,
        }

        with tempfile.TemporaryDirectory() as tmpdir:
            report_path = Path(tmpdir) / "report.json"
            report_path.write_text(json.dumps(report), encoding="utf-8")
            score = self.module.build_score_report(
                report,
                report_path=report_path,
                baseline_mode="dawn",
                comparison_mode="doe",
            )

        self.assertEqual(score["workloadFilter"]["kind"], "category")
        self.assertEqual(score["workloadFilter"]["categories"], ["compute", "visual"])
        self.assertAlmostEqual(score["overall"]["baselineScore"], 33.333333333333336)
        self.assertAlmostEqual(score["overall"]["comparisonScore"], 66.66666666666667)
        self.assertAlmostEqual(score["overall"]["comparisonDeltaPercent"], -100.0)

    def test_cli_writes_score_report(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            report_path = Path(tmpdir) / "report.json"
            out_path = Path(tmpdir) / "score.json"
            report_path.write_text(json.dumps(_report()), encoding="utf-8")
            completed = subprocess.run(
                [
                    sys.executable,
                    str(MODULE_PATH),
                    "--report",
                    str(report_path),
                    "--out",
                    str(out_path),
                ],
                cwd=REPO_ROOT,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            payload = json.loads(out_path.read_text(encoding="utf-8"))

        self.assertEqual(payload["overall"]["rowCount"], 3)
        self.assertIn("doe=66.67 dawn=33.33 delta=+50.00%", completed.stdout)
        self.assertIn("categoryBalanced.doe=66.67 categoryBalanced.dawn=33.33", completed.stdout)
        self.assertIn("[browser-score]", completed.stdout)


if __name__ == "__main__":
    unittest.main()
