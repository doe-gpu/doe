from __future__ import annotations

import hashlib
import importlib.util
import json
import unittest
from pathlib import Path

from bench.tools import run_browser_render_oracle as oracle_runner


REPO_ROOT = Path(__file__).resolve().parents[2]
MANIFEST_PATH = (
    REPO_ROOT
    / "browser/chromium/bench/generated/browser_projection_manifest.apple.metal.json"
)
CHECKER_PATH = REPO_ROOT / "browser/chromium/scripts/check-browser-benchmark-superset.py"


def load_checker():
    spec = importlib.util.spec_from_file_location("browser_superset_checker", CHECKER_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {CHECKER_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class BrowserRenderOracleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.source = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
        self.checker = load_checker()

    def test_manifest_owns_exact_full_raster_oracle(self) -> None:
        focused, expected, effective = oracle_runner.focused_manifest(self.source, "exact")
        self.assertEqual(focused["schemaVersion"], 7)
        self.assertEqual(expected, effective)
        oracle = focused["rows"][0]["browserWorkload"]["renderOutputOracle"]
        payload = bytearray(oracle["bytesPerRow"] * oracle["height"])
        rect = oracle["rect"]
        for y in range(oracle["height"]):
            for x in range(oracle["width"]):
                inside = (
                    rect["x"] <= x < rect["x"] + rect["width"]
                    and rect["y"] <= y < rect["y"] + rect["height"]
                )
                rgba = oracle["insideRgba"] if inside else oracle["outsideRgba"]
                offset = y * oracle["bytesPerRow"] + x * 4
                payload[offset : offset + 4] = bytes(rgba)
        self.assertEqual(hashlib.sha256(payload).hexdigest(), expected)

    def test_corruption_changes_only_effective_oracle_identity(self) -> None:
        exact, expected, _ = oracle_runner.focused_manifest(self.source, "exact")
        corrupt, corrupt_expected, effective = oracle_runner.focused_manifest(
            self.source, "corrupt"
        )
        self.assertEqual(corrupt_expected, expected)
        self.assertNotEqual(effective, expected)
        self.assertNotEqual(
            corrupt["projectionContractHash"], exact["projectionContractHash"]
        )
        corrupt_oracle = corrupt["rows"][0]["browserWorkload"]["renderOutputOracle"]
        exact_oracle = exact["rows"][0]["browserWorkload"]["renderOutputOracle"]
        corrupt_oracle["expectedSha256"] = exact_oracle["expectedSha256"]
        self.assertEqual(corrupt_oracle, exact_oracle)

    def test_runtime_verdict_requires_exact_success_or_explicit_rejection(self) -> None:
        _, expected, _ = oracle_runner.focused_manifest(self.source, "exact")
        byte_length = 16384
        base = {
            "mode": "dawn",
            "activeRuntimeMatched": True,
            "status": "ok",
            "statusCode": "ok",
            "error": "",
            "expectedRasterSha256": expected,
            "computedExpectedRasterSha256": expected,
            "actualRasterSha256": expected,
            "rasterByteLength": byte_length,
            "rasterMismatchCount": 0,
            "firstRasterMismatchOffset": -1,
            "oraclePassed": True,
        }
        self.assertTrue(
            oracle_runner.expected_runtime_result(
                base, "dawn", expected, expected, byte_length
            )
        )

        effective = oracle_runner.corrupted_sha256(expected)
        rejected = {
            **base,
            "status": "fail",
            "statusCode": "scenario_runtime_error",
            "error": "full-raster render oracle failed",
            "expectedRasterSha256": effective,
            "oraclePassed": False,
        }
        self.assertTrue(
            oracle_runner.expected_runtime_result(
                rejected, "dawn", expected, effective, byte_length
            )
        )
        rejected["actualRasterSha256"] = effective
        self.assertFalse(
            oracle_runner.expected_runtime_result(
                rejected, "dawn", expected, effective, byte_length
            )
        )

    def test_checker_requires_full_raster_identity_and_cross_runtime_parity(self) -> None:
        focused, expected, _ = oracle_runner.focused_manifest(self.source, "exact")
        manifest_row = focused["rows"][0]
        oracle = manifest_row["browserWorkload"]["renderOutputOracle"]
        metrics = {
            "viewport": oracle["rect"],
            "rasterOracle": oracle["kind"],
            "rasterReferenceId": oracle["referenceId"],
            "rasterByteLength": oracle["bytesPerRow"] * oracle["height"],
            "expectedRasterSha256": expected,
            "computedExpectedRasterSha256": expected,
            "actualRasterSha256": expected,
            "rasterMismatchCount": 0,
            "firstRasterMismatchOffset": -1,
            "pass": True,
            "createRenderTargetMs": 0.0,
            "shaderModuleMs": 0.0,
            "renderPipelineMs": 0.0,
            "createViewMs": 0.0,
            "submitReadbackMs": 0.0,
            "mapReadMs": 0.0,
            "destroyMs": 0.0,
            "renderMs": 0.0,
            "oracleValidationMs": 0.0,
        }
        mode_result = {"status": "ok", "metrics": metrics}
        self.assertEqual(
            self.checker.check_render_runtime_evidence(
                mode_result, manifest_row, "L1:render", "dawn"
            ),
            [],
        )
        report_row = {
            "runtimes": {
                "dawn": mode_result,
                "doe": {"status": "ok", "metrics": dict(metrics)},
            }
        }
        self.assertEqual(
            self.checker.check_render_cross_runtime_parity(
                report_row, manifest_row, "L1:render"
            ),
            [],
        )
        report_row["runtimes"]["doe"]["metrics"]["actualRasterSha256"] = "0" * 64
        self.assertTrue(
            self.checker.check_render_cross_runtime_parity(
                report_row, manifest_row, "L1:render"
            )
        )


if __name__ == "__main__":
    unittest.main()
