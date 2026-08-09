"""Tests for the downstream application promotion boundary."""

from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from bench.gates.external_project_release_gate import (
    _floor_failures,
    _preparation_receipt_failures,
    evaluate,
)
from bench.lib.ecosystem_registry import load_json_object
from bench.runners.run_external_project_release_suite import promoted_harnesses


REPO_ROOT = Path(__file__).resolve().parents[2]


class ExternalProjectReleaseGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.registry = load_json_object(
            REPO_ROOT / "config/ecosystem-registry.json"
        )
        cls.policy = load_json_object(
            REPO_ROOT / "config/external-project-promotion-policy.json"
        )
        cls.holo_manifest = load_json_object(
            REPO_ROOT
            / "bench/external-projects/holoscript-snn-webgpu/tropical-spmv.harness.json"
        )

    def test_checked_in_release_surface_passes_without_false_promotion(self) -> None:
        result = evaluate(REPO_ROOT, self.registry, self.policy)

        self.assertTrue(result["ok"], result["failures"])
        self.assertEqual(result["summary"]["promotedHarnessCount"], 0)

    def test_diagnostic_harness_cannot_satisfy_promotion_floor(self) -> None:
        actor = self.registry["actors"][0]
        failures = _floor_failures(
            REPO_ROOT,
            actor,
            self.holo_manifest,
            {},
            self.policy["promotionFloor"],
            "actors[0].harnesses[0]",
        )
        codes = {item["code"] for item in failures}

        self.assertIn("production_substitution_unvalidated", codes)
        self.assertIn("missing_promoted_support_target", codes)
        self.assertIn("reliability_floor_not_met", codes)
        self.assertIn("replay_not_required", codes)
        self.assertIn("release_command_not_blocking", codes)
        self.assertIn("missing_promotion_report", codes)

    def test_release_runner_resolves_promoted_manifest_from_explicit_root(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest_path = root / "harness.json"
            manifest_path.write_text(
                json.dumps(
                    {
                        "releasePolicy": {
                            "promotionState": "promoted",
                            "command": ["node", "run.mjs"],
                        }
                    }
                ),
                encoding="utf-8",
            )
            registry = {
                "actors": [
                    {
                        "id": "actor",
                        "promotionStatus": "promoted",
                        "harnesses": [
                            {"id": "harness", "manifestPath": "harness.json"}
                        ],
                    }
                ]
            }

            self.assertEqual(
                promoted_harnesses(root, registry),
                [("actor", "harness")],
            )

    def test_promotion_requires_preparation_receipt(self) -> None:
        actor = self.registry["actors"][0]
        manifest = dict(self.holo_manifest)
        manifest["receiptPolicy"] = dict(manifest["receiptPolicy"])
        manifest["receiptPolicy"]["preparationReceiptRequired"] = False

        failures = _floor_failures(
            REPO_ROOT,
            actor,
            manifest,
            {},
            self.policy["promotionFloor"],
            "actors[0].harnesses[0]",
        )

        self.assertIn(
            "preparation_receipt_not_required",
            {item["code"] for item in failures},
        )

    def test_promotion_report_requires_valid_claim_eligible_preparation(self) -> None:
        actor = {"id": "sample-actor"}
        manifest = {"harnessId": "sample-harness"}
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            receipt_path = (
                root
                / "bench/out/external-projects/sample-actor/run/preparation.json"
            )
            receipt_path.parent.mkdir(parents=True)
            receipt = {
                "artifactKind": "external-project-preparation-receipt",
                "actorId": "sample-actor",
                "harnessId": "sample-harness",
                "status": "passed",
                "source": {"actualCommit": "a" * 40},
                "supportTarget": {"claimEligible": True},
            }
            receipt["receiptSha256"] = hashlib.sha256(
                json.dumps(
                    receipt,
                    sort_keys=True,
                    separators=(",", ":"),
                ).encode("utf-8")
            ).hexdigest()
            receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
            relative_path = receipt_path.relative_to(root).as_posix()
            report = {
                "reportId": "sample-report",
                "upstream": {"commit": "a" * 40},
                "receipts": [
                    {
                        "path": relative_path,
                        "sha256": hashlib.sha256(receipt_path.read_bytes()).hexdigest(),
                    }
                ],
            }

            self.assertEqual(
                _preparation_receipt_failures(
                    root,
                    actor,
                    manifest,
                    report,
                    "reports.sample-report",
                ),
                [],
            )

            receipt["supportTarget"]["claimEligible"] = False
            receipt_path.write_text(json.dumps(receipt), encoding="utf-8")
            report["receipts"][0]["sha256"] = hashlib.sha256(
                receipt_path.read_bytes()
            ).hexdigest()
            failures = _preparation_receipt_failures(
                root,
                actor,
                manifest,
                report,
                "reports.sample-report",
            )
            self.assertIn(
                "invalid_preparation_receipt",
                {item["code"] for item in failures},
            )


if __name__ == "__main__":
    unittest.main()
