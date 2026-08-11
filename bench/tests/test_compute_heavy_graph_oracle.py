#!/usr/bin/env python3
"""Regression coverage for source-bound compute-heavy graph oracles."""

from __future__ import annotations

import hashlib
import json
import sys
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
if str(BENCH_ROOT) not in sys.path:
    sys.path.insert(0, str(BENCH_ROOT))

from oracles.compute_heavy_graph_consensus_v1 import (
    EXPECTED_GRAPH_IDENTITIES,
    EXPECTED_OUTPUT_SHA256,
    MONTE_CARLO,
    STABLE_FLUIDS,
    expected_sha256,
    graph_identity,
)


class ComputeHeavyGraphOracleTests(unittest.TestCase):
    def test_graph_sources_retain_reviewed_identities(self) -> None:
        for workload, expected_identity in EXPECTED_GRAPH_IDENTITIES.items():
            self.assertEqual(graph_identity(workload), expected_identity)

    def test_expected_hashes_are_source_bound(self) -> None:
        for workload, expected_output in EXPECTED_OUTPUT_SHA256.items():
            self.assertEqual(expected_sha256(workload), expected_output)

    def test_monte_carlo_uses_independent_float32_reference(self) -> None:
        payload = json.loads(
            (BENCH_ROOT / "ir" / "compute_heavy.json").read_text(encoding="utf-8")
        )
        scenarios = {scenario["id"]: scenario for scenario in payload["scenarios"]}
        oracle = scenarios[MONTE_CARLO]["outputOracle"]
        reference_path = REPO_ROOT / oracle["reference_path"]
        reference_sha256 = hashlib.sha256(reference_path.read_bytes()).hexdigest()
        self.assertEqual(oracle["schema_version"], 3)
        self.assertEqual(oracle["reference_class"], "independent_v1")
        self.assertEqual(oracle["kind"], "float32_reference_tolerance_v1")
        self.assertEqual(oracle["reference_sha256"], reference_sha256)
        self.assertEqual(reference_sha256, EXPECTED_OUTPUT_SHA256[MONTE_CARLO])
        self.assertEqual(
            oracle["reference_id"],
            "bench/oracles/monte_carlo_reference_v1.c#final-radiance",
        )

    def test_stable_fluids_uses_independent_float32_reference(self) -> None:
        payload = json.loads(
            (BENCH_ROOT / "ir" / "compute_heavy.json").read_text(encoding="utf-8")
        )
        scenarios = {scenario["id"]: scenario for scenario in payload["scenarios"]}
        oracle = scenarios[STABLE_FLUIDS]["outputOracle"]
        reference_path = REPO_ROOT / oracle["reference_path"]
        reference_sha256 = hashlib.sha256(reference_path.read_bytes()).hexdigest()
        self.assertEqual(oracle["schema_version"], 3)
        self.assertEqual(oracle["reference_class"], "independent_v1")
        self.assertEqual(oracle["kind"], "float32_reference_tolerance_v1")
        self.assertEqual(oracle["reference_sha256"], reference_sha256)
        self.assertEqual(
            oracle["reference_id"],
            "bench/oracles/stable_fluids_reference_v1.c#final-dye",
        )


if __name__ == "__main__":
    unittest.main()
