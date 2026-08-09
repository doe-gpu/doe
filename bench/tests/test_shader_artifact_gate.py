#!/usr/bin/env python3
"""Regression tests for the shader artifact gate."""

from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
import stat
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_DIR = REPO_ROOT / "bench"
MODULE_PATH = BENCH_DIR / "gates" / "shader_artifact_gate.py"

sys.path.insert(0, str(REPO_ROOT))


def load_module():
    spec = importlib.util.spec_from_file_location("shader_artifact_gate", MODULE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load shader_artifact_gate from {MODULE_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ShaderArtifactGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.module = load_module()

    def write_manifest(self, root: Path, payload: dict) -> Path:
        manifest_path = root / "manifest.json"
        manifest_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
        return manifest_path

    def sha256(self, value: bytes) -> str:
        return hashlib.sha256(value).hexdigest()

    def write_executable(self, root: Path, name: str, body: str) -> Path:
        path = root / name
        path.write_text(body, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IEXEC)
        return path

    def test_spirv_manifest_validates_when_validator_is_provided(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fawn-shader-artifact-gate-") as tmpdir:
            root = Path(tmpdir)
            spirv_path = root / "shader.spv"
            spirv_bytes = b"SPIR-V"
            spirv_path.write_bytes(spirv_bytes)
            spirv_hash = self.sha256(spirv_bytes)
            validator = self.write_executable(
                root,
                "spirv-val",
                "#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n",
            )
            manifest_path = self.write_manifest(
                root,
                {
                    "schemaVersion": 2,
                    "backendId": "doe_vulkan",
                    "module": "doe-zig-runtime",
                    "pipelineHash": "pipeline",
                    "wgslSha256": "0" * 64,
                    "irSha256": "1" * 64,
                    "toolchainSha256": "2" * 64,
                    "taxonomyCode": "ok",
                    "previousHash": "prev",
                    "hash": "hash",
                    "spirvSha256": spirv_hash,
                    "stages": [
                        {
                            "stage": "ir_to_spirv",
                            "implementation": "native_zig",
                            "artifactSha256": spirv_hash,
                            "artifactPath": "shader.spv",
                        }
                    ],
                },
            )

            failures, validated = self.module.validate_spirv_artifacts(
                manifest_path,
                json.loads(manifest_path.read_text(encoding="utf-8")),
                str(validator),
                False,
            )
            self.assertEqual(failures, [])
            self.assertEqual(validated, 1)

            failures, validated = self.module.validate_spirv_artifacts(
                manifest_path,
                json.loads(manifest_path.read_text(encoding="utf-8")),
                "",
                False,
            )
            self.assertEqual(failures, [])
            self.assertEqual(validated, 0)

            failures, validated = self.module.validate_spirv_artifacts(
                manifest_path,
                json.loads(manifest_path.read_text(encoding="utf-8")),
                "",
                True,
            )
            self.assertTrue(any("not provided" in item for item in failures))
            self.assertEqual(validated, 0)

    def test_invalid_spirv_validator_fails(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fawn-shader-artifact-gate-") as tmpdir:
            root = Path(tmpdir)
            spirv_path = root / "shader.spv"
            spirv_bytes = b"SPIR-V"
            spirv_path.write_bytes(spirv_bytes)
            spirv_hash = self.sha256(spirv_bytes)
            validator = self.write_executable(
                root,
                "spirv-val",
                "#!/usr/bin/env python3\nimport sys\nsys.stderr.write('bad spirv\\n')\nsys.exit(1)\n",
            )
            manifest_path = self.write_manifest(
                root,
                {
                    "schemaVersion": 2,
                    "backendId": "doe_vulkan",
                    "module": "doe-zig-runtime",
                    "pipelineHash": "pipeline",
                    "wgslSha256": "0" * 64,
                    "irSha256": "1" * 64,
                    "toolchainSha256": "2" * 64,
                    "taxonomyCode": "ok",
                    "previousHash": "prev",
                    "hash": "hash",
                    "spirvSha256": spirv_hash,
                    "stages": [
                        {
                            "stage": "ir_to_spirv",
                            "implementation": "native_zig",
                            "artifactSha256": spirv_hash,
                            "artifactPath": "shader.spv",
                        }
                    ],
                },
            )

            failures, validated = self.module.validate_spirv_artifacts(
                manifest_path,
                json.loads(manifest_path.read_text(encoding="utf-8")),
                str(validator),
                False,
            )
            self.assertEqual(validated, 0)
            self.assertTrue(any("spirv-val failed" in item for item in failures))

    def test_backend_bootstrap_manifest_has_no_executed_spirv_to_validate(self) -> None:
        manifest = {
            "backendId": "doe_vulkan",
            "module": "bootstrap",
            "taxonomyCode": "backend_initialized",
            "spirvSha256": "0" * 64,
            "stages": [
                {
                    "stage": "ir_to_spirv",
                    "implementation": "native_zig",
                    "artifactSha256": "0" * 64,
                }
            ],
        }
        failures, validated = self.module.validate_spirv_artifacts(
            Path("bootstrap.json"),
            manifest,
            "/usr/bin/spirv-val",
            True,
        )
        self.assertEqual(failures, [])
        self.assertEqual(validated, 0)

    def test_spirv_hash_mismatch_fails(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fawn-shader-artifact-gate-") as tmpdir:
            root = Path(tmpdir)
            spirv_path = root / "shader.spv"
            spirv_bytes = b"SPIR-V"
            spirv_path.write_bytes(spirv_bytes)
            spirv_hash = self.sha256(spirv_bytes)
            manifest_path = self.write_manifest(
                root,
                {
                    "schemaVersion": 2,
                    "backendId": "doe_vulkan",
                    "module": "doe-zig-runtime",
                    "pipelineHash": "pipeline",
                    "wgslSha256": "0" * 64,
                    "irSha256": "1" * 64,
                    "toolchainSha256": "2" * 64,
                    "taxonomyCode": "ok",
                    "previousHash": "prev",
                    "hash": "hash",
                    "spirvSha256": "3" * 64,
                    "stages": [
                        {
                            "stage": "ir_to_spirv",
                            "implementation": "native_zig",
                            "artifactSha256": spirv_hash,
                            "artifactPath": "shader.spv",
                        }
                    ],
                },
            )

            failures, validated = self.module.validate_spirv_artifacts(
                manifest_path,
                json.loads(manifest_path.read_text(encoding="utf-8")),
                "",
                False,
            )

            self.assertEqual(validated, 0)
            self.assertTrue(any("manifest spirvSha256 mismatch" in item for item in failures))

    def test_spirv_stage_hash_mismatch_fails(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fawn-shader-artifact-gate-") as tmpdir:
            root = Path(tmpdir)
            spirv_path = root / "shader.spv"
            spirv_bytes = b"SPIR-V"
            spirv_path.write_bytes(spirv_bytes)
            spirv_hash = self.sha256(spirv_bytes)
            manifest_path = self.write_manifest(
                root,
                {
                    "schemaVersion": 2,
                    "backendId": "doe_vulkan",
                    "module": "doe-zig-runtime",
                    "pipelineHash": "pipeline",
                    "wgslSha256": "0" * 64,
                    "irSha256": "1" * 64,
                    "toolchainSha256": "2" * 64,
                    "taxonomyCode": "ok",
                    "previousHash": "prev",
                    "hash": "hash",
                    "spirvSha256": spirv_hash,
                    "stages": [
                        {
                            "stage": "ir_to_spirv",
                            "implementation": "native_zig",
                            "artifactSha256": "4" * 64,
                            "artifactPath": "shader.spv",
                        }
                    ],
                },
            )

            failures, validated = self.module.validate_spirv_artifacts(
                manifest_path,
                json.loads(manifest_path.read_text(encoding="utf-8")),
                "",
                False,
            )

            self.assertEqual(validated, 0)
            self.assertTrue(any("stage artifactSha256 mismatch" in item for item in failures))

    def test_missing_spirv_artifact_path_requires_explicit_binary_validation(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fawn-shader-artifact-gate-") as tmpdir:
            root = Path(tmpdir)
            manifest_path = self.write_manifest(
                root,
                {
                    "schemaVersion": 2,
                    "backendId": "doe_vulkan",
                    "module": "doe-zig-runtime",
                    "pipelineHash": "pipeline",
                    "wgslSha256": "0" * 64,
                    "irSha256": "1" * 64,
                    "toolchainSha256": "2" * 64,
                    "taxonomyCode": "ok",
                    "previousHash": "prev",
                    "hash": "hash",
                    "spirvSha256": "3" * 64,
                    "stages": [
                        {
                            "stage": "ir_to_spirv",
                            "implementation": "native_zig",
                            "artifactSha256": "4" * 64,
                        }
                    ],
                },
            )
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

            failures, validated = self.module.validate_spirv_artifacts(
                manifest_path,
                manifest,
                "",
                False,
            )
            self.assertEqual(failures, [])
            self.assertEqual(validated, 0)

            failures, validated = self.module.validate_spirv_artifacts(
                manifest_path,
                manifest,
                "",
                True,
            )
            self.assertTrue(any("missing artifactPath" in item for item in failures))
            self.assertEqual(validated, 0)

    def test_non_spirv_manifest_does_not_require_validator(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fawn-shader-artifact-gate-") as tmpdir:
            root = Path(tmpdir)
            manifest_path = self.write_manifest(
                root,
                {
                    "schemaVersion": 2,
                    "backendId": "doe_metal",
                    "module": "doe-zig-runtime",
                    "pipelineHash": "pipeline",
                    "wgslSha256": "0" * 64,
                    "irSha256": "1" * 64,
                    "mslSha256": "2" * 64,
                    "metallibSha256": "3" * 64,
                    "toolchainSha256": "4" * 64,
                    "taxonomyCode": "ok",
                    "previousHash": "prev",
                    "hash": "hash",
                    "stages": [
                        {
                            "stage": "ir_to_msl",
                            "implementation": "native_zig",
                            "artifactSha256": "5" * 64,
                        }
                    ],
                },
            )

            failures, validated = self.module.validate_spirv_artifacts(
                manifest_path,
                json.loads(manifest_path.read_text(encoding="utf-8")),
                "",
                False,
            )
            self.assertEqual(failures, [])
            self.assertEqual(validated, 0)

    def test_main_validates_receipt_first_report_samples(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fawn-shader-artifact-gate-") as tmpdir:
            root = Path(tmpdir)
            spirv_path = root / "shader.spv"
            spirv_bytes = b"SPIR-V"
            spirv_path.write_bytes(spirv_bytes)
            spirv_hash = self.sha256(spirv_bytes)
            validator = self.write_executable(
                root,
                "spirv-val",
                "#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n",
            )
            manifest_path = self.write_manifest(
                root,
                {
                    "schemaVersion": 2,
                    "backendId": "doe_vulkan",
                    "module": "doe-zig-runtime",
                    "pipelineHash": "pipeline",
                    "wgslSha256": "0" * 64,
                    "irSha256": "1" * 64,
                    "toolchainSha256": "2" * 64,
                    "taxonomyCode": "ok",
                    "previousHash": "prev",
                    "hash": "hash",
                    "spirvSha256": spirv_hash,
                    "stages": [
                        {
                            "stage": "ir_to_spirv",
                            "implementation": "native_zig",
                            "artifactSha256": spirv_hash,
                            "artifactPath": "shader.spv",
                        }
                    ],
                },
            )
            run_path = root / "doe-run.json"
            run_path.write_text(
                json.dumps(
                    {
                        "samples": [
                            {
                                "returnCode": 0,
                                "traceMeta": {
                                    "shaderArtifactManifestPath": str(manifest_path),
                                    "shaderArtifactManifestHash": "hash",
                                },
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )
            report_path = root / "compare.json"
            report_path.write_text(
                json.dumps(
                    {
                        "workloads": [
                            {
                                "id": "receipt_workload",
                                "receipts": {"left": {"path": str(run_path)}},
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )

            old_argv = sys.argv
            sys.argv = [
                "shader_artifact_gate.py",
                "--report",
                str(report_path),
                "--schema",
                str(REPO_ROOT / "config" / "shader-artifact.schema.json"),
                "--require-manifest",
                "--spirv-val",
                str(validator),
            ]
            try:
                with redirect_stdout(io.StringIO()):
                    self.assertEqual(self.module.main(), 0)
            finally:
                sys.argv = old_argv

    def test_main_fails_manifest_hash_mismatch(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fawn-shader-artifact-gate-") as tmpdir:
            root = Path(tmpdir)
            manifest_path = self.write_manifest(
                root,
                {
                    "schemaVersion": 2,
                    "backendId": "doe_metal",
                    "module": "doe-zig-runtime",
                    "pipelineHash": "pipeline",
                    "wgslSha256": "0" * 64,
                    "irSha256": "1" * 64,
                    "mslSha256": "2" * 64,
                    "metallibSha256": "3" * 64,
                    "toolchainSha256": "4" * 64,
                    "taxonomyCode": "ok",
                    "previousHash": "prev",
                    "hash": "manifest-hash",
                    "stages": [
                        {
                            "stage": "ir_to_msl",
                            "implementation": "native_zig",
                            "artifactSha256": "5" * 64,
                        }
                    ],
                },
            )
            run_path = root / "doe-run.json"
            run_path.write_text(
                json.dumps(
                    {
                        "samples": [
                            {
                                "returnCode": 0,
                                "traceMeta": {
                                    "shaderArtifactManifestPath": str(manifest_path),
                                    "shaderArtifactManifestHash": "trace-hash",
                                },
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )
            report_path = root / "compare.json"
            report_path.write_text(
                json.dumps(
                    {
                        "workloads": [
                            {
                                "id": "receipt_workload",
                                "receipts": {"left": {"path": str(run_path)}},
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )

            old_argv = sys.argv
            sys.argv = [
                "shader_artifact_gate.py",
                "--report",
                str(report_path),
                "--schema",
                str(REPO_ROOT / "config" / "shader-artifact.schema.json"),
                "--require-manifest",
            ]
            try:
                output = io.StringIO()
                with redirect_stdout(output):
                    self.assertEqual(self.module.main(), 1)
                self.assertIn("manifest hash mismatch", output.getvalue())
            finally:
                sys.argv = old_argv

    def test_main_missing_report_fails_without_traceback(self) -> None:
        old_argv = sys.argv
        sys.argv = [
            "shader_artifact_gate.py",
            "--report",
            "bench/out/missing-shader-artifact-report.json",
            "--schema",
            str(REPO_ROOT / "config" / "shader-artifact.schema.json"),
        ]
        try:
            output = io.StringIO()
            with redirect_stdout(output):
                self.assertEqual(self.module.main(), 1)
            self.assertIn("FAIL: shader artifact gate input error:", output.getvalue())
            self.assertNotIn("Traceback", output.getvalue())
        finally:
            sys.argv = old_argv


if __name__ == "__main__":
    unittest.main(verbosity=2)
