from __future__ import annotations

import json
import unittest
from pathlib import Path

from jsonschema import Draft202012Validator
from referencing import Registry, Resource


ROOT = Path(__file__).resolve().parents[2]
ASSETS = ROOT / "packages/doe-gpu/assets"
HASH = "sha256:" + ("0" * 64)


def receipt() -> dict:
    return {
        "schema": "doe.governed-node-webgpu-process-receipt/v1",
        "status": "pass",
        "checkpoint": "process-complete",
        "workload": {
            "id": "schema-fixture",
            "version": "1",
            "implementationSha256": HASH,
            "inputSha256": HASH,
            "inputBytes": 0,
            "expectedOutputSha256": HASH,
        },
        "provider": {
            "requested": {"id": "provider", "module": "/provider.mjs"},
            "effective": {"providerId": "provider"},
        },
        "process": {
            "declaration": {
                "executable": "/node",
                "nodeArgs": [],
                "loaderContract": "doe.node-webgpu-loader/v1",
                "entrypoint": "/application.mjs",
                "args": [],
                "cwd": "/work",
                "filesystem": {
                    "mode": "node-permission-read-only",
                    "readPaths": ["/application.mjs", "/provider.mjs"],
                    "workerThreads": "allowed-for-loader",
                    "nativeAddons": "allowed-for-provider",
                },
                "timeoutMs": 1,
                "maxOutputBytes": 1,
            },
            "environment": {"mode": "sealed", "keys": [], "sha256": HASH},
            "exitCode": 0,
            "signal": None,
            "spawned": True,
            "aborted": False,
            "terminationScope": "process-group",
            "timedOut": False,
            "outputLimitExceeded": False,
            "stdoutSha256": HASH,
            "stdoutBytes": 0,
            "stderrSha256": HASH,
            "stderrBytes": 0,
            "durationMs": 0,
        },
        "oracle": {
            "status": "pass",
            "expectedOutputSha256": HASH,
            "actualOutputSha256": HASH,
            "outputBytes": 0,
        },
        "applicationEvidence": None,
        "applicationEvidenceSha256": None,
        "replay": {"workloadSha256": HASH, "executionSha256": HASH},
        "errors": [],
    }


class GovernedProcessSchemaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.receipt_schema = json.loads(
            (ASSETS / "governed-node-webgpu-process-receipt.schema.json").read_text()
        )
        cls.artifact_schema = json.loads(
            (ASSETS / "governed-node-webgpu-process-artifact.schema.json").read_text()
        )
        Draft202012Validator.check_schema(cls.receipt_schema)
        Draft202012Validator.check_schema(cls.artifact_schema)
        registry = Registry().with_resource(
            cls.receipt_schema["$id"], Resource.from_contents(cls.receipt_schema)
        )
        cls.receipt_validator = Draft202012Validator(cls.receipt_schema)
        cls.artifact_validator = Draft202012Validator(
            cls.artifact_schema, registry=registry
        )

    def test_current_receipt_shape_validates(self) -> None:
        self.receipt_validator.validate(receipt())

    def test_current_cli_artifact_shape_validates(self) -> None:
        file_identity = {"path": "/file", "sha256": HASH}
        artifact = {
            "schema": "doe.governed-node-webgpu-process-cli-artifact/v1",
            "status": "pass",
            "command": "run",
            "contract": {"sourcePath": "/contract.json", "sha256": HASH},
            "dependencies": {
                "provider": file_identity,
                "input": file_identity,
                "entrypoint": file_identity,
                "evaluator": file_identity,
                "runtimeFiles": [
                    {"id": "runtime-data", "path": "/data", "sha256": HASH}
                ],
            },
            "receipt": receipt(),
        }
        self.artifact_validator.validate(artifact)

    def test_partial_extended_lifecycle_is_rejected(self) -> None:
        value = receipt()
        del value["process"]["aborted"]
        errors = list(self.receipt_validator.iter_errors(value))
        self.assertTrue(errors)


if __name__ == "__main__":
    unittest.main()
