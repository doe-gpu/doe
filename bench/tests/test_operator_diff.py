#!/usr/bin/env python3
"""Regression tests for operator manifest diff summaries."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_DIR = REPO_ROOT / "bench"
sys.path.insert(0, str(BENCH_DIR))

from native_compare_modules import operator_diff


class OperatorDiffTests(unittest.TestCase):
    def write_manifest(self, root: Path, name: str, payload: list[dict]) -> Path:
        path = root / name
        path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        return path

    def build_sample(self, manifest_path: Path) -> dict:
        return {
            "returnCode": 0,
            "traceMetaPath": str(manifest_path.with_suffix(".meta.json")),
            "traceMeta": {
                "module": "doe-zig-runtime",
                "operatorRecordManifestPath": str(manifest_path),
            },
        }

    def test_operator_diff_reports_structural_match(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fawn-operator-diff-") as tmpdir:
            root = Path(tmpdir)
            payload = [
                {
                    "schemaVersion": 1,
                    "sourceIndex": 0,
                    "command": "kernel_dispatch",
                    "semanticOpId": "layer.0.attn.softmax",
                    "trace": {},
                    "profile": {"vendor": "a", "api": "vulkan", "driver": "1"},
                    "execution": {"status": "ok", "statusCode": "ok"},
                    "commandShape": {"dispatchGeometry": {"x": 1, "y": 1, "z": 1}},
                    "shaderArtifacts": {"pipelineHash": "p0"},
                    "repro": {
                        "commandsPath": "left.repro.commands.json",
                        "metaPath": "left.repro.meta.json",
                        "rerunMode": "structural_same_device_backend",
                        "bitwise": False,
                    },
                }
            ]
            left_manifest = self.write_manifest(root, "left.operators.json", payload)
            right_manifest = self.write_manifest(root, "right.operators.json", payload)

            summary = operator_diff.summarize_workload_operator_diff(
                {"commandSamples": [self.build_sample(left_manifest)]},
                {"commandSamples": [self.build_sample(right_manifest)]},
            )

            self.assertEqual(summary["available"], True)
            self.assertEqual(summary["status"], "matched")
            self.assertEqual(summary["firstDivergence"]["found"], False)
            self.assertEqual(summary["firstDivergence"]["comparedOperatorCount"], 1)

    def test_operator_diff_reports_capture_digest_divergence(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fawn-operator-diff-") as tmpdir:
            root = Path(tmpdir)
            base = {
                "schemaVersion": 1,
                "sourceIndex": 0,
                "command": "kernel_dispatch",
                "semanticOpId": "layer.4.attn.softmax",
                "semanticStage": "softmax",
                "trace": {},
                "profile": {"vendor": "a", "api": "vulkan", "driver": "1"},
                "execution": {"status": "ok", "statusCode": "ok"},
                "commandShape": {"dispatchGeometry": {"x": 1, "y": 1, "z": 1}},
                "shaderArtifacts": {"pipelineHash": "p0"},
                "repro": {
                    "commandsPath": "repro.commands.json",
                    "metaPath": "repro.meta.json",
                    "rerunMode": "structural_same_device_backend",
                    "bitwise": False,
                },
            }
            left_manifest = self.write_manifest(
                root,
                "left.operators.json",
                [{**base, "capture": {"status": "ok", "sha256": "a" * 64, "path": "left.capture.bin"}}],
            )
            right_manifest = self.write_manifest(
                root,
                "right.operators.json",
                [{**base, "capture": {"status": "ok", "sha256": "b" * 64, "path": "right.capture.bin"}}],
            )

            summary = operator_diff.summarize_workload_operator_diff(
                {"commandSamples": [self.build_sample(left_manifest)]},
                {"commandSamples": [self.build_sample(right_manifest)]},
            )

            self.assertEqual(summary["available"], True)
            self.assertEqual(summary["status"], "diverged")
            self.assertEqual(summary["firstDivergence"]["type"], "capture_digest_mismatch")
            self.assertEqual(summary["firstDivergence"]["semanticOpId"], "layer.4.attn.softmax")

    def test_operator_diff_ignores_malformed_manifest(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fawn-operator-diff-") as tmpdir:
            root = Path(tmpdir)
            left_manifest = root / "left.operators.json"
            right_manifest = root / "right.operators.json"
            left_manifest.write_text("{not-json", encoding="utf-8")
            right_manifest.write_text("[]\n", encoding="utf-8")

            summary = operator_diff.summarize_workload_operator_diff(
                {"commandSamples": [self.build_sample(left_manifest)]},
                {"commandSamples": [self.build_sample(right_manifest)]},
            )

            self.assertEqual(summary["available"], False)
            self.assertEqual(summary["status"], "missing_operator_manifests")


if __name__ == "__main__":
    unittest.main(verbosity=2)
