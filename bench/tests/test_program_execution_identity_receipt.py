from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from bench.tools import program_execution_identity_receipt as identity


ROOT = Path(__file__).resolve().parents[2]


def sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


class ProgramExecutionIdentityReceiptTests(unittest.TestCase):
    def setUp(self) -> None:
        out = ROOT / "bench/out"
        out.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=out)
        self.root = Path(self.temp.name)
        self.kernel_root = self.root / "kernels"
        self.artifact_root = self.root / "shader-artifacts"
        self.kernel_root.mkdir()
        self.artifact_root.mkdir()

        self.runtime = self.root / "doe-runtime"
        self.runtime.write_bytes(b"runtime")
        self.source = self.kernel_root / "fixture.wgsl"
        self.source.write_text("@compute @workgroup_size(1) fn main() {}\n")
        self.spirv = self.artifact_root / "fixture.spv"
        self.spirv.write_bytes(b"\x03\x02\x23\x07fixture")
        self.oracle_ref = self.root / "oracle.py"
        self.oracle_ref.write_text("# independent fixture oracle\n")

        source_hash = identity.file_sha256(self.source)
        spirv_hash = identity.file_sha256(self.spirv)
        self.manifest = self.artifact_root / "manifest.json"
        manifest_identity = "6" * 64
        self.manifest.write_text(json.dumps({
            "schemaVersion": 2,
            "backendId": "doe_vulkan",
            "module": "fixture.wgsl",
            "pipelineHash": "7" * 64,
            "wgslSha256": source_hash,
            "irSha256": "4" * 64,
            "spirvSha256": spirv_hash,
            "toolchainSha256": "5" * 64,
            "stages": [
                {"stage": "sema", "artifactSha256": "3" * 64},
                {"stage": "ir_build", "artifactSha256": "4" * 64},
                {
                    "stage": "ir_to_spirv",
                    "artifactSha256": spirv_hash,
                    "artifactPath": self.spirv.name,
                },
            ],
            "hash": manifest_identity,
        }))

        expected = "8" * 64
        reference_id = identity.repo_path(self.oracle_ref)
        self.commands = self.root / "commands.json"
        self.commands.write_text(json.dumps([{
            "kind": "kernel_dispatch",
            "kernel": "fixture.wgsl",
            "repeat": 2,
            "output_oracle": {
                "kind": "sha256_exact_v1",
                "expected_sha256": expected,
                "reference_id": reference_id,
            },
        }]))
        manifest_path = identity.repo_path(self.manifest)
        self.trace_meta = self.root / "execution.meta.json"
        self.trace_meta.write_text(json.dumps({
            "shaderArtifactManifestPath": manifest_path,
            "shaderArtifactManifestHash": manifest_identity,
            "executionBackend": "doe_vulkan",
            "backendLane": "vulkan_test",
            "profile": {"vendor": "fixture", "api": "vulkan"},
            "executionSuccessCount": 1,
            "executionErrorCount": 0,
            "executionDispatchCount": 2,
            "fallbackUsed": False,
            "outputOracleCount": 1,
            "outputOracleMatchedCount": 1,
            "outputOracleFailedCount": 0,
            "outputOracleExpectedSha256": expected,
            "outputOracleActualSha256": expected,
            "outputOracleReferenceId": reference_id,
        }))
        self.trace = self.root / "execution.ndjson"
        self.trace.write_text(json.dumps({
            "opCode": "dispatch",
            "executionShaderArtifactManifestPath": manifest_path,
            "executionShaderArtifactManifestHash": manifest_identity,
            "executionBackend": "doe_vulkan",
            "executionStatus": "ok",
            "executionDispatchCount": 2,
        }) + "\n")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def build(self) -> dict:
        return identity.build_receipt(
            self.runtime,
            self.commands,
            self.kernel_root,
            self.trace_meta,
            self.trace,
        )

    def test_receipt_links_source_backend_execution_and_oracle(self) -> None:
        receipt = self.build()
        self.assertEqual(receipt["verdict"]["status"], "passed")
        self.assertEqual(receipt["verdict"]["failureCodes"], [])
        self.assertTrue(all(receipt["checks"].values()))
        receipt_path = self.root / "receipt.json"
        receipt_path.write_text(json.dumps(receipt))
        self.assertEqual(identity.verify_receipt(receipt_path), [])

    def test_source_tamper_fails_closed(self) -> None:
        receipt = self.build()
        receipt_path = self.root / "receipt.json"
        receipt_path.write_text(json.dumps(receipt))
        self.source.write_text("@compute fn changed() {}\n")
        self.assertNotEqual(identity.verify_receipt(receipt_path), [])
        rebuilt = self.build()
        self.assertEqual(rebuilt["verdict"]["status"], "failed")
        self.assertIn("sourceMatchesManifest", rebuilt["verdict"]["failureCodes"])

    def test_output_oracle_drift_fails_closed(self) -> None:
        meta = json.loads(self.trace_meta.read_text())
        meta["outputOracleActualSha256"] = "9" * 64
        self.trace_meta.write_text(json.dumps(meta))
        receipt = self.build()
        self.assertEqual(receipt["verdict"]["status"], "failed")
        self.assertFalse(receipt["checks"]["outputOracleMatched"])
        receipt_path = self.root / "failed-receipt.json"
        receipt_path.write_text(json.dumps(receipt))
        failures = identity.verify_receipt(receipt_path)
        self.assertTrue(
            any("current inputs do not produce a passing receipt" in failure for failure in failures)
        )


if __name__ == "__main__":
    unittest.main()
