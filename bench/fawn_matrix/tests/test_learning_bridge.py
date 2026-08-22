"""Tests for DoeLab Fawn matrix failure handoff."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from pipeline.agent.fawn_matrix_learning_bridge import failure_records


class LearningBridgeTest(unittest.TestCase):
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
            self.assertEqual(manifest["recordCount"], 1)
            self.assertEqual(manifest["hashChain"]["rowCount"], 1)
            self.assertEqual(
                manifest["records"][0]["workloadId"],
                "multi_step_agent_interaction",
            )


if __name__ == "__main__":
    unittest.main()
