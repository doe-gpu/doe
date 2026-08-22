"""Regressions for physical Fawn matrix evidence and decisions."""

from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from bench.fawn_matrix.cli import aggregate_reports
from bench.fawn_matrix.harness.evaluator import (
    evaluate_decision_rules,
)
from bench.fawn_matrix.harness.evidence import (
    EvidenceError,
    validate_raw_evidence,
)
from bench.fawn_matrix.harness.lanes import build_lane_results
from bench.fawn_matrix.harness.types import Lane


def _hash(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


class FawnMatrixEvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "fixture.html").write_text(
            "fixture",
            encoding="utf-8",
        )
        (self.root / "stock").write_bytes(b"stock")
        (self.root / "fawn").write_bytes(b"fawn")
        (self.root / "doe").write_bytes(b"doe")
        self.workload = {
            "inputPath": "fixture.html",
            "targetTolerances": {"maxP95P50Ratio": 4.0},
            "timedIterations": 3,
            "warmupIterations": 1,
            "workloadId": "context_snapshot_diff",
        }

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _sample(
        self,
        phase: str,
        iteration: int,
        latency: float,
        oracle: str,
    ) -> dict:
        serialized = json.dumps(
            {"iteration": iteration, "phase": phase},
            sort_keys=True,
        )
        return {
            "contextTokens": 10,
            "iteration": iteration,
            "oraclePass": True,
            "oracleSha256": oracle,
            "orderIndex": iteration % 4,
            "payloadSha256": _hash(serialized.encode()),
            "phase": phase,
            "rendererCpuMs": latency / 2,
            "rendererJsHeapMb": 8.0,
            "serializedBytes": len(serialized.encode()),
            "serializedPayload": serialized,
            "success": True,
            "timing": {
                "actionMs": latency / 4,
                "setupMs": latency / 3,
                "snapshotDiffMs": latency / 2,
                "totalWallMs": latency,
            },
            "tokenizerId": "unicode-word-punctuation-v1",
        }

    def _payload(self) -> dict:
        oracle = _hash(b"oracle")
        lanes = {}
        definitions = {
            Lane.LANE_A.value: (
                "playwright_full_ax_v1",
                "dawn",
                self.root / "stock",
                40.0,
            ),
            Lane.LANE_B.value: (
                "playwright_full_ax_v1",
                "dawn",
                self.root / "fawn",
                30.0,
            ),
            Lane.LANE_C.value: (
                "playwright_full_ax_v1",
                "doe",
                self.root / "fawn",
                31.0,
            ),
            Lane.LANE_D.value: (
                "fawn_direct_cdp_incremental_v1",
                "doe",
                self.root / "fawn",
                15.0,
            ),
        }
        for lane_id, definition in definitions.items():
            transport, runtime, browser, base_latency = definition
            artifact = (
                self.root / "doe"
                if runtime == "doe"
                else browser
            )
            samples = [
                self._sample(
                    "warmup",
                    0,
                    base_latency + 0.5,
                    oracle,
                )
            ]
            samples.extend(
                self._sample(
                    "timed",
                    index,
                    base_latency + index,
                    oracle,
                )
                for index in range(3)
            )
            if lane_id == Lane.LANE_D.value:
                for sample in samples:
                    sample["contextTokens"] = 2
            lanes[lane_id] = {
                "adapterInfo": {
                    "architecture": "metal",
                    "vendor": "test",
                },
                "browserIdentity": {
                    "executablePath": str(browser),
                    "executableSha256": _hash(
                        browser.read_bytes()
                    ),
                    "version": "1",
                },
                "runtimeIdentity": {
                    "activeRuntimeProof": {"matched": True},
                    "artifactPath": str(artifact),
                    "artifactSha256": _hash(
                        artifact.read_bytes()
                    ),
                    "fallbackApplied": False,
                    "forcedMode": runtime,
                    "hiddenFallbackAllowed": False,
                    "selectedRuntime": runtime,
                },
                "samples": samples,
                "transport": transport,
            }
        return {
            "lanes": lanes,
            "platform": {
                "hardwareIdentity": {
                    "identityHash": "hardware-a",
                    "verified": True,
                },
                "platformId": "apple-metal",
            },
            "reportKind":
                "fawn-doe-context-snapshot-diff-raw",
            "run": {
                "laneOrderPolicy": "rotating_interleaved_v1",
                "startedAtUtc": "2026-08-22T00:00:00+00:00",
                "timedIterations": 3,
                "warmupIterations": 1,
            },
            "runStatus": "passed",
            "schemaVersion": 1,
            "workload": {
                "inputSha256": _hash(b"fixture"),
                "workloadId": "context_snapshot_diff",
            },
        }

    def test_physical_receipt_builds_scoped_decision(
        self,
    ) -> None:
        payload = self._payload()
        evidence = validate_raw_evidence(
            payload,
            self.workload,
            self.root,
        )
        results = build_lane_results(payload, evidence)
        report = evaluate_decision_rules(
            "context_snapshot_diff",
            results,
            {
                "materialContextReductionRatio": 1.2,
                "materialSpeedupRatio": 1.05,
                "maxMemoryRegressionMb": 32.0,
            },
            payload["platform"],
            evidence,
            {"path": "raw.json", "sha256": "a" * 64},
        )
        self.assertEqual(
            report.evidence_status,
            "physical_diagnostic",
        )
        self.assertFalse(
            report.comparability["doeRuntimePerformanceCredit"]
        )

    def test_synthetic_marker_is_rejected(self) -> None:
        payload = self._payload()
        payload["simulated_mode"] = True
        with self.assertRaisesRegex(EvidenceError, "synthetic"):
            validate_raw_evidence(
                payload,
                self.workload,
                self.root,
            )

    def test_oracle_mismatch_is_rejected(self) -> None:
        payload = self._payload()
        payload["lanes"][Lane.LANE_D.value]["samples"][-1][
            "oracleSha256"
        ] = "b" * 64
        with self.assertRaisesRegex(
            EvidenceError,
            "not equivalent",
        ):
            validate_raw_evidence(
                payload,
                self.workload,
                self.root,
            )

    def test_aggregate_requires_both_physical_platforms(
        self,
    ) -> None:
        report_path = self.root / "apple.json"
        report_path.write_text(
            json.dumps(
                {
                    "evidence_status": "physical_diagnostic",
                    "overall_thesis_status": "INCONCLUSIVE",
                    "platform": {
                        "hardwareIdentity": {
                            "identityHash": "apple"
                        },
                        "platformId": "apple-metal",
                    },
                }
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(ValueError, "exactly"):
            aggregate_reports(
                [report_path],
                self.root / "aggregate.json",
            )


if __name__ == "__main__":
    unittest.main()
