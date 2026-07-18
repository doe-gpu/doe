from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from bench.runners import run_single_workload_sweep as sweep


class SingleWorkloadSweepTests(unittest.TestCase):
    def test_find_run_receipt_requires_exact_product_and_workload(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp)
            artifact_dir = workspace / "run-artifacts" / "doe"
            artifact_dir.mkdir(parents=True)
            expected = artifact_dir / "doe-target.run.json"
            expected.write_text(
                json.dumps({"product": "doe", "workload": {"id": "target"}}),
                encoding="utf-8",
            )
            (artifact_dir / "doe-other.run.json").write_text(
                json.dumps({"product": "doe", "workload": {"id": "other"}}),
                encoding="utf-8",
            )

            self.assertEqual(
                sweep.find_run_receipt(
                    workspace_path=workspace,
                    product="doe",
                    workload="target",
                ),
                expected,
            )

    def test_run_once_uses_receipt_first_sequence_and_accepts_diagnostic_claim(
        self,
    ) -> None:
        settings = sweep.SweepConfig(
            baseline_product="doe",
            comparison_product="dawn_delegate",
            comparability="strict",
            require_timing_class="operation",
            resource_probe="none",
            resource_sample_target_count=0,
            benchmark_policy="",
        )
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config = root / "compare.json"
            config.write_text("{}\n", encoding="utf-8")
            workspace = root / "workspace"
            report = root / "result.json"
            commands: list[list[str]] = []

            def fake_run(command: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
                commands.append(command)
                subcommand = command[2]
                if subcommand == "run-config":
                    side = command[command.index("--side") + 1]
                    product = "doe" if side == "baseline" else "dawn_delegate"
                    artifact_dir = workspace / "run-artifacts" / product
                    artifact_dir.mkdir(parents=True, exist_ok=True)
                    (artifact_dir / f"{product}-target.run.json").write_text(
                        json.dumps(
                            {"product": product, "workload": {"id": "target"}}
                        ),
                        encoding="utf-8",
                    )
                    return subprocess.CompletedProcess(command, 0, "run ok", "")
                if subcommand == "compare":
                    report.write_text('{"workloads": []}\n', encoding="utf-8")
                    return subprocess.CompletedProcess(command, 0, "compare ok", "")
                if subcommand == "claim":
                    claim_path = Path(command[command.index("--out") + 1])
                    claim_path.write_text(
                        '{"claimStatus": "diagnostic"}\n', encoding="utf-8"
                    )
                    return subprocess.CompletedProcess(command, 2, "claim diagnostic", "")
                raise AssertionError(f"unexpected command: {command}")

            with patch.object(sweep.subprocess, "run", side_effect=fake_run):
                return_code, output, receipts = sweep.run_once(
                    config=config,
                    sweep_config=settings,
                    workload="target",
                    out_path=report,
                    workspace_path=workspace,
                )

            self.assertEqual(return_code, 0)
            self.assertIn("claim diagnostic", output)
            self.assertEqual(len(receipts), 2)
            self.assertEqual(
                [command[2] for command in commands],
                ["run-config", "run-config", "compare", "claim"],
            )
            compare_command = commands[2]
            self.assertNotIn("--config", compare_command)
            self.assertIn(str(receipts[0]), compare_command)
            self.assertIn(str(receipts[1]), compare_command)

    def test_run_once_refuses_existing_workspace(self) -> None:
        settings = sweep.SweepConfig(
            baseline_product="doe",
            comparison_product="dawn_delegate",
            comparability="strict",
            require_timing_class="operation",
            resource_probe="none",
            resource_sample_target_count=0,
            benchmark_policy="",
        )
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            workspace.mkdir()
            return_code, output, receipts = sweep.run_once(
                config=root / "compare.json",
                sweep_config=settings,
                workload="target",
                out_path=root / "result.json",
                workspace_path=workspace,
            )

            self.assertEqual(return_code, 1)
            self.assertIn("refusing to reuse", output)
            self.assertEqual(receipts, [])


if __name__ == "__main__":
    unittest.main()
