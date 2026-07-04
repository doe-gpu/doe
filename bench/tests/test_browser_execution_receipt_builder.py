#!/usr/bin/env python3
"""Tests for browser execution receipt building."""

from __future__ import annotations

import hashlib
import json
import unittest
from pathlib import Path

import jsonschema

from bench.tools import build_browser_execution_receipt as builder
from bench.tools import check_browser_published_proof_surface as proof_check


REPO_ROOT = Path(__file__).resolve().parents[2]
SMOKE_REPORT = REPO_ROOT / "examples" / "browser-smoke-report.sample.json"
SCHEMA = REPO_ROOT / "config" / "browser-execution-receipt.schema.json"
OUTPUT_HASH = "d" * 64
SOURCE_TEXT = "@compute @workgroup_size(1) fn main() {}"
SOURCE_HASH = hashlib.sha256(SOURCE_TEXT.encode("utf-8")).hexdigest()


def _smoke_report() -> dict:
    return json.loads(SMOKE_REPORT.read_text(encoding="utf-8"))


def _receipt(mode: str, smoke_report: dict | None = None) -> dict:
    return builder.build_receipt(
        smoke_report_path=SMOKE_REPORT,
        smoke_report=_smoke_report() if smoke_report is None else smoke_report,
        mode=mode,
        receipt_id=f"browser-smoke-compute-{mode}",
        workload_id="browser-smoke-compute",
        source_shader={
            "language": "wgsl",
            "entryPoint": "main",
            "source": SOURCE_TEXT,
            "sha256": SOURCE_HASH,
        },
        command_count=1,
        success_count=1,
        dispatch_count=1,
        output_hash=OUTPUT_HASH,
        frame_hash=None,
        timing_phases={
            "setupNs": 1000,
            "encodeNs": 2000,
            "submitWaitNs": 3000,
        },
    )


class BrowserExecutionReceiptBuilderTests(unittest.TestCase):
    def test_build_receipt_from_doe_smoke_result(self) -> None:
        receipt = _receipt("doe")

        jsonschema.validate(receipt, json.loads(SCHEMA.read_text(encoding="utf-8")))
        self.assertEqual(receipt["selectedRuntime"], "doe")
        self.assertEqual(receipt["loweringPath"], ["wgsl", "doe-wgsl", "tsir", "hostplan", "webgpu"])
        self.assertEqual(receipt["runtimeSelectorState"]["selectedRuntime"], "doe")
        self.assertEqual(receipt["commandCoverage"]["dispatchCount"], 1)
        self.assertEqual(receipt["driver"]["vendor"], "sample")
        self.assertEqual(receipt["driver"]["api"], "webgpu")
        self.assertEqual(receipt["driver"]["driver"], "sample-driver")
        self.assertEqual(receipt["device"]["adapter"], "sample-adapter")
        self.assertEqual(receipt["device"]["featureCount"], 1)
        self.assertEqual(
            proof_check.check_execution_receipt_payload(
                receipt,
                "browser-smoke-compute-doe",
                "browser-smoke-compute-doe",
                None,
            ),
            [],
        )

    def test_build_receipt_from_dawn_smoke_result(self) -> None:
        receipt = _receipt("dawn")

        jsonschema.validate(receipt, json.loads(SCHEMA.read_text(encoding="utf-8")))
        self.assertEqual(receipt["selectedRuntime"], "dawn")
        self.assertEqual(receipt["loweringPath"], ["wgsl", "tint", "dawn-native"])
        self.assertEqual(receipt["runtimeSelectorState"]["selectedRuntime"], "dawn")

    def test_source_shader_payload_hashes_source_text(self) -> None:
        payload = builder.source_shader_payload(
            language="wgsl",
            entry_point="main",
            source="@compute @workgroup_size(1) fn main() {}",
            source_hash=None,
        )

        self.assertEqual(
            payload["sha256"],
            SOURCE_HASH,
        )
        self.assertIn("source", payload)

    def test_source_shader_payload_rejects_hash_only_identity(self) -> None:
        with self.assertRaisesRegex(ValueError, "source text"):
            builder.source_shader_payload(
                language="wgsl",
                entry_point="main",
                source=None,
                source_hash=SOURCE_HASH,
            )

    def test_source_shader_payload_rejects_hash_drift(self) -> None:
        with self.assertRaisesRegex(ValueError, "must match"):
            builder.source_shader_payload(
                language="wgsl",
                entry_point="main",
                source=SOURCE_TEXT,
                source_hash="0" * 64,
            )

    def test_build_receipt_rejects_hidden_fallback(self) -> None:
        report = _smoke_report()
        report["modeResults"][1]["runtimeSelection"]["hiddenFallbackAllowed"] = True

        with self.assertRaisesRegex(ValueError, "hiddenFallbackAllowed"):
            _receipt("doe", smoke_report=report)

    def test_build_receipt_rejects_runtime_drift(self) -> None:
        report = _smoke_report()
        report["modeResults"][1]["runtimeSelection"]["selectedRuntime"] = "dawn"

        with self.assertRaisesRegex(ValueError, "selectedRuntime"):
            _receipt("doe", smoke_report=report)

    def test_build_receipt_rejects_incomplete_command_coverage(self) -> None:
        with self.assertRaisesRegex(ValueError, "success-count"):
            builder.build_receipt(
                smoke_report_path=SMOKE_REPORT,
                smoke_report=_smoke_report(),
                mode="doe",
                receipt_id="browser-smoke-compute-doe",
                workload_id="browser-smoke-compute",
                source_shader={
                    "language": "wgsl",
                    "entryPoint": "main",
                    "source": SOURCE_TEXT,
                    "sha256": SOURCE_HASH,
                },
                command_count=1,
                success_count=2,
                dispatch_count=1,
                output_hash=OUTPUT_HASH,
                frame_hash=None,
                timing_phases={
                    "setupNs": 1000,
                    "encodeNs": 2000,
                    "submitWaitNs": 3000,
                },
            )

    def test_build_receipt_rejects_unknown_driver_identity(self) -> None:
        report = _smoke_report()
        report["modeResults"][1]["runtimeSelection"]["profile"]["driver"] = "unknown"

        with self.assertRaisesRegex(ValueError, "profile.driver"):
            _receipt("doe", smoke_report=report)

    def test_schema_rejects_placeholder_driver_identity(self) -> None:
        receipt = _receipt("doe")
        receipt["driver"]["api"] = "unknown"

        with self.assertRaises(jsonschema.ValidationError):
            jsonschema.validate(receipt, json.loads(SCHEMA.read_text(encoding="utf-8")))

    def test_proof_checker_rejects_incomplete_device_identity(self) -> None:
        receipt = _receipt("doe")
        del receipt["device"]["adapterInfoSha256"]

        failures = proof_check.check_execution_receipt_payload(
            receipt,
            "browser-smoke-compute-doe",
            "browser-smoke-compute-doe",
            "doe",
        )

        self.assertIn(
            {
                "code": "invalid_receipt_device_identity",
                "path": "browser-smoke-compute-doe.device.adapterInfoSha256",
                "message": "receipt payload device.adapterInfoSha256 must be lowercase SHA-256",
            },
            failures,
        )

    def test_build_receipt_rejects_missing_device_label(self) -> None:
        report = _smoke_report()
        adapter_identity = report["modeResults"][1]["adapterIdentity"]
        adapter_identity.pop("adapter", None)
        adapter_identity.pop("device", None)
        adapter_identity.pop("name", None)

        with self.assertRaisesRegex(ValueError, "adapterIdentity"):
            _receipt("doe", smoke_report=report)


if __name__ == "__main__":
    unittest.main()
