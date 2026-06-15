"""Tests for the advisory TSIR nightly parity canary."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

from bench.gates import nightly_tsir_parity_canary as canary


REPO_ROOT = Path(__file__).resolve().parents[2]

LOWERING_IDENTITY_KEYS = (
    "emitterDigest",
    "targetDescriptorCorrectnessHash",
    "tsirRealizationDigest",
    "tsirSemanticDigest",
)


class NightlyTsirParityCanaryTests(unittest.TestCase):
    _report_tmp: tempfile.TemporaryDirectory[str] | None = None
    _report: dict | None = None

    @classmethod
    def tearDownClass(cls) -> None:
        if cls._report_tmp is not None:
            cls._report_tmp.cleanup()
            cls._report_tmp = None
            cls._report = None

    @classmethod
    def _bootstrap_report(cls) -> dict:
        if cls._report is None:
            cls._report_tmp = tempfile.TemporaryDirectory()
            cls._report = canary.build_report(
                canary.DEFAULT_FIXTURE_DIR,
                canary.DEFAULT_INPUTS_DIR,
                Path(cls._report_tmp.name),
                python=sys.executable,
            )
        return cls._report

    def test_loads_exact_bootstrap_fixture_set(self) -> None:
        entries = canary.load_fixture_entries(canary.DEFAULT_FIXTURE_DIR)
        pairs = {
            (entry["kernelRef"], entry["backend"])
            for _, entry in entries
        }
        self.assertEqual(len(entries), 12)
        expected_pairs = {
            (kernel_ref, backend)
            for kernel_ref in (
                "doe.tsir.bootstrap.fused_gemv",
                "doe.tsir.bootstrap.gather",
                "doe.tsir.bootstrap.rms_norm",
            )
            for backend in (
                "webgpu-generic",
                "wse3",
                "msl",
                "spir-v",
            )
        }
        self.assertEqual(pairs, expected_pairs)

    def test_canary_runs_fixture_receipts_without_claiming_backend_pass(self) -> None:
        """Reference lane is expected to be green once input-tensor fixtures
        exist; backend lanes may be either pass or deferred depending on
        which local execution adapters are available. The advisory canary
        must only fail on explicit fail statuses."""
        report = self._bootstrap_report()
        self.assertEqual(report["artifactKind"], "tsir_nightly_parity_canary")
        self.assertEqual(report["fixtureCount"], 12)
        self.assertEqual(report["failures"], [])
        for result in report["results"]:
            self.assertIn("loweringIdentity", result)
            self.assertEqual(result["statuses"][0], "pass")
            self.assertNotIn("fail", result["statuses"])
            self.assertIn(result["cliExitCode"], (0, 1))

    def test_canary_receipts_carry_fixture_lowering_identity(self) -> None:
        """Each canary receipt must carry the same TSIR identity digests as
        the source manifest-lowering fixture it was produced from.

        This locks the cross-artifact invariant that a parity receipt is
        bound to exactly the (semantic, realization, emitter, target)
        tuple declared by the manifest entry — not a drifted or
        recomputed version. If a future change to the parity CLI or the
        canary starts emitting receipts with different digests than the
        fixture, this test turns red and blocks the drift before it
        reaches per-kernel-family parity promotion.
        """
        kernel_prefix = "doe.tsir.bootstrap."
        entries = canary.load_fixture_entries(canary.DEFAULT_FIXTURE_DIR)
        fixture_by_pair = {
            (
                entry["kernelRef"].removeprefix(kernel_prefix),
                entry["backend"],
            ): entry
            for _, entry in entries
        }

        report = self._bootstrap_report()
        for result in report["results"]:
            kernel = result["kernel"]
            backend = result["backend"]
            fixture = fixture_by_pair[(kernel, backend)]
            identity = result["loweringIdentity"]
            for key in LOWERING_IDENTITY_KEYS:
                self.assertEqual(
                    identity[key],
                    fixture[key],
                    msg=(
                        f"canary receipt {kernel}/{backend} diverged "
                        f"from fixture on {key}: receipt={identity[key]!r} "
                        f"fixture={fixture[key]!r}"
                    ),
                )

    def test_real_kernel_requires_doppler_transcript_dir(self) -> None:
        fixture = (
            REPO_ROOT
            / "bench"
            / "fixtures"
            / "tsir-real-entries"
            / "fused_gemv.webgpu-generic.json"
        )
        entry = canary.tsir_manifest_lowering.load_entry_doc(fixture)
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(ValueError, "--doppler-transcripts-dir"):
                canary.run_fixture(
                    fixture,
                    entry,
                    Path(tmp),
                    canary.DEFAULT_INPUTS_DIR,
                    sys.executable,
                )

    def test_real_kernel_threads_doppler_transcript_and_probe(self) -> None:
        fixture = (
            REPO_ROOT
            / "bench"
            / "fixtures"
            / "tsir-real-entries"
            / "fused_gemv.webgpu-generic.json"
        )
        entry = canary.tsir_manifest_lowering.load_entry_doc(fixture)
        captured_cmd: list[str] = []

        def fake_run(
            cmd: list[str],
            cwd: Path,
            check: bool,
            text: bool,
            stdout: int,
            stderr: int,
        ) -> canary.subprocess.CompletedProcess[str]:
            del cwd, check, text, stdout, stderr
            captured_cmd.extend(cmd)
            receipt_dir = Path(cmd[cmd.index("--receipt-dir") + 1])
            receipt_dir.mkdir(parents=True, exist_ok=True)
            receipt = {
                "schemaVersion": 2,
                "artifactKind": "doe_parity_receipt",
                "kernel": "fused_gemv",
                "exactnessClass": entry["exactness"]["class"],
                "referenceHash": None,
                "inputsDigest": "test-inputs",
                "loweringIdentity": {
                    key: entry[key] for key in LOWERING_IDENTITY_KEYS
                },
                "referenceSource": {
                    "kind": "doppler-reference-transcript",
                    "executionGraphHash": "sha256:" + ("a" * 64),
                    "sourceHash": "sha256:" + ("b" * 64),
                    "transcriptPath": "fixture",
                },
                "comparisons": [
                    {
                        "backend": "reference",
                        "status": "not_implemented",
                    },
                    {
                        "backend": "webgpu",
                        "status": "deferred",
                    },
                    {
                        "backend": "csl-simfabric",
                        "status": "deferred",
                    },
                ],
                "rejectionReasons": [],
            }
            (receipt_dir / "fused_gemv.parity.json").write_text(
                json.dumps(receipt),
                encoding="utf-8",
            )
            return canary.subprocess.CompletedProcess(cmd, 1, "", "")

        original_run = canary.subprocess.run
        canary.subprocess.run = fake_run
        try:
            with tempfile.TemporaryDirectory() as tmp:
                tmp_path = Path(tmp)
                transcripts = tmp_path / "transcripts"
                probes = tmp_path / "probes"
                transcripts.mkdir()
                probes.mkdir()
                transcript_path = transcripts / "fused_gemv.doppler-transcript.json"
                transcript_path.write_text("{}", encoding="utf-8")
                probe_hash = "c" * 64
                (probes / "fused_gemv.kernel-probe-hash").write_text(
                    probe_hash + "\n",
                    encoding="utf-8",
                )
                result = canary.run_fixture(
                    fixture,
                    entry,
                    tmp_path / "out",
                    canary.DEFAULT_INPUTS_DIR,
                    sys.executable,
                    doppler_transcripts_dir=transcripts,
                    doppler_probes_dir=probes,
                )
        finally:
            canary.subprocess.run = original_run

        self.assertEqual(result["statuses"], ["not_implemented", "deferred", "deferred"])
        self.assertIn("--doppler-transcript", captured_cmd)
        self.assertEqual(
            captured_cmd[captured_cmd.index("--doppler-transcript") + 1],
            str(transcript_path),
        )
        self.assertIn("--doppler-kernel-probe-hash", captured_cmd)
        self.assertEqual(
            captured_cmd[captured_cmd.index("--doppler-kernel-probe-hash") + 1],
            probe_hash,
        )


if __name__ == "__main__":
    unittest.main()
