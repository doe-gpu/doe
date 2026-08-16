from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

import jsonschema

from bench.tools import validate_native_program_identity_trace as validator


ROOT = Path(__file__).resolve().parents[2]
Q5_TRACE = (
    ROOT
    / "bench/out/external-projects/world-lab-runtime-webgpu"
    / "world-lab-package-native-render-identity-clean-install-qm5-v1-retry1"
    / "processes/D0/native-program-identity.jsonl"
)


def sha256(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


class NativeProgramIdentityTraceValidatorTests(unittest.TestCase):
    def setUp(self) -> None:
        out = ROOT / "bench/out"
        out.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=out)
        self.root = Path(self.temp.name)
        self.compute_hash = self._artifact(b"compute")
        self.vertex_hash = self._artifact(b"vertex")
        self.fragment_hash = self._artifact(b"fragment")
        self.trace = self.root / "native-program-identity.jsonl"
        self.rows = [
            {
                "schemaVersion": 1,
                "traceKind": "doe_native_program_identity_v1",
                "event": "dispatch_encoded",
                "processId": 41,
                "sequence": 1,
                "backend": "doe_vulkan",
                "wgslSha256": "1" * 64,
                "backendArtifactSha256": self.compute_hash,
                "backendArtifactFile": self._filename(self.compute_hash),
                "entryPoint": "main",
                "workgroups": [1, 1, 1],
                "repeatIndex": 0,
            },
            {
                "schemaVersion": 1,
                "traceKind": "doe_native_program_identity_v1",
                "event": "submission_succeeded",
                "processId": 41,
                "sequence": 2,
                "backend": "doe_vulkan",
            },
            {
                "schemaVersion": 1,
                "traceKind": "doe_native_program_identity_v1",
                "event": "render_draw_executed",
                "processId": 52,
                "sequence": 1,
                "backend": "doe_vulkan",
                "completion": "internal_submit_and_wait_succeeded",
                "vertexWgslSha256": "2" * 64,
                "fragmentWgslSha256": "3" * 64,
                "vertexBackendArtifactSha256": self.vertex_hash,
                "vertexBackendArtifactFile": self._filename(self.vertex_hash),
                "fragmentBackendArtifactSha256": self.fragment_hash,
                "fragmentBackendArtifactFile": self._filename(self.fragment_hash),
                "vertexEntryPoint": "vs",
                "fragmentEntryPoint": "fs",
                "drawKind": "draw",
                "args": [6, 1, 0, 0],
            },
        ]
        self._write_rows()

    def tearDown(self) -> None:
        self.temp.cleanup()

    @staticmethod
    def _filename(digest: str) -> str:
        return f"doe-native-vulkan-{digest}.spv"

    def _artifact(self, value: bytes) -> str:
        digest = sha256(value)
        (self.root / self._filename(digest)).write_bytes(value)
        return digest

    def _write_rows(self) -> None:
        self.trace.write_text(
            "".join(f"{json.dumps(row)}\n" for row in self.rows),
            encoding="utf-8",
        )

    def _validate(self) -> dict:
        return validator.build_validation(
            self.trace,
            artifact_root=self.root,
            spirv_val_path=Path("/bin/true"),
            require_render_completion=True,
        )

    def test_valid_trace_binds_sequences_completion_and_artifacts(self) -> None:
        result = self._validate()
        self.assertEqual(result["verdict"]["status"], "passed")
        self.assertEqual(result["verdict"]["failureCodes"], [])
        self.assertTrue(all(result["checks"].values()))
        self.assertEqual(result["counts"]["rows"], 3)
        self.assertEqual(result["counts"]["artifacts"], 3)

    def test_missing_compute_submission_fails_closed(self) -> None:
        self.rows.pop(1)
        self._write_rows()
        result = self._validate()
        self.assertEqual(result["verdict"]["status"], "failed")
        self.assertIn(
            "compute_dispatch_lacks_later_submission",
            result["verdict"]["failureCodes"],
        )

    def test_missing_render_completion_fails_strict_validation(self) -> None:
        self.rows[2].pop("completion")
        self._write_rows()
        result = self._validate()
        self.assertEqual(result["verdict"]["status"], "failed")
        self.assertTrue(result["checks"]["rowSchemaValid"])
        self.assertIn(
            "render_draw_lacks_internal_completion",
            result["verdict"]["failureCodes"],
        )

    def test_artifact_tamper_fails_closed(self) -> None:
        (self.root / self._filename(self.compute_hash)).write_bytes(b"changed")
        result = self._validate()
        self.assertEqual(result["verdict"]["status"], "failed")
        self.assertFalse(result["checks"]["backendArtifactsValid"])

    def test_world_lab_q5_trace_passes_the_standalone_validator(self) -> None:
        result = validator.build_validation(
            Q5_TRACE,
            require_render_completion=True,
        )
        self.assertEqual(result["verdict"]["status"], "passed")
        self.assertEqual(result["counts"]["dispatches"], 3)
        self.assertEqual(result["counts"]["renderDraws"], 2)
        self.assertEqual(result["counts"]["submissions"], 3)
        self.assertEqual(result["counts"]["artifacts"], 6)
        output_schema = json.loads(
            (
                ROOT
                / "config/native-program-identity-trace-validation.schema.json"
            ).read_text()
        )
        jsonschema.validate(result, output_schema)


if __name__ == "__main__":
    unittest.main()
