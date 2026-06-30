#!/usr/bin/env python3
"""Tests for composed Doe-vs-Tint compiler frontier bundle receipts."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import jsonschema

from bench.tools import check_tint_compiler_frontier_bundle as bundle


REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = REPO_ROOT / "config" / "tint-compiler-frontier-bundle.schema.json"
SAMPLE_PATH = REPO_ROOT / "examples" / "tint-compiler-frontier-bundle.sample.json"
TARGETS_PATH = REPO_ROOT / "config" / "schema-targets.json"
COMPILER_SCHEMA_PATH = REPO_ROOT / "config" / "tint-compiler-evidence.schema.json"


def _load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


class TintCompilerFrontierBundleTests(unittest.TestCase):
    def _compiler_evidence(self) -> dict:
        return {
            "schemaVersion": 1,
            "artifactKind": "tint-compiler-evidence",
            "generatedAt": "2026-06-30T00:00:00Z",
            "comparisonStatus": "diagnostic",
            "claimStatus": "diagnostic",
            "corpus": {
                "id": "test",
                "source": "test",
                "sourceSha256": "0" * 64,
                "manifestPath": "manifest.json",
            },
            "toolchains": {
                "doe": {
                    "name": "doe",
                    "version": "test",
                    "command": ["doe"],
                    "sourceRevision": "test",
                },
                "tint": {
                    "name": "tint",
                    "version": "test",
                    "command": ["tint"],
                    "sourceRevision": "test",
                },
            },
            "phaseModel": {
                "timingScope": "phase",
                "units": "ns",
                "requiredPhases": ["parse", "sema", "lower", "emit", "total"],
            },
            "rows": [
                {
                    "shaderId": "shader",
                    "sourceSha256": "1" * 64,
                    "sourcePath": "shader.wgsl",
                    "corpusCategory": "webgpu_sample",
                    "expectedValidity": "valid",
                    "expectedBackendTargets": ["spirv"],
                    "target": "spirv",
                    "shaderStage": "compute",
                    "doe": {
                        "status": "ok",
                        "diagnosticCode": "",
                        "diagnosticMessage": "",
                        "outputSha256": "2" * 64,
                        "irSha256": "3" * 64,
                        "outputPath": "doe.spv",
                        "validationStatus": "passed",
                        "validationTool": "spirv-val",
                        "validationMessage": "",
                        "phaseTimingsNs": {
                            "parse": 1,
                            "sema": 1,
                            "lower": 1,
                            "emit": 1,
                            "total": 4,
                        },
                        "phaseBenchmarkTimingsNs": {},
                        "receiptPath": "doe.json",
                    },
                    "tint": {
                        "status": "ok",
                        "diagnosticCode": "",
                        "diagnosticMessage": "",
                        "outputSha256": "4" * 64,
                        "irSha256": None,
                        "outputPath": "tint.spv",
                        "validationStatus": "passed",
                        "validationTool": "spirv-val",
                        "validationMessage": "",
                        "phaseTimingsNs": {"total": 10},
                        "phaseBenchmarkTimingsNs": {
                            "parseWgsl": 10,
                            "validateIr": 20,
                            "generateBackend": 30,
                        },
                        "receiptPath": "tint.spv",
                    },
                    "comparability": {
                        "status": "diagnostic",
                        "reasons": ["exact Tint phase timings missing"],
                    },
                    "claimability": {
                        "status": "diagnostic",
                        "reasons": ["exact Tint phase timings missing"],
                        "deltaPercent": {"p50": None},
                    },
                }
            ],
            "summary": {
                "rowCount": 1,
                "comparableRows": 0,
                "claimableRows": 0,
                "reasons": ["exact Tint phase timings missing"],
            },
        }

    def _lowering_link(self) -> dict:
        return {
            "schemaVersion": 1,
            "artifactKind": "wgsl_lowering_link_receipt",
            "evidencePath": "evidence.json",
            "manifestPath": "manifest.json",
            "corpusId": "test",
            "rows": [
                {
                    "shaderId": "shader",
                    "manifestShaderId": "shader",
                    "sourcePath": "shader.wgsl",
                    "sourceSha256": "1" * 64,
                    "expectedValidity": "valid",
                    "shaderStage": "compute",
                    "backendTarget": "spirv",
                    "doeIrSha256": "3" * 64,
                    "doeBackendOutputSha256": "2" * 64,
                    "doeReceiptPath": "doe.json",
                    "doeValidationStatus": "passed",
                    "tintBackendOutputSha256": "4" * 64,
                    "tintReceiptPath": "tint.spv",
                    "tintValidationStatus": "passed",
                    "validationStatus": "passed",
                    "comparabilityStatus": "diagnostic",
                    "claimabilityStatus": "diagnostic",
                    "linkStatus": "linked",
                    "failureCodes": [],
                }
            ],
            "summary": {
                "rowCount": 1,
                "linkedRows": 1,
                "diagnosticRows": 0,
                "failureCodes": [],
            },
        }

    def _target_validation(self) -> dict:
        return {
            "schemaVersion": 1,
            "artifactKind": "tint_compiler_target_validation",
            "evidencePath": "evidence.json",
            "evidencePaths": ["evidence.json"],
            "requiredTargets": ["spirv"],
            "status": "pass",
            "targetCoverage": [
                {
                    "target": "spirv",
                    "evidencePaths": ["evidence.json"],
                    "rowCount": 1,
                    "validatedRows": 1,
                    "diagnosticRows": 0,
                    "shaderIds": ["shader"],
                }
            ],
            "claimBlockers": [],
            "claimBlockerSummary": [],
            "claimBlockerSummaryByEvidencePath": [
                {
                    "evidencePath": "evidence.json",
                    "claimBlockerSummary": [],
                }
            ],
            "failures": [],
            "summary": {
                "targetCount": 1,
                "coveredTargetCount": 1,
                "rowCount": 1,
                "validatedRows": 1,
                "diagnosticRows": 0,
                "claimBlockerCount": 0,
                "failureCount": 0,
            },
        }

    def _phase_benchmark(self) -> dict:
        return {
            "schemaVersion": 1,
            "artifactKind": "tint_phase_benchmark_evidence",
            "evidencePath": "evidence.json",
            "requiredTargets": ["spirv"],
            "requiredBenchmarkScopes": ["parseWgsl", "validateIr", "generateBackend"],
            "requiredExactPhases": ["parse", "sema", "lower", "emit"],
            "status": "pass",
            "targetCoverage": [
                {
                    "target": "spirv",
                    "rowCount": 1,
                    "tintOkRows": 1,
                    "phaseBenchmarkCoveredRows": 1,
                    "shaderIds": ["shader"],
                }
            ],
            "rows": [
                {
                    "shaderId": "shader",
                    "target": "spirv",
                    "tintStatus": "ok",
                    "phaseBenchmarkStatus": "covered",
                    "exactPhaseStatus": "missing",
                    "phaseBenchmarkTimingsNs": {
                        "parseWgsl": 10,
                        "validateIr": 20,
                        "generateBackend": 30,
                    },
                    "missingPhaseBenchmarkScopes": [],
                    "missingExactPhases": ["parse", "sema", "lower", "emit"],
                }
            ],
            "failures": [],
            "summary": {
                "targetCount": 1,
                "coveredTargetCount": 1,
                "rowCount": 1,
                "tintOkRows": 1,
                "phaseBenchmarkCoveredRows": 1,
                "phaseBenchmarkMissingRows": 0,
                "exactPhaseCompleteRows": 0,
                "exactPhaseMissingRows": 1,
                "notApplicableRows": 0,
                "failureCount": 0,
            },
        }

    def _write_json(self, root: Path, rel: str, payload: dict) -> str:
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload) + "\n", encoding="utf-8")
        return rel

    def test_bundle_passes_component_receipts_while_claimability_is_blocked(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            compiler = self._compiler_evidence()
            lowering = self._lowering_link()
            target = self._target_validation()
            phase = self._phase_benchmark()
            compiler_path = self._write_json(root, "evidence.json", compiler)
            lowering_path = self._write_json(root, "lowering.json", lowering)
            target_path = self._write_json(root, "target.json", target)
            phase_path = self._write_json(root, "phase.json", phase)
            report = bundle.build_report(
                compiler_evidence_paths=[compiler_path],
                lowering_link_receipt_paths=[lowering_path],
                target_validation_paths=[target_path],
                phase_benchmark_paths=[phase_path],
                required_targets=["spirv"],
                schema=_load_json(COMPILER_SCHEMA_PATH),
                root=root,
            )

        self.assertEqual(report["status"], "pass")
        self.assertEqual(report["claimabilityStatus"], "blocked")
        self.assertEqual(report["summary"]["coveredTargetCount"], 1)
        self.assertTrue(report["claimBlockers"])
        self.assertIn(
            {
                "code": "claimable_tint_compiler_evidence_report",
                "message": "tint: missing integer phase timing: parse",
                "count": 1,
            },
            report["compilerEvidenceReports"][0]["claimBlockerSummary"],
        )

    def test_bundle_includes_target_validation_claim_blockers(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            compiler = self._compiler_evidence()
            lowering = self._lowering_link()
            target = self._target_validation()
            target["claimBlockers"] = [
                {
                    "code": "doe_result_not_ok",
                    "path": "evidence[bench/out/evidence.json].rows[1].doe.status",
                    "message": "Doe compiler result is not ok: doe_compile_failed",
                }
            ]
            target["claimBlockerSummary"] = [
                {
                    "code": "doe_result_not_ok",
                    "message": "Doe compiler result is not ok: doe_compile_failed",
                    "count": 1,
                }
            ]
            target["claimBlockerSummaryByEvidencePath"] = [
                {
                    "evidencePath": "evidence.json",
                    "claimBlockerSummary": [],
                },
                {
                    "evidencePath": "bench/out/evidence.json",
                    "claimBlockerSummary": [
                        {
                            "code": "doe_result_not_ok",
                            "message": "Doe compiler result is not ok: doe_compile_failed",
                            "count": 1,
                        }
                    ],
                },
            ]
            target["summary"]["claimBlockerCount"] = 1
            phase = self._phase_benchmark()
            compiler_path = self._write_json(root, "evidence.json", compiler)
            lowering_path = self._write_json(root, "lowering.json", lowering)
            target_path = self._write_json(root, "target.json", target)
            phase_path = self._write_json(root, "phase.json", phase)
            report = bundle.build_report(
                compiler_evidence_paths=[compiler_path],
                lowering_link_receipt_paths=[lowering_path],
                target_validation_paths=[target_path],
                phase_benchmark_paths=[phase_path],
                required_targets=["spirv"],
                schema=_load_json(COMPILER_SCHEMA_PATH),
                root=root,
            )

        self.assertEqual(report["status"], "pass")
        self.assertTrue(
            any(
                item["code"] == "shader_artifact_validation_for_target_backends"
                for item in report["claimBlockers"]
            )
        )
        self.assertEqual(
            report["componentReceipts"]["targetValidations"][0][
                "claimBlockerSummaryByEvidencePath"
            ],
            target["claimBlockerSummaryByEvidencePath"],
        )

    def test_bundle_fails_when_required_target_lacks_phase_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            compiler_path = self._write_json(root, "evidence.json", self._compiler_evidence())
            lowering_path = self._write_json(root, "lowering.json", self._lowering_link())
            target_path = self._write_json(root, "target.json", self._target_validation())
            report = bundle.build_report(
                compiler_evidence_paths=[compiler_path],
                lowering_link_receipt_paths=[lowering_path],
                target_validation_paths=[target_path],
                phase_benchmark_paths=[],
                required_targets=["spirv"],
                schema=_load_json(COMPILER_SCHEMA_PATH),
                root=root,
            )

        self.assertEqual(report["status"], "fail")
        self.assertTrue(
            any(
                item["code"] == "target_missing_phase_benchmark_receipt"
                for item in report["failures"]
            )
        )

    def test_bundle_fails_when_component_receipt_references_unlisted_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            phase = self._phase_benchmark()
            phase["evidencePath"] = "other-evidence.json"
            compiler_path = self._write_json(root, "evidence.json", self._compiler_evidence())
            lowering_path = self._write_json(root, "lowering.json", self._lowering_link())
            target_path = self._write_json(root, "target.json", self._target_validation())
            phase_path = self._write_json(root, "phase.json", phase)
            report = bundle.build_report(
                compiler_evidence_paths=[compiler_path],
                lowering_link_receipt_paths=[lowering_path],
                target_validation_paths=[target_path],
                phase_benchmark_paths=[phase_path],
                required_targets=["spirv"],
                schema=_load_json(COMPILER_SCHEMA_PATH),
                root=root,
            )

        self.assertEqual(report["status"], "fail")
        self.assertIn(
            {
                "code": "phaseBenchmark_unlisted_evidence_path",
                "path": "phaseBenchmarkReceipts[0].evidencePaths",
                "message": "phaseBenchmark receipt evidence path must be supplied via --compiler-evidence: other-evidence.json",
            },
            report["failures"],
        )

    def test_bundle_requires_explicit_compiler_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            lowering_path = self._write_json(root, "lowering.json", self._lowering_link())
            target_path = self._write_json(root, "target.json", self._target_validation())
            phase_path = self._write_json(root, "phase.json", self._phase_benchmark())
            report = bundle.build_report(
                compiler_evidence_paths=[],
                lowering_link_receipt_paths=[lowering_path],
                target_validation_paths=[target_path],
                phase_benchmark_paths=[phase_path],
                required_targets=["spirv"],
                schema=_load_json(COMPILER_SCHEMA_PATH),
                root=root,
            )

        self.assertEqual(report["status"], "fail")
        self.assertIn(
            {
                "code": "missing_compiler_evidence_report",
                "path": "compilerEvidence",
                "message": "at least one compiler evidence report is required",
            },
            report["failures"],
        )

    def test_bundle_fails_require_claimable_for_diagnostic_compiler_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            compiler_path = self._write_json(root, "evidence.json", self._compiler_evidence())
            lowering_path = self._write_json(root, "lowering.json", self._lowering_link())
            target_path = self._write_json(root, "target.json", self._target_validation())
            phase_path = self._write_json(root, "phase.json", self._phase_benchmark())
            report = bundle.build_report(
                compiler_evidence_paths=[compiler_path],
                lowering_link_receipt_paths=[lowering_path],
                target_validation_paths=[target_path],
                phase_benchmark_paths=[phase_path],
                required_targets=["spirv"],
                schema=_load_json(COMPILER_SCHEMA_PATH),
                root=root,
                require_claimable=True,
            )

        self.assertEqual(report["status"], "fail")
        self.assertEqual(report["claimabilityStatus"], "blocked")
        self.assertTrue(
            any(
                item["code"] == "claimable_tint_compiler_evidence_report"
                for item in report["failures"]
            )
        )

    def test_sample_matches_schema_and_registry(self) -> None:
        sample = _load_json(SAMPLE_PATH)
        jsonschema.Draft202012Validator(_load_json(SCHEMA_PATH)).validate(
            sample
        )
        self.assertEqual(sample["status"], "pass")
        self.assertEqual(sample["claimabilityStatus"], "blocked")
        self.assertEqual(sample["failures"], [])
        self.assertIn(
            "shader_artifact_validation_for_target_backends",
            {item["code"] for item in sample["claimBlockers"]},
        )
        self.assertTrue(sample["compilerEvidenceReports"][0]["claimBlockerSummary"])
        self.assertTrue(
            sample["componentReceipts"]["targetValidations"][0][
                "claimBlockerSummary"
            ]
        )
        self.assertTrue(
            sample["componentReceipts"]["targetValidations"][0][
                "claimBlockerSummaryByEvidencePath"
            ]
        )
        registry = _load_json(TARGETS_PATH)
        self.assertIn(
            {
                "schema": "config/tint-compiler-frontier-bundle.schema.json",
                "data": "examples/tint-compiler-frontier-bundle.sample.json",
            },
            registry["targets"],
        )


if __name__ == "__main__":
    unittest.main()
