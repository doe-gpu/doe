"""Tests for portable external-project preparation and reproduction plans."""

from __future__ import annotations

import json
import platform
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from bench.external_project_reproduction import (
    Selection,
    _payload_sha256,
    prepare_external_project,
    reproduce_external_project,
    reproduction_plan,
    resolve_selection,
)


REPO_ROOT = Path(__file__).resolve().parents[2]


class ExternalProjectReproductionPlanTests(unittest.TestCase):
    def test_cpp_ml_plan_bootstraps_pinned_zig_before_version_and_build(self) -> None:
        selection = resolve_selection(
            REPO_ROOT,
            "electronicarts-cpp-ml-intro",
            "mnist-webgpu-demo",
            run_id="portable-plan-test",
        )

        plan = reproduction_plan(selection)

        self.assertEqual(
            plan["bootstrapCommands"],
            [["python3", "bench/tools/bootstrap_zig.py"]],
        )
        self.assertIn(
            [".tooling/zig-0.15.2/zig", "version"],
            plan["versionCommands"],
        )
        self.assertIn(
            [
                "../../.tooling/zig-0.15.2/zig",
                "build",
                "dropin",
                "-Doptimize=ReleaseFast",
            ],
            plan["doeCommands"],
        )
        self.assertEqual(
            plan["upstreamRoot"],
            "bench/out/external-projects/electronicarts-cpp-ml-intro/upstream",
        )
        self.assertEqual(
            plan["workloadCommand"][-2:],
            ["--run-id", "portable-plan-test"],
        )


class ExternalProjectReproductionExecutionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.actor_id = "sample-actor"
        self.harness_id = "sample-harness"
        self.platform_id = self._platform_id()
        self._create_contracts()

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    @staticmethod
    def _platform_id() -> str:
        if sys.platform.startswith("linux"):
            return "linux"
        if sys.platform == "darwin":
            return "darwin"
        if sys.platform == "win32":
            return "win32"
        raise unittest.SkipTest(f"unsupported test platform: {sys.platform}")

    @staticmethod
    def _write_json(path: Path, payload: dict[str, object]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(payload, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    @staticmethod
    def _run_git(repository: Path, *arguments: str) -> str:
        completed = subprocess.run(
            ["git", "-C", str(repository), *arguments],
            check=True,
            capture_output=True,
            text=True,
        )
        return completed.stdout.strip()

    def _create_contracts(self) -> None:
        config_root = self.root / "config"
        config_root.mkdir(parents=True)
        for filename in (
            "external-project-preparation-receipt.schema.json",
            "external-project-reproduction-receipt.schema.json",
        ):
            shutil.copyfile(REPO_ROOT / "config" / filename, config_root / filename)

        source_root = self.root / "fixture-source"
        source_root.mkdir()
        self._run_git(source_root, "init")
        (source_root / ".gitignore").write_text("installed.txt\n", encoding="utf-8")
        (source_root / "README.md").write_text("fixture\n", encoding="utf-8")
        self._run_git(source_root, "add", ".gitignore", "README.md")
        self._run_git(
            source_root,
            "-c",
            "user.name=Doe Test",
            "-c",
            "user.email=doe-test@example.invalid",
            "commit",
            "-m",
            "fixture",
        )
        self.commit = self._run_git(source_root, "rev-parse", "HEAD")
        source_url = source_root.as_uri()

        provider_path = self.root / "provider.node"
        provider_path.write_bytes(b"provider")
        manifest_path = (
            self.root
            / "bench/external-projects/sample-actor/sample.harness.json"
        )
        manifest = {
            "actorId": self.actor_id,
            "harnessId": self.harness_id,
            "upstream": {"repositoryUrl": source_url, "commit": self.commit},
            "installation": {
                "installSteps": [
                    {
                        "id": "fixture-dependencies",
                        "command": [
                            sys.executable,
                            "-c",
                            (
                                "from pathlib import Path; "
                                "Path('installed.txt').write_text('ok')"
                            ),
                        ],
                        "workingDirectory": {
                            "scope": "upstream",
                            "path": ".",
                        },
                        "timeoutSeconds": 30,
                    }
                ],
            },
            "reproduction": {
                "providerModulePath": "provider.node",
                "arguments": ["{runRoot}/raw.json", "{runRoot}/receipt.json"],
                "evidenceFiles": [
                    {"id": "raw", "path": "raw.json"},
                    {"id": "receipt", "path": "receipt.json"},
                ],
            },
            "workload": {
                "command": [
                    sys.executable,
                    "-c",
                    (
                        "import pathlib,sys; "
                        "pathlib.Path(sys.argv[1]).write_text('{\"ok\":true}'); "
                        "pathlib.Path(sys.argv[2]).write_text('{\"receipt\":true}')"
                    ),
                ]
            },
            "supportTargets": [
                {
                    "id": "fixture-physical-target",
                    "os": self.platform_id,
                    "arch": platform.machine(),
                    "adapter": "PHYSICAL_GPU",
                    "driver": "FIXTURE_DRIVER",
                    "status": "promoted",
                }
            ],
        }
        self._write_json(manifest_path, manifest)

        registry = {
            "actors": [
                {
                    "id": self.actor_id,
                    "source": {
                        "repositoryUrl": source_url,
                        "upstreamCommit": self.commit,
                    },
                    "harnesses": [
                        {
                            "id": self.harness_id,
                            "manifestPath": manifest_path.relative_to(
                                self.root
                            ).as_posix(),
                        }
                    ],
                }
            ]
        }
        self._write_json(config_root / "ecosystem-registry.json", registry)

        python_command = [sys.executable, "-c"]

        def process(process_id: str, command: list[str]) -> dict[str, object]:
            return {
                "id": process_id,
                "command": command,
                "workingDirectory": ".",
                "timeoutSeconds": 30,
            }

        policy = {
            "upstreamRootTemplate": (
                "bench/out/external-projects/{actorId}/upstream"
            ),
            "runRootTemplate": (
                "bench/out/external-projects/{actorId}/{runId}"
            ),
            "sourceCommandTimeoutSeconds": 30,
            "workloadCommandTimeoutSeconds": 30,
            "bootstrapCommands": [],
            "versionCommands": [
                process("python-version", [*python_command, "print('Python fixture')"])
            ],
            "hardwareProbes": {
                self.platform_id: {
                    "command": process(
                        "hardware-probe",
                        [
                            *python_command,
                            "print('PHYSICAL_GPU FIXTURE_DRIVER')",
                        ],
                    ),
                    "requiredPatterns": ["PHYSICAL_GPU"],
                    "prohibitedPatterns": ["SOFTWARE_RENDERER"],
                }
            },
            "doePreparation": {
                "commonCommands": [
                    process(
                        "build-doe",
                        [
                            *python_command,
                            (
                                "from pathlib import Path; "
                                "Path('doe.bin').write_bytes(b'doe')"
                            ),
                        ],
                    )
                ],
                "platformCommands": {self.platform_id: []},
                "commonArtifacts": [{"id": "doe-runtime", "path": "doe.bin"}],
                "platformArtifacts": {self.platform_id: []},
            },
            "gateCommands": [
                process("release-gate", [*python_command, "print('PASS')"])
            ],
        }
        self._write_json(
            config_root / "external-project-reproduction-policy.json", policy
        )

    def _selection(self, run_id: str) -> Selection:
        return resolve_selection(
            self.root,
            self.actor_id,
            self.harness_id,
            run_id=run_id,
            validate_contracts=False,
        )

    def test_reproduction_pins_source_and_hashes_all_evidence(self) -> None:
        selection = self._selection("integration-pass")

        receipt, receipt_path = reproduce_external_project(selection)

        self.assertEqual(receipt["status"], "passed", receipt["failure"])
        self.assertEqual(receipt["evidenceMaturity"], "claimable-candidate")
        self.assertEqual(receipt["receiptSha256"], _payload_sha256(receipt))
        self.assertEqual(len(receipt["evidence"]), 2)
        self.assertEqual(
            self._run_git(selection.upstream_root, "rev-parse", "HEAD"),
            self.commit,
        )
        self.assertTrue(receipt_path.is_file())
        preparation = json.loads(
            (selection.run_root / "preparation.json").read_text(encoding="utf-8")
        )
        self.assertEqual(preparation["status"], "passed")
        self.assertEqual(preparation["receiptSha256"], _payload_sha256(preparation))
        self.assertTrue(preparation["source"]["clean"])
        self.assertTrue(preparation["supportTarget"]["claimEligible"])

    def test_dirty_existing_checkout_fails_before_repinning(self) -> None:
        first_selection = self._selection("integration-first")
        first_receipt, _ = reproduce_external_project(first_selection)
        self.assertEqual(first_receipt["status"], "passed", first_receipt["failure"])
        (first_selection.upstream_root / "README.md").write_text(
            "local operator change\n",
            encoding="utf-8",
        )

        receipt, _ = prepare_external_project(self._selection("integration-dirty"))

        self.assertEqual(receipt["status"], "failed")
        self.assertEqual(receipt["failure"]["stage"], "source")
        self.assertIn("local changes", receipt["failure"]["message"])

    def test_software_renderer_stops_before_source_preparation(self) -> None:
        policy_path = (
            self.root / "config/external-project-reproduction-policy.json"
        )
        policy = json.loads(policy_path.read_text(encoding="utf-8"))
        policy["hardwareProbes"][self.platform_id]["command"]["command"] = [
            sys.executable,
            "-c",
            "print('PHYSICAL_GPU FIXTURE_DRIVER SOFTWARE_RENDERER')",
        ]
        self._write_json(policy_path, policy)
        selection = self._selection("integration-software-renderer")

        receipt, _ = prepare_external_project(selection)

        self.assertEqual(receipt["status"], "unavailable")
        self.assertEqual(receipt["failure"]["stage"], "hardware")
        self.assertIn("prohibited fallback", receipt["failure"]["message"])
        self.assertFalse(selection.upstream_root.exists())


if __name__ == "__main__":
    unittest.main()
