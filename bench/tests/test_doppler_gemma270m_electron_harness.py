from __future__ import annotations

import copy
import json
import subprocess
import unittest
from pathlib import Path

import jsonschema

from bench.external_project_reproduction import reproduction_plan, resolve_selection


REPO_ROOT = Path(__file__).resolve().parents[2]
HARNESS_PATH = (
    REPO_ROOT
    / "bench/external-projects/doppler/gemma270m-electron.harness.json"
)
SCHEMA_PATH = REPO_ROOT / "config/external-project-harness.schema.json"


class DopplerGemma270mElectronHarnessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.harness = json.loads(HARNESS_PATH.read_text(encoding="utf-8"))
        cls.schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
        cls.validator = jsonschema.Draft202012Validator(cls.schema)

    def test_harness_validates_against_canonical_external_project_schema(self) -> None:
        self.assertEqual(list(self.validator.iter_errors(self.harness)), [])

    def test_runner_is_valid_ecmascript_module_syntax(self) -> None:
        runner = REPO_ROOT / self.harness["workload"]["command"][1]
        completed = subprocess.run(
            ["node", "--check", str(runner)],
            cwd=REPO_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_model_contract_rejects_missing_model_shader_and_provider_identity(self) -> None:
        removals = (
            ("modelId",),
            ("artifactSource",),
            ("shaderIdentity",),
            ("providerContract",),
            ("application", "package"),
            ("providers", "W0"),
            ("providers", "D0"),
        )
        for removal in removals:
            with self.subTest(removal=removal):
                payload = copy.deepcopy(self.harness)
                target = payload["workload"]["modelContract"]
                for key in removal[:-1]:
                    target = target[key]
                del target[removal[-1]]
                errors = list(self.validator.iter_errors(payload))
                self.assertTrue(errors)

    def test_dry_run_resolves_frozen_source_application_providers_tuple_and_outputs(self) -> None:
        selection = resolve_selection(
            REPO_ROOT,
            "doppler",
            "gemma270m-electron",
            run_id="amd-gemma270m-qm0",
        )

        plan = reproduction_plan(selection)
        resolved = plan["resolvedContract"]
        model = resolved["modelContract"]

        self.assertEqual(
            resolved["upstream"]["commit"],
            "c27d1354b24f2ddfaaccd2742d1550a848db1931",
        )
        self.assertEqual(
            model["manifest"]["path"],
            "models/local/gemma-3-270m-it-q4k-ehf16-af32/manifest.json",
        )
        self.assertEqual(model["artifactSource"]["project"], "doppler")
        self.assertEqual(
            model["artifactSource"]["path"],
            "models/local/gemma-3-270m-it-q4k-ehf16-af32",
        )
        self.assertEqual(model["application"]["runtime"], "electron")
        self.assertEqual(model["application"]["version"], "43.4.0")
        self.assertEqual(
            model["application"]["package"]["path"],
            "bench/external-projects/doppler/electron-app/package.json",
        )
        self.assertFalse(model["execution"]["useChatTemplate"])
        self.assertEqual(model["providers"]["W0"]["id"], "dawn-node-webgpu")
        self.assertEqual(model["providers"]["D0"]["id"], "doe-gpu")
        self.assertEqual(
            resolved["supportTargets"],
            [
                {
                    "id": "linux-x64-radeon-8060s-radv-26-0-3-electron-43-4-0",
                    "os": "linux",
                    "arch": "x86_64",
                    "runtime": "electron-43.4.0",
                    "adapter": "Radeon 8060S Graphics",
                    "driver": "Mesa 26.0.3",
                    "status": "validated",
                }
            ],
        )
        self.assertEqual(
            plan["outputs"]["preparationReceipt"],
            "bench/out/external-projects/doppler/amd-gemma270m-qm0/preparation.json",
        )
        self.assertEqual(
            plan["outputs"]["reproductionReceipt"],
            "bench/out/external-projects/doppler/amd-gemma270m-qm0/reproduction.json",
        )
        self.assertEqual(
            [entry["path"] for entry in plan["outputs"]["evidence"]],
            [
                "bench/out/external-projects/doppler/amd-gemma270m-qm0/result.json",
                "bench/out/external-projects/doppler/amd-gemma270m-qm0/oracle.json",
                (
                    "bench/out/external-projects/doppler/amd-gemma270m-qm0/"
                    "lanes/W0/doppler_int4ple_reference_export.json"
                ),
                (
                    "bench/out/external-projects/doppler/amd-gemma270m-qm0/"
                    "lanes/D0/doppler_int4ple_reference_export.json"
                ),
            ],
        )


if __name__ == "__main__":
    unittest.main()
