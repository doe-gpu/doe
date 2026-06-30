#!/usr/bin/env python3
"""Tests for target-backend validation receipts from Tint compiler evidence."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from bench.tools import check_tint_compiler_target_validation as target_validation


class TintCompilerTargetValidationTests(unittest.TestCase):
    def _evidence(self, root: Path, prefix: str = "") -> dict:
        artifact_root = root / prefix if prefix else root
        doe_output = artifact_root / "artifacts" / "shader" / "doe" / "output.spv"
        tint_output = artifact_root / "artifacts" / "shader" / "tint" / "output.spv"
        doe_receipt = artifact_root / "artifacts" / "shader" / "doe" / "compile-report.json"
        tint_receipt = tint_output
        doe_output.parent.mkdir(parents=True)
        tint_output.parent.mkdir(parents=True)
        doe_output.write_bytes(b"\x03\x02\x23\x07doe")
        tint_output.write_bytes(b"\x03\x02\x23\x07tint")
        doe_receipt.write_text('{"kind":"runtime_compile_report"}\n', encoding="utf-8")

        def rel(path: Path) -> str:
            return path.relative_to(root).as_posix()

        return {
            "artifactKind": "tint-compiler-evidence",
            "rows": [
                {
                    "shaderId": "shader",
                    "target": "spirv",
                    "expectedBackendTargets": ["spirv"],
                    "expectedValidity": "valid",
                    "doe": {
                        "status": "ok",
                        "diagnosticCode": "",
                        "diagnosticMessage": "",
                        "outputSha256": target_validation.file_sha256(doe_output),
                        "outputPath": rel(doe_output),
                        "receiptPath": rel(doe_receipt),
                        "validationStatus": "passed",
                        "validationTool": "spirv-val",
                        "validationMessage": "",
                    },
                    "tint": {
                        "status": "ok",
                        "diagnosticCode": "",
                        "diagnosticMessage": "",
                        "outputSha256": target_validation.file_sha256(tint_output),
                        "outputPath": rel(tint_output),
                        "receiptPath": rel(tint_receipt),
                        "validationStatus": "passed",
                        "validationTool": "spirv-val",
                        "validationMessage": "",
                    },
                }
            ],
        }

    def _report(self, evidence: dict, root: Path, *targets: str) -> dict:
        return target_validation.build_report(
            evidence=evidence,
            evidence_path="bench/out/tint-compiler-evidence.json",
            required_targets=list(targets),
            verify_files_root=root,
        )

    def _report_multi(
        self,
        evidence_reports: list[tuple[str, dict]],
        root: Path,
        *targets: str,
        allow_diagnostic_rows: bool = False,
    ) -> dict:
        return target_validation.build_report(
            evidence_reports=evidence_reports,
            required_targets=list(targets),
            verify_files_root=root,
            allow_diagnostic_rows=allow_diagnostic_rows,
        )

    def test_target_validation_passes_with_verified_backend_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            report = self._report(self._evidence(root), root, "spirv")

        self.assertEqual(report["status"], "pass")
        self.assertEqual(report["summary"]["validatedRows"], 1)
        self.assertEqual(report["summary"]["diagnosticRows"], 0)
        self.assertEqual(report["summary"]["claimBlockerCount"], 0)
        self.assertEqual(report["failures"], [])

    def test_target_validation_reports_missing_required_target(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            report = self._report(self._evidence(root), root, "msl")

        self.assertEqual(report["status"], "fail")
        self.assertIn(
            {
                "code": "missing_required_target",
                "path": "requiredTargets.msl",
                "message": "no compiler evidence rows found for target msl",
            },
            report["failures"],
        )

    def test_target_validation_reports_output_hash_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            evidence = self._evidence(root)
            evidence["rows"][0]["doe"]["outputSha256"] = "0" * 64
            report = self._report(evidence, root, "spirv")

        self.assertEqual(report["status"], "fail")
        self.assertTrue(
            any(item["code"] == "doe_output_hash_mismatch" for item in report["failures"])
        )

    def test_target_validation_verifies_output_artifacts(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            evidence = self._evidence(root)
            artifact_dir = root / "artifacts" / "shader" / "tint"
            vertex_output = artifact_dir / "output.vs_main.spv"
            fragment_output = artifact_dir / "output.fs_main.spv"
            vertex_output.write_bytes(b"\x03\x02\x23\x07vertex")
            fragment_output.write_bytes(b"\x03\x02\x23\x07fragment")

            def rel(path: Path) -> str:
                return path.relative_to(root).as_posix()

            evidence["rows"][0]["tint"]["outputArtifacts"] = [
                {
                    "target": "spirv",
                    "entryPoint": "vs_main",
                    "shaderStage": "vertex",
                    "outputSha256": target_validation.file_sha256(vertex_output),
                    "outputPath": rel(vertex_output),
                    "validationStatus": "passed",
                    "validationTool": "spirv-val",
                    "validationMessage": "",
                },
                {
                    "target": "spirv",
                    "entryPoint": "fs_main",
                    "shaderStage": "fragment",
                    "outputSha256": target_validation.file_sha256(fragment_output),
                    "outputPath": rel(fragment_output),
                    "validationStatus": "passed",
                    "validationTool": "spirv-val",
                    "validationMessage": "",
                },
            ]

            report = self._report(evidence, root, "spirv")
            evidence["rows"][0]["tint"]["outputArtifacts"][1]["outputSha256"] = "0" * 64
            mismatch_report = self._report(evidence, root, "spirv")

        self.assertEqual(report["status"], "pass")
        self.assertEqual(report["failures"], [])
        self.assertEqual(mismatch_report["status"], "fail")
        self.assertTrue(
            any(
                item["code"] == "tint_output_artifact_hash_mismatch"
                for item in mismatch_report["failures"]
            )
        )

    def test_target_validation_rejects_unsafe_output_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            evidence = self._evidence(root)
            evidence["rows"][0]["tint"]["outputPath"] = "../output.spv"
            report = self._report(evidence, root, "spirv")

        self.assertEqual(report["status"], "fail")
        self.assertTrue(
            any(item["code"] == "tint_output_path_unsafe" for item in report["failures"])
        )

    def test_target_validation_requires_passed_validation_status(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            evidence = self._evidence(root)
            evidence["rows"][0]["tint"]["validationStatus"] = "failed"
            report = self._report(evidence, root, "spirv")

        self.assertEqual(report["status"], "fail")
        self.assertTrue(
            any(item["code"] == "tint_validation_not_passed" for item in report["failures"])
        )

    def test_target_validation_can_compose_diagnostic_rows_across_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            first = self._evidence(root, "first")
            second = self._evidence(root, "second")
            second["rows"][0]["shaderId"] = "shader-diagnostic"
            second["rows"][0]["doe"] = {
                "status": "failed",
                "diagnosticCode": "doe_compile_failed",
                "diagnosticMessage": "unsupported builtin textureBarrier",
                "outputSha256": None,
                "outputPath": "",
                "receiptPath": "",
                "validationStatus": "not_run",
                "validationTool": "",
                "validationMessage": "",
            }
            report = self._report_multi(
                [
                    ("bench/out/first.json", first),
                    ("bench/out/second.json", second),
                ],
                root,
                "spirv",
                allow_diagnostic_rows=True,
            )

        self.assertEqual(report["status"], "pass")
        self.assertEqual(report["evidencePaths"], ["bench/out/first.json", "bench/out/second.json"])
        self.assertEqual(report["summary"]["rowCount"], 2)
        self.assertEqual(report["summary"]["validatedRows"], 1)
        self.assertEqual(report["summary"]["diagnosticRows"], 1)
        self.assertEqual(report["summary"]["claimBlockerCount"], 1)
        self.assertEqual(report["failures"], [])
        self.assertEqual(report["claimBlockers"][0]["code"], "doe_result_not_ok")
        self.assertEqual(
            report["claimBlockers"][0]["message"],
            "Doe compiler result is not ok: doe_compile_failed: unsupported builtin textureBarrier",
        )
        self.assertEqual(
            report["claimBlockerSummary"],
            [
                {
                    "code": "doe_result_not_ok",
                    "message": (
                        "Doe compiler result is not ok: doe_compile_failed: "
                        "unsupported builtin textureBarrier"
                    ),
                    "count": 1,
                }
            ],
        )
        self.assertEqual(
            report["claimBlockerSummaryByEvidencePath"],
            [
                {
                    "evidencePath": "bench/out/first.json",
                    "claimBlockerSummary": [],
                },
                {
                    "evidencePath": "bench/out/second.json",
                    "claimBlockerSummary": [
                        {
                            "code": "doe_result_not_ok",
                            "message": (
                                "Doe compiler result is not ok: doe_compile_failed: "
                                "unsupported builtin textureBarrier"
                            ),
                            "count": 1,
                        }
                    ],
                },
            ],
        )

    def test_target_validation_keeps_ok_row_artifact_errors_hard_in_diagnostic_mode(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            evidence = self._evidence(root)
            evidence["rows"][0]["doe"]["outputSha256"] = "0" * 64
            report = self._report_multi(
                [("bench/out/evidence.json", evidence)],
                root,
                "spirv",
                allow_diagnostic_rows=True,
            )

        self.assertEqual(report["status"], "fail")
        self.assertTrue(
            any(item["code"] == "doe_output_hash_mismatch" for item in report["failures"])
        )


if __name__ == "__main__":
    unittest.main()
