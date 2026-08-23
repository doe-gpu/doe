"""Tests for DoeLab Fawn matrix failure handoff."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from pipeline.agent.fawn_matrix_learning_bridge import (
    failure_records,
    validate_learning_manifest,
)


class LearningBridgeTest(unittest.TestCase):
    def test_schema_tracks_v2_authority_contract(self) -> None:
        schema = json.loads(Path(
            "config/doe-lab-fawn-matrix-learning.schema.json"
        ).read_text(encoding="utf-8"))
        proposal = schema["$defs"]["CandidateProposal"]["properties"]
        self.assertEqual(proposal["status"]["const"], "unverified")
        self.assertEqual(proposal["allowedNextStage"]["const"], "verify")
        self.assertEqual(
            set(proposal["prohibitedActions"]["items"]["enum"]),
            {"release_claim", "runtime_policy_mutation", "candidate_promotion"},
        )

    def test_failed_oracle_becomes_hash_chained_learning_record(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "raw.json"
            source.write_text("{}", encoding="utf-8")
            payload = {
                "workloadId": "multi_step_agent_interaction",
                "lanes": {
                    "lane_d_fawn_direct_doe": {
                        "runtimeIdentity": {"selectedRuntime": "doe"},
                        "adapterInfo": {"vendor": "Doe"},
                        "samples": [{
                            "phase": "timed",
                            "iteration": 4,
                            "success": False,
                            "oraclePass": False,
                        }],
                    }
                },
                "errors": [],
            }
            manifest = failure_records(payload, source)
            self.assertEqual(manifest["schemaVersion"], 2)
            self.assertEqual(manifest["recordCount"], 1)
            self.assertEqual(manifest["hashChain"]["rowCount"], 1)
            self.assertEqual(manifest["clusterCount"], 1)
            self.assertEqual(
                manifest["records"][0]["workloadId"],
                "multi_step_agent_interaction",
            )
            proposal = manifest["clusters"][0]["candidateProposal"]
            self.assertEqual(proposal["status"], "unverified")
            self.assertEqual(proposal["hypothesisStatus"], "unestablished")
            self.assertEqual(proposal["allowedNextStage"], "verify")
            self.assertIn("candidate_promotion", proposal["prohibitedActions"])

    def test_repeated_failures_cluster_deterministically(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "raw.json"
            source.write_text("same source bytes", encoding="utf-8")
            failed = {
                "phase": "timed",
                "iteration": 2,
                "success": True,
                "oraclePass": False,
            }
            repeated = {**failed, "iteration": 1}
            passed = {**failed, "iteration": 3, "oraclePass": True}
            lane = {
                "runtimeIdentity": {"selectedRuntime": "doe"},
                "adapterInfo": {"vendor": "Doe"},
                "samples": [failed, passed, repeated],
            }
            payload = {
                "workloadId": "webgpu_model_preprocessing",
                "lanes": {"lane_c_fawn_playwright_doe": lane},
                "errors": [],
            }
            first = failure_records(payload, source)
            lane["samples"] = list(reversed(lane["samples"]))
            second = failure_records(payload, source)
            self.assertEqual(first, second)
            self.assertEqual(first["recordCount"], 2)
            self.assertEqual(first["clusterCount"], 1)
            self.assertEqual(first["clusters"][0]["occurrenceCount"], 2)
            self.assertEqual(
                first["clusters"][0]["candidateProposal"]["observedBoundary"],
                "fawn_doe_runtime_boundary",
            )

    def test_context_report_uses_nested_workload_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "raw.json"
            source.write_text("{}", encoding="utf-8")
            manifest = failure_records({
                "workload": {"workloadId": "context_snapshot_diff"},
                "lanes": {},
                "errors": ["browser launch failed"],
            }, source)
            self.assertEqual(manifest["workloadId"], "context_snapshot_diff")
            self.assertEqual(manifest["records"][0]["failureClass"], "executor_error")

    def test_validator_rejects_authority_widening(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "raw.json"
            source.write_text("{}", encoding="utf-8")
            manifest = failure_records({
                "workloadId": "multi_step_agent_interaction",
                "lanes": {
                    "lane_d_fawn_direct_doe": {
                        "runtimeIdentity": {"selectedRuntime": "doe"},
                        "adapterInfo": {"vendor": "Doe"},
                        "samples": [{
                            "phase": "timed",
                            "iteration": 1,
                            "success": False,
                            "oraclePass": False,
                        }],
                    },
                },
                "errors": [],
            }, source)
            manifest["clusters"][0]["candidateProposal"]["status"] = "promoted"
            with self.assertRaisesRegex(ValueError, "must remain unverified"):
                validate_learning_manifest(manifest)

    def test_validator_rejects_record_tampering(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "raw.json"
            source.write_text("{}", encoding="utf-8")
            manifest = failure_records({
                "workload": {"workloadId": "context_snapshot_diff"},
                "lanes": {},
                "errors": ["launch failed"],
            }, source)
            manifest["records"][0]["error"] = "different failure"
            with self.assertRaisesRegex(ValueError, "hash chain"):
                validate_learning_manifest(manifest)


if __name__ == "__main__":
    unittest.main()
