#!/usr/bin/env python3
"""Tests for Tint benchmark-scope phase timing evidence receipts."""

from __future__ import annotations

import json
import unittest
from pathlib import Path

import jsonschema

from bench.tools import check_tint_phase_benchmark_evidence as phase_check


REPO_ROOT = Path(__file__).resolve().parents[2]
SCHEMA_PATH = REPO_ROOT / "config" / "tint-phase-benchmark-evidence.schema.json"
SAMPLE_PATH = REPO_ROOT / "examples" / "tint-phase-benchmark-evidence.sample.json"
TARGETS_PATH = REPO_ROOT / "config" / "schema-targets.json"


def _load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


class TintPhaseBenchmarkEvidenceTests(unittest.TestCase):
    def _evidence(self) -> dict:
        return {
            "artifactKind": "tint-compiler-evidence",
            "phaseModel": {
                "timingScope": "phase",
                "units": "ns",
                "requiredPhases": ["parse", "sema", "lower", "emit", "total"],
            },
            "rows": [
                {
                    "shaderId": "shader",
                    "target": "spirv",
                    "tint": {
                        "status": "ok",
                        "phaseTimingsNs": {"total": 100},
                        "phaseBenchmarkTimingsNs": {
                            "parseWgsl": 11,
                            "validateIr": 22,
                            "generateBackend": 33,
                        },
                    },
                }
            ],
        }

    def _report(self, evidence: dict, *targets: str) -> dict:
        return phase_check.build_report(
            evidence=evidence,
            evidence_path="bench/out/tint-compiler-evidence.json",
            required_targets=list(targets),
        )

    def test_phase_benchmark_evidence_passes_without_exact_tint_phases(self) -> None:
        report = self._report(self._evidence(), "spirv")

        self.assertEqual(report["status"], "pass")
        self.assertEqual(report["rows"][0]["phaseBenchmarkStatus"], "covered")
        self.assertEqual(report["rows"][0]["exactPhaseStatus"], "missing")
        self.assertEqual(
            report["rows"][0]["missingExactPhases"],
            ["parse", "sema", "lower", "emit"],
        )
        self.assertEqual(report["failures"], [])

    def test_phase_benchmark_evidence_fails_when_scope_is_missing(self) -> None:
        evidence = self._evidence()
        del evidence["rows"][0]["tint"]["phaseBenchmarkTimingsNs"]["validateIr"]
        report = self._report(evidence, "spirv")

        self.assertEqual(report["status"], "fail")
        self.assertEqual(report["rows"][0]["phaseBenchmarkStatus"], "missing")
        self.assertIn("validateIr", report["rows"][0]["missingPhaseBenchmarkScopes"])
        self.assertTrue(
            any(item["code"] == "phase_benchmark_scope_missing" for item in report["failures"])
        )

    def test_phase_benchmark_evidence_ignores_non_ok_tint_rows(self) -> None:
        evidence = self._evidence()
        evidence["rows"][0]["tint"] = {
            "status": "failed",
            "phaseTimingsNs": {},
            "phaseBenchmarkTimingsNs": {},
        }
        report = self._report(evidence, "spirv")

        self.assertEqual(report["status"], "pass")
        self.assertEqual(report["rows"][0]["phaseBenchmarkStatus"], "not_applicable")
        self.assertEqual(report["summary"]["notApplicableRows"], 1)

    def test_phase_benchmark_evidence_reports_missing_required_target(self) -> None:
        report = self._report(self._evidence(), "msl")

        self.assertEqual(report["status"], "fail")
        self.assertIn(
            {
                "code": "missing_required_target",
                "path": "requiredTargets.msl",
                "message": "no compiler evidence rows found for target msl",
            },
            report["failures"],
        )

    def test_phase_benchmark_evidence_reports_exact_phase_completion(self) -> None:
        evidence = self._evidence()
        evidence["rows"][0]["tint"]["phaseTimingsNs"] = {
            "parse": 1,
            "sema": 2,
            "lower": 3,
            "emit": 4,
            "total": 10,
        }
        report = self._report(evidence, "spirv")

        self.assertEqual(report["status"], "pass")
        self.assertEqual(report["rows"][0]["exactPhaseStatus"], "complete")
        self.assertEqual(report["rows"][0]["missingExactPhases"], [])

    def test_sample_matches_schema_and_registry(self) -> None:
        jsonschema.Draft202012Validator(_load_json(SCHEMA_PATH)).validate(
            _load_json(SAMPLE_PATH)
        )
        registry = _load_json(TARGETS_PATH)
        self.assertIn(
            {
                "schema": "config/tint-phase-benchmark-evidence.schema.json",
                "data": "examples/tint-phase-benchmark-evidence.sample.json",
            },
            registry["targets"],
        )


if __name__ == "__main__":
    unittest.main()
