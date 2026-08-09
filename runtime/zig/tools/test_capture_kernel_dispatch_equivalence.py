"""Focused tests for kernel-dispatch equivalence normalization."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from capture_kernel_dispatch_equivalence import _comparison, _without_timing


class KernelDispatchEquivalenceTests(unittest.TestCase):
    def test_timing_normalization_is_recursive_and_narrow(self) -> None:
        normalized = _without_timing(
            {
                "hash": "0x01",
                "executionDurationNs": 10,
                "pipelineCache": {
                    "state": "enabled",
                    "warmupNs": 20,
                    "warmupCount": 1,
                },
            }
        )
        self.assertEqual(
            normalized,
            {
                "hash": "0x01",
                "pipelineCache": {"state": "enabled", "warmupCount": 1},
            },
        )

    def test_digest_comparison_reports_exact_equality(self) -> None:
        digest = "a" * 64
        self.assertEqual(
            _comparison(digest, digest),
            {
                "baselineSha256": digest,
                "candidateSha256": digest,
                "equal": True,
            },
        )


if __name__ == "__main__":
    unittest.main()
