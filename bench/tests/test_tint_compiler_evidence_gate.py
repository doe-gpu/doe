#!/usr/bin/env python3
"""Tests for the Doe-vs-Tint compiler evidence gate."""

from __future__ import annotations

import importlib.util
import json
import sys
import unittest
from pathlib import Path

import jsonschema


REPO_ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = REPO_ROOT / "bench" / "gates" / "tint_compiler_evidence_gate.py"
SCHEMA_PATH = REPO_ROOT / "config" / "tint-compiler-evidence.schema.json"
SAMPLE_PATH = REPO_ROOT / "examples" / "tint-compiler-evidence.sample.json"

sys.path.insert(0, str(REPO_ROOT))


def load_module():
    spec = importlib.util.spec_from_file_location("tint_compiler_evidence_gate", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load tint_compiler_evidence_gate from {MODULE_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def side_payload(output_digit: str) -> dict:
    return {
        "status": "ok",
        "diagnosticCode": "",
        "diagnosticMessage": "",
        "outputSha256": output_digit * 64,
        "irSha256": "7" * 64,
        "outputPath": f"bench/out/scratch/{output_digit}.spv",
        "validationStatus": "passed",
        "validationTool": "validator",
        "validationMessage": "",
        "phaseTimingsNs": {
            "parse": 1,
            "sema": 1,
            "lower": 1,
            "emit": 1,
            "total": 4,
        },
        "phaseBenchmarkTimingsNs": {},
        "receiptPath": f"bench/out/scratch/{output_digit}.json",
    }


def claimable_report() -> dict:
    return {
        "schemaVersion": 1,
        "artifactKind": "tint-compiler-evidence",
        "generatedAt": "2026-05-25T00:00:00Z",
        "comparisonStatus": "comparable",
        "claimStatus": "claimable",
        "corpus": {
            "id": "unit",
            "source": "unit",
            "sourceSha256": "0" * 64,
            "manifestPath": "",
        },
        "toolchains": {
            "doe": {
                "name": "doe-wgsl",
                "version": "unit",
                "command": ["doe"],
                "sourceRevision": "unit",
                "artifactPath": "runtime/zig/zig-out/bin/doe-runtime-compile-report",
                "artifactSha256": "4" * 64,
            },
            "tint": {
                "name": "tint",
                "version": "unit",
                "command": ["tint"],
                "sourceRevision": "unit",
                "artifactPath": "bench/vendor/dawn/out/Release/tint",
                "artifactSha256": "5" * 64,
            },
            "tintWarm": {
                "name": "tint-benchmark",
                "version": "unit",
                "command": ["tint_benchmark"],
                "sourceRevision": "unit",
                "artifactPath": "bench/vendor/dawn/out/Release/tint_benchmark",
                "artifactSha256": "6" * 64,
            },
        },
        "phaseModel": {
            "timingScope": "phase",
            "units": "ns",
            "requiredPhases": ["parse", "sema", "lower", "emit", "total"],
        },
        "rows": [
            {
                "shaderId": "shader-a",
                "sourceSha256": "1" * 64,
                "sourcePath": "bench/fixtures/wgsl-corpus/webgpu/sample-prefix-sum.wgsl",
                "corpusCategory": "webgpu_sample",
                "expectedValidity": "valid",
                "expectedBackendTargets": ["spirv"],
                "target": "spirv",
                "shaderStage": "compute",
                "doe": side_payload("2"),
                "tint": side_payload("3"),
                "comparability": {
                    "status": "comparable",
                    "reasons": [],
                },
                "claimability": {
                    "status": "claimable",
                    "reasons": [],
                    "deltaPercent": {
                        "p50": 12.5,
                        "p95": 8.0,
                        "p99": 4.0,
                    },
                },
            }
        ],
        "summary": {
            "rowCount": 1,
            "comparableRows": 1,
            "claimableRows": 1,
            "reasons": [],
        },
    }


def diagnostic_report_with_tint_total_only_phases() -> dict:
    payload = claimable_report()
    payload["comparisonStatus"] = "diagnostic"
    payload["claimStatus"] = "diagnostic"
    row = payload["rows"][0]
    row["tint"]["phaseTimingsNs"] = {"total": 4}
    row["comparability"] = {
        "status": "diagnostic",
        "reasons": ["tint_missing_named_phase_timings"],
    }
    row["claimability"] = {
        "status": "diagnostic",
        "reasons": ["tint_missing_named_phase_timings"],
        "deltaPercent": {},
    }
    payload["summary"] = {
        "rowCount": 1,
        "comparableRows": 0,
        "claimableRows": 0,
        "reasons": ["tint_missing_named_phase_timings"],
    }
    return payload


def comparable_diagnostic_report_with_tint_total_only_phases() -> dict:
    payload = diagnostic_report_with_tint_total_only_phases()
    payload["comparisonStatus"] = "comparable"
    row = payload["rows"][0]
    row["comparability"] = {
        "status": "comparable",
        "reasons": [],
    }
    row["claimability"] = {
        "status": "diagnostic",
        "reasons": ["tint missing phase timing: parse"],
        "deltaPercent": {},
    }
    payload["summary"] = {
        "rowCount": 1,
        "comparableRows": 1,
        "claimableRows": 0,
        "reasons": ["tint missing phase timing: parse"],
    }
    return payload


class TintCompilerEvidenceGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = load_module()
        cls.schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))

    def test_sample_report_is_schema_valid_and_diagnostic(self) -> None:
        payload = json.loads(SAMPLE_PATH.read_text(encoding="utf-8"))
        jsonschema.Draft202012Validator(self.schema).validate(payload)
        result = self.module.evaluate_report(payload)
        self.assertTrue(result["ok"])
        self.assertEqual(result["summary"]["claimStatus"], "diagnostic")
        self.assertEqual(result["summary"]["comparableRows"], 0)

    def test_claimable_report_passes(self) -> None:
        payload = claimable_report()
        jsonschema.Draft202012Validator(self.schema).validate(payload)
        result = self.module.evaluate_report(payload, require_claimable=True)
        self.assertTrue(result["ok"], result["failures"])
        self.assertEqual(result["summary"]["claimableRows"], 1)

    def test_zero_row_diagnostic_report_passes(self) -> None:
        payload = claimable_report()
        payload["comparisonStatus"] = "diagnostic"
        payload["claimStatus"] = "diagnostic"
        payload["rows"] = []
        payload["summary"] = {
            "rowCount": 0,
            "comparableRows": 0,
            "claimableRows": 0,
            "reasons": [
                "missing_tint_benchmark_input_script: bench/vendor/dawn/src/tint/cmd/bench/generate_benchmark_inputs.py"
            ],
        }
        jsonschema.Draft202012Validator(self.schema).validate(payload)
        result = self.module.evaluate_report(payload)
        self.assertTrue(result["ok"], result["failures"])
        self.assertEqual(result["summary"]["claimStatus"], "diagnostic")

    def test_zero_row_claimable_report_fails(self) -> None:
        payload = claimable_report()
        payload["rows"] = []
        payload["summary"] = {
            "rowCount": 0,
            "comparableRows": 0,
            "claimableRows": 0,
            "reasons": [],
        }
        result = self.module.evaluate_report(payload, require_claimable=True)
        self.assertFalse(result["ok"])
        self.assertTrue(any("requires at least one row" in item for item in result["failures"]))

    def test_diagnostic_report_allows_claim_blockers_without_claim_requirement(self) -> None:
        payload = diagnostic_report_with_tint_total_only_phases()
        jsonschema.Draft202012Validator(self.schema).validate(payload)

        result = self.module.evaluate_report(payload)

        self.assertTrue(result["ok"], result["failures"])
        self.assertEqual(result["summary"]["comparableRows"], 0)
        self.assertEqual(result["summary"]["claimableRows"], 0)
        self.assertTrue(
            any("tint: missing integer phase timing: parse" in item for item in result["claimBlockers"])
        )

    def test_comparable_diagnostic_report_allows_claim_blockers_without_claim_requirement(self) -> None:
        payload = comparable_diagnostic_report_with_tint_total_only_phases()
        jsonschema.Draft202012Validator(self.schema).validate(payload)

        result = self.module.evaluate_report(payload)

        self.assertTrue(result["ok"], result["failures"])
        self.assertEqual(result["summary"]["comparisonStatus"], "comparable")
        self.assertEqual(result["summary"]["comparableRows"], 1)
        self.assertEqual(result["summary"]["claimableRows"], 0)
        self.assertTrue(
            any("tint: missing integer phase timing: parse" in item for item in result["claimBlockers"])
        )

    def test_diagnostic_report_claim_blockers_fail_when_claimable_required(self) -> None:
        payload = diagnostic_report_with_tint_total_only_phases()

        result = self.module.evaluate_report(payload, require_claimable=True)

        self.assertFalse(result["ok"])
        self.assertTrue(
            any("tint: missing integer phase timing: parse" in item for item in result["failures"])
        )
        self.assertTrue(
            any("--require-claimable requires comparisonStatus=comparable" in item for item in result["failures"])
        )

    def test_comparable_diagnostic_report_claim_blockers_fail_when_claimable_required(self) -> None:
        payload = comparable_diagnostic_report_with_tint_total_only_phases()

        result = self.module.evaluate_report(payload, require_claimable=True)

        self.assertFalse(result["ok"])
        self.assertTrue(
            any("tint: missing integer phase timing: parse" in item for item in result["failures"])
        )
        self.assertTrue(
            any("--require-claimable requires claimStatus=claimable" in item for item in result["failures"])
        )

    def test_claimable_report_rejects_missing_tint_validation(self) -> None:
        payload = claimable_report()
        payload["rows"][0]["tint"]["validationStatus"] = "not_run"
        result = self.module.evaluate_report(payload, require_claimable=True)
        self.assertFalse(result["ok"])
        self.assertTrue(
            any("tint: ok result requires validationStatus=passed" in item for item in result["failures"])
        )

    def test_comparable_row_rejects_diagnostic_reasons(self) -> None:
        payload = claimable_report()
        payload["rows"][0]["comparability"]["reasons"] = ["stale timing scope"]
        result = self.module.evaluate_report(payload, require_claimable=True)
        self.assertFalse(result["ok"])
        self.assertTrue(
            any("comparable row must not carry comparability reasons" in item for item in result["failures"])
        )

    def test_claimable_row_rejects_diagnostic_reasons(self) -> None:
        payload = claimable_report()
        payload["rows"][0]["claimability"]["reasons"] = ["missing warm tint samples"]
        result = self.module.evaluate_report(payload, require_claimable=True)
        self.assertFalse(result["ok"])
        self.assertTrue(
            any("claimable row must not carry claimability reasons" in item for item in result["failures"])
        )

    def test_summary_counts_must_match_rows(self) -> None:
        payload = claimable_report()
        payload["summary"]["claimableRows"] = 0
        result = self.module.evaluate_report(payload, require_claimable=True)
        self.assertFalse(result["ok"])
        self.assertTrue(any("summary.claimableRows must be 1" in item for item in result["failures"]))

    def test_claimable_report_requires_compiler_artifact_hashes(self) -> None:
        payload = claimable_report()
        payload["toolchains"]["doe"]["artifactSha256"] = None
        result = self.module.evaluate_report(payload, require_claimable=True)
        self.assertFalse(result["ok"])
        self.assertTrue(
            any("toolchains.doe.artifactSha256 must be sha256 hex" in item for item in result["failures"])
        )

    def test_claimable_report_requires_tint_warm_artifact_hash(self) -> None:
        payload = claimable_report()
        payload["toolchains"]["tintWarm"]["artifactPath"] = ""
        payload["toolchains"]["tintWarm"]["artifactSha256"] = None
        result = self.module.evaluate_report(payload, require_claimable=True)
        self.assertFalse(result["ok"])
        self.assertTrue(
            any("toolchains.tintWarm.artifactSha256 must be sha256 hex" in item for item in result["failures"])
        )

    def test_claimable_row_requires_corpus_linkage(self) -> None:
        payload = claimable_report()
        payload["rows"][0].pop("sourcePath")
        result = self.module.evaluate_report(payload, require_claimable=True)
        self.assertFalse(result["ok"])
        self.assertTrue(any("claimable row requires sourcePath" in item for item in result["failures"]))

    def test_claimable_row_requires_doe_ir_hash(self) -> None:
        payload = claimable_report()
        payload["rows"][0]["doe"]["irSha256"] = None
        result = self.module.evaluate_report(payload, require_claimable=True)
        self.assertFalse(result["ok"])
        self.assertTrue(any("claimable row requires doe.irSha256" in item for item in result["failures"]))

    def test_claimable_row_rejects_unsafe_source_path(self) -> None:
        payload = claimable_report()
        payload["rows"][0]["sourcePath"] = "../outside.wgsl"

        result = self.module.evaluate_report(payload, require_claimable=True)

        self.assertFalse(result["ok"])
        self.assertTrue(any("shader-a.sourcePath" in item for item in result["failures"]))

    def test_claimable_row_rejects_unsafe_receipt_path(self) -> None:
        payload = claimable_report()
        payload["rows"][0]["doe"]["receiptPath"] = "/tmp/doe.json"

        result = self.module.evaluate_report(payload, require_claimable=True)

        self.assertFalse(result["ok"])
        self.assertTrue(any("shader-a:doe.receiptPath" in item for item in result["failures"]))

    def test_claimable_report_rejects_unsafe_toolchain_artifact_path(self) -> None:
        payload = claimable_report()
        payload["toolchains"]["tint"]["artifactPath"] = "bench/vendor/../tint"

        result = self.module.evaluate_report(payload, require_claimable=True)

        self.assertFalse(result["ok"])
        self.assertTrue(any("toolchains.tint.artifactPath" in item for item in result["failures"]))

    def test_report_rejects_unsafe_corpus_manifest_path(self) -> None:
        payload = claimable_report()
        payload["corpus"]["manifestPath"] = "bench//manifest.json"

        result = self.module.evaluate_report(payload)

        self.assertFalse(result["ok"])
        self.assertTrue(any("corpus.manifestPath" in item for item in result["failures"]))

    def test_claimable_report_requires_phase_split_model(self) -> None:
        payload = claimable_report()
        payload["phaseModel"]["requiredPhases"] = ["total"]
        payload["rows"][0]["doe"]["phaseTimingsNs"] = {"total": 4}
        payload["rows"][0]["tint"]["phaseTimingsNs"] = {"total": 4}

        result = self.module.evaluate_report(payload, require_claimable=True)

        self.assertFalse(result["ok"])
        self.assertTrue(
            any("requires phaseModel.requiredPhases" in item for item in result["failures"])
        )


if __name__ == "__main__":
    unittest.main()
