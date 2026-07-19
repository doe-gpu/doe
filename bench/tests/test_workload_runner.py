#!/usr/bin/env python3
"""Contracts for the unified Doe workload runner."""

from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

from bench.workload_runner import run_suite


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRATCH_ROOT = REPO_ROOT / "bench" / "out" / "scratch"


class WorkloadRunnerTests(unittest.TestCase):
    def setUp(self) -> None:
        SCRATCH_ROOT.mkdir(parents=True, exist_ok=True)
        self.temp_dir = tempfile.TemporaryDirectory(
            prefix="doe-workload-runner-",
            dir=SCRATCH_ROOT,
        )
        self.root = Path(self.temp_dir.name)
        self.input_path = self.root / "input.txt"
        self.input_path.write_text("alpha\n", encoding="utf-8")

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def _relative(self, path: Path) -> str:
        return path.relative_to(REPO_ROOT).as_posix()

    def _suite(
        self,
        command: list[str],
        *,
        inputs: list[dict[str, str]] | None = None,
        policy_kind: str = "correctness-only",
        evidence_extensions: list[dict[str, object]] | None = None,
    ) -> Path:
        workload: dict[str, object] = {
            "workloadId": "runner_contract",
            "inputs": inputs or [
                {
                    "kind": "file",
                    "path": self._relative(self.input_path),
                }
            ],
            "oracle": {
                "oracleId": "process/exit-zero-v1",
                "kind": "process-exit",
                "expectedExitCode": 0,
            },
            "executor": {
                "executorId": "python_fixture",
                "executorKind": "pure",
                "workingDirectory": ".",
                "command": command,
            },
            "policy": {
                "policyId": f"{policy_kind}/v1",
                "kind": policy_kind,
            },
        }
        if evidence_extensions is not None:
            workload["evidenceExtensions"] = evidence_extensions
        suite = {
            "schemaVersion": 1,
            "suiteId": "runner_contract_suite",
            "workloads": [workload],
        }
        suite_path = self.root / "suite.json"
        suite_path.write_text(
            json.dumps(suite, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        return suite_path

    def test_passing_workload_emits_small_core_and_typed_extensions(self) -> None:
        suite_path = self._suite(
            [sys.executable, "-c", "print('workload passed')"]
        )
        output_path = self.root / "ledger.json"

        ledger = run_suite(suite_path, output_path, REPO_ROOT)

        self.assertEqual(ledger["summary"]["status"], "pass")
        result = ledger["results"][0]
        self.assertEqual(
            set(result),
            {
                "correctness",
                "evidenceExtensions",
                "executorIdentity",
                "expectedOutcome",
                "inputIdentity",
                "measuredTiming",
                "policyId",
                "workloadId",
            },
        )
        self.assertEqual(result["correctness"]["status"], "pass")
        self.assertIsNone(result["correctness"]["firstFailingBoundary"])
        self.assertGreater(result["measuredTiming"]["elapsedNs"], 0)
        self.assertEqual(
            [item["extensionType"] for item in result["evidenceExtensions"]],
            [
                "input_manifest",
                "process_result",
                "process_stdout",
                "process_stderr",
            ],
        )
        for extension in result["evidenceExtensions"]:
            self.assertFalse(Path(extension["path"]).is_absolute())
            self.assertTrue((REPO_ROOT / extension["path"]).is_file())

    def test_oracle_failure_names_first_boundary(self) -> None:
        suite_path = self._suite([sys.executable, "-c", "raise SystemExit(3)"])
        ledger = run_suite(suite_path, self.root / "failed.json", REPO_ROOT)

        result = ledger["results"][0]
        self.assertEqual(ledger["summary"]["status"], "fail")
        self.assertEqual(result["correctness"]["status"], "fail")
        self.assertEqual(result["correctness"]["firstFailingBoundary"], "oracle")
        self.assertEqual(
            result["correctness"]["reasonCode"],
            "unexpected_process_exit",
        )
        process_result = next(
            item
            for item in result["evidenceExtensions"]
            if item["extensionType"] == "process_result"
        )
        self.assertEqual(
            json.loads((REPO_ROOT / process_result["path"]).read_text()),
            {"returnCode": 3},
        )

    def test_input_identity_changes_when_input_changes(self) -> None:
        suite_path = self._suite([sys.executable, "-c", "raise SystemExit(0)"])
        first = run_suite(suite_path, self.root / "first.json", REPO_ROOT)
        self.input_path.write_text("beta\n", encoding="utf-8")
        second = run_suite(suite_path, self.root / "second.json", REPO_ROOT)

        self.assertNotEqual(
            first["results"][0]["inputIdentity"]["hash"],
            second["results"][0]["inputIdentity"]["hash"],
        )

    def test_repository_tree_hashes_nonignored_source_changes(self) -> None:
        source_root = Path(
            tempfile.mkdtemp(
                prefix=".doe-workload-source-",
                dir=REPO_ROOT / "bench" / "tests",
            )
        )
        self.addCleanup(lambda: source_root.rmdir())
        source_path = source_root / "source.txt"
        self.addCleanup(lambda: source_path.unlink(missing_ok=True))
        source_path.write_text("present\n", encoding="utf-8")
        suite_path = self._suite(
            [sys.executable, "-c", "raise SystemExit(0)"],
            inputs=[
                {
                    "kind": "repository-tree",
                    "path": self._relative(source_root),
                }
            ],
        )

        first = run_suite(suite_path, self.root / "first.json", REPO_ROOT)
        source_path.write_text("changed\n", encoding="utf-8")
        second = run_suite(suite_path, self.root / "second.json", REPO_ROOT)

        self.assertNotEqual(
            first["results"][0]["inputIdentity"]["hash"],
            second["results"][0]["inputIdentity"]["hash"],
        )

    def test_repository_tree_preserves_external_symlink_identity(self) -> None:
        source_root = Path(
            tempfile.mkdtemp(
                prefix=".doe-workload-symlink-",
                dir=REPO_ROOT / "bench" / "tests",
            )
        )
        self.addCleanup(lambda: source_root.rmdir())
        link_path = source_root / "source-link"
        self.addCleanup(lambda: link_path.unlink(missing_ok=True))
        link_target = "/external/doe-workload-target"
        link_path.symlink_to(link_target)
        suite_path = self._suite(
            [sys.executable, "-c", "raise SystemExit(0)"],
            inputs=[
                {
                    "kind": "repository-tree",
                    "path": self._relative(source_root),
                }
            ],
        )

        ledger = run_suite(suite_path, self.root / "symlink.json", REPO_ROOT)
        input_manifest = next(
            extension
            for extension in ledger["results"][0]["evidenceExtensions"]
            if extension["extensionType"] == "input_manifest"
        )
        manifest = json.loads(
            (REPO_ROOT / input_manifest["path"]).read_text(encoding="utf-8")
        )

        self.assertIn(
            {
                "kind": "symlink",
                "path": self._relative(link_path),
                "sha256": hashlib.sha256(link_target.encode("utf-8")).hexdigest(),
            },
            manifest["items"],
        )

    def test_claim_bearing_workload_requires_evidence_extension(self) -> None:
        suite_path = self._suite(
            [sys.executable, "-c", "raise SystemExit(0)"],
            policy_kind="claim-bearing",
        )
        with self.assertRaisesRegex(ValueError, "schema validation failed"):
            run_suite(suite_path, self.root / "claim.json", REPO_ROOT)

    def test_missing_claim_extension_fails_after_oracle(self) -> None:
        suite_path = self._suite(
            [sys.executable, "-c", "raise SystemExit(0)"],
            policy_kind="claim-bearing",
            evidence_extensions=[
                {
                    "extensionType": "claim_receipt",
                    "path": self._relative(self.root / "missing-claim.json"),
                    "required": True,
                }
            ],
        )
        ledger = run_suite(suite_path, self.root / "missing.json", REPO_ROOT)

        result = ledger["results"][0]
        self.assertEqual(result["correctness"]["status"], "fail")
        self.assertEqual(
            result["correctness"]["firstFailingBoundary"],
            "evidence_extension",
        )
        self.assertNotIn(
            "claim_receipt",
            [item["extensionType"] for item in result["evidenceExtensions"]],
        )

    def test_failed_oracle_never_attaches_existing_claim_extension(self) -> None:
        claim_path = self.root / "claim.json"
        claim_path.write_text("{}\n", encoding="utf-8")
        suite_path = self._suite(
            [sys.executable, "-c", "raise SystemExit(4)"],
            policy_kind="claim-bearing",
            evidence_extensions=[
                {
                    "extensionType": "claim_receipt",
                    "path": self._relative(claim_path),
                    "required": True,
                }
            ],
        )
        ledger = run_suite(suite_path, self.root / "rejected-claim.json", REPO_ROOT)

        result = ledger["results"][0]
        self.assertEqual(result["correctness"]["firstFailingBoundary"], "oracle")
        self.assertNotIn(
            "claim_receipt",
            [item["extensionType"] for item in result["evidenceExtensions"]],
        )

    def test_existing_output_is_never_overwritten(self) -> None:
        suite_path = self._suite([sys.executable, "-c", "raise SystemExit(0)"])
        output_path = self.root / "immutable.json"
        run_suite(suite_path, output_path, REPO_ROOT)

        with self.assertRaisesRegex(FileExistsError, "already exists"):
            run_suite(suite_path, output_path, REPO_ROOT)


if __name__ == "__main__":
    unittest.main()
