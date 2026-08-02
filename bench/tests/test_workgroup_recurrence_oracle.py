#!/usr/bin/env python3
"""Regression coverage for the repeated workgroup output oracle."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
if str(BENCH_ROOT) not in sys.path:
    sys.path.insert(0, str(BENCH_ROOT))

from oracles.workgroup_recurrence_u32_v1 import expected_sha256


ONE_DISPATCH_SHA256 = "bc0c7a019fa53cc1b9f96a0e282eee1e81ed30a6f053eadc8581331831b25b07"
HUNDRED_DISPATCH_SHA256 = "20b294d0e46d723dd0c7bb96ba3e98ff59d597872f21d6b50bdf29f31d0f8a07"


class WorkgroupRecurrenceOracleTests(unittest.TestCase):
    def test_reference_hashes(self) -> None:
        self.assertEqual(expected_sha256(dispatch_count=1), ONE_DISPATCH_SHA256)
        self.assertEqual(expected_sha256(dispatch_count=100), HUNDRED_DISPATCH_SHA256)

    def test_governed_commands_bind_oracle_to_timed_repeat(self) -> None:
        for name in ("workgroup_atomic_commands.json", "workgroup_non_atomic_commands.json"):
            commands = json.loads((REPO_ROOT / "examples" / name).read_text(encoding="utf-8"))
            command = commands[0]
            oracle = command["output_oracle"]
            self.assertEqual(oracle["dispatch_count"], command["repeat"])
            self.assertEqual(oracle["expected_sha256"], HUNDRED_DISPATCH_SHA256)
            self.assertEqual(
                oracle["reference_id"],
                "bench/oracles/workgroup_recurrence_u32_v1.py",
            )


if __name__ == "__main__":
    unittest.main()
