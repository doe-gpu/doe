"""Validation gate for the fused-dequant SUMMA wedge (Wedge 7 of
`feat/fused-dequant-summa`).

Pairs the f32_dense baseline witness with the q4k_block256 dispatch
receipt and fires structural invariants. The gate definition:

  - Existing simfabric multi-token decode chain re-runs unchanged with
    `b_dtype=.f32_dense` (the witness's `baselineSourceReceipt.sha256`
    must still match the live receipt at
    `bench/out/r3-1-31b-multi-token-decode/receipt.json`).
  - Parallel green receipt with `b_dtype=.q4k_block256` exists at
    `bench/out/r3-1-31b-multi-token-decode-q4k/receipt.json`.
  - When the q4k dispatch receipt is in `mode=dispatch`, its
    `tokenSequence` and `perStepLogitsDigests` must equal the
    baseline's element-for-element. Any drift is a hard regression.
  - The wedge's `wedgeFabricBytes_q4k_block256` must be strictly
    smaller than `baselineFabricBytes_f32_dense` (the whole point of
    the wedge).

Tests are tolerant to the wedge's pre-run state:
  - If the q4k receipt is in `mode=pending`, the parity assertions
    are skipped and only the structural-pin invariants are checked.
  - If the q4k receipt does not exist at all, all tests skip with
    a clear pointer to the dispatch writer.
"""

from __future__ import annotations

import hashlib
import json
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

BASELINE_RECEIPT = (
    REPO_ROOT / "bench/out/r3-1-31b-multi-token-decode/receipt.json"
)
BASELINE_WITNESS = (
    REPO_ROOT
    / "bench/out/r3-1-31b-multi-token-decode-q4k-baseline-witness/receipt.json"
)
WEDGE_RECEIPT = (
    REPO_ROOT / "bench/out/r3-1-31b-multi-token-decode-q4k/receipt.json"
)


def _file_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _load_or_skip(test_case: unittest.TestCase, path: Path) -> dict:
    if not path.is_file():
        test_case.skipTest(
            f"{path.relative_to(REPO_ROOT)} not present — "
            f"run the appropriate writer in bench/tools/ first"
        )
    return json.loads(path.read_text(encoding="utf-8"))


class BaselineWitnessFreshnessTests(unittest.TestCase):
    """Witness must continue to bind to the live baseline. If the
    baseline receipt drifts (Gemma 4 31B regression), this fires."""

    def test_baseline_receipt_present(self) -> None:
        if not BASELINE_WITNESS.is_file() and not WEDGE_RECEIPT.is_file():
            self.skipTest(
                "Q4K SUMMA evidence receipts are not present; run the governed "
                "baseline and wedge writers first"
            )
        self.assertTrue(
            BASELINE_RECEIPT.is_file(),
            f"baseline missing: {BASELINE_RECEIPT.relative_to(REPO_ROOT)}",
        )

    def test_witness_present(self) -> None:
        if not BASELINE_WITNESS.is_file():
            self.skipTest(
                "baseline witness not yet emitted; run "
                "bench/tools/synthesize_q4k_summa_baseline_witness.py"
            )

    def test_witness_pins_live_baseline_digest(self) -> None:
        witness = _load_or_skip(self, BASELINE_WITNESS)
        self.assertTrue(
            BASELINE_RECEIPT.is_file(),
            f"baseline missing: {BASELINE_RECEIPT.relative_to(REPO_ROOT)}",
        )
        live_digest = _file_sha256(BASELINE_RECEIPT)
        cited = witness.get("baselineSourceReceipt", {}).get("sha256")
        self.assertEqual(
            cited,
            live_digest,
            "baseline witness pins a stale baseline digest. "
            "Either (a) the f32_dense Gemma 4 31B chain regressed "
            "and the wedge must be reverted, or (b) the witness is "
            "out of date — re-run "
            "bench/tools/synthesize_q4k_summa_baseline_witness.py "
            "to refresh.",
        )

    def test_witness_baseline_verdict_is_pass(self) -> None:
        witness = _load_or_skip(self, BASELINE_WITNESS)
        verdict = (
            witness.get("baselineSourceReceipt", {}).get("verdict")
        )
        self.assertEqual(
            verdict,
            "pass",
            "baseline witness is bound to a non-passing baseline; "
            "the wedge's parity gate is meaningless against a "
            "broken baseline.",
        )


class WedgeReceiptStructureTests(unittest.TestCase):
    """Structural invariants on the q4k_block256 wedge receipt that
    apply regardless of mode (pending or dispatch)."""

    def setUp(self) -> None:
        self.wedge = _load_or_skip(self, WEDGE_RECEIPT)

    def test_artifact_kind(self) -> None:
        self.assertEqual(
            self.wedge.get("artifactKind"),
            "doe_q4k_summa_dispatch_receipt",
        )

    def test_mode_is_recognized(self) -> None:
        self.assertIn(
            self.wedge.get("mode"),
            {"pending", "compile_and_execute", "dispatch"},
        )

    def test_summa_tile_kt_is_256_aligned(self) -> None:
        wedge_contract = self.wedge.get("wedgeContract") or {}
        tile = wedge_contract.get("summaTileShape") or {}
        self.assertTrue(
            tile.get("ktAlignmentSatisfied"),
            f"wedgeContract.summaTileShape.Kt={tile.get('Kt')} is not "
            f"256-aligned; the q4k passthrough requires Q4K block "
            f"boundaries to align with SUMMA tile boundaries.",
        )

    def test_fabric_bytes_wedge_is_smaller_than_baseline(self) -> None:
        wedge_contract = self.wedge.get("wedgeContract") or {}
        fabric = (
            wedge_contract.get("expectedFabricBytesPerBBroadcast") or {}
        )
        baseline_bytes = fabric.get("baselineFabricBytes_f32_dense") or 0
        wedge_bytes = fabric.get("wedgeFabricBytes_q4k_block256") or 0
        self.assertGreater(baseline_bytes, 0)
        self.assertGreater(wedge_bytes, 0)
        self.assertLess(
            wedge_bytes,
            baseline_bytes,
            "wedge fabric bytes per B broadcast is not smaller than "
            "baseline — the wedge has nothing to claim.",
        )


class WedgeCompileAndExecuteTests(unittest.TestCase):
    """Compile + execute milestone: the wedge cell must produce valid
    CSL that compiles under cslc and runs end-to-end on simfabric.
    Numerical parity is the next step (WedgeDispatchParityTests)."""

    def setUp(self) -> None:
        self.wedge = _load_or_skip(self, WEDGE_RECEIPT)
        if self.wedge.get("mode") not in {"compile_and_execute", "dispatch"}:
            self.skipTest(
                f"wedge receipt is in mode={self.wedge.get('mode')!r}; "
                f"compile_and_execute milestone fires only after the "
                f"cs_python driver has produced a per-cell receipt."
            )

    def test_cslc_compilation_successful(self) -> None:
        cslc_block = self.wedge.get("cslcInvocation") or {}
        self.assertTrue(
            cslc_block.get("compilationSuccessful"),
            "wedge CSL did not compile cleanly under cslc; the "
            "emitter is producing invalid CSL.",
        )

    def test_cell_receipt_present(self) -> None:
        cell = self.wedge.get("cellReceipt") or {}
        self.assertTrue(
            cell.get("sha256"),
            "wedge cell receipt sha256 missing; compile_and_execute "
            "claim is not bound to a per-cell run.",
        )
        shape = cell.get("shape") or {}
        self.assertGreaterEqual(
            shape.get("Kt", 0),
            256,
            "cell ran at sub-256 Kt; q4k passthrough requires 256-"
            "aligned K",
        )

    def test_cell_parity_passes_when_recorded(self) -> None:
        cell_parity_flag = self.wedge.get("cellParityPassed")
        if cell_parity_flag is None:
            self.skipTest(
                "cellParityPassed not recorded; older receipt schema. "
                "Re-run synthesize_q4k_summa_dispatch_receipt.py."
            )
        self.assertTrue(
            cell_parity_flag,
            "wedge cell ran but the C output diverges from the "
            "host-dequant reference. Numerical bug in either the "
            "PE-side dequant or the SUMMA accumulation — investigate "
            "before claiming the wedge.",
        )
        cell = self.wedge.get("cellReceipt") or {}
        rel_diff = cell.get("parityMaxRelDiff")
        self.assertIsNotNone(rel_diff)
        self.assertLess(
            float(rel_diff),
            1e-4,
            "cell parityMaxRelDiff exceeds 1e-4; SUMMA accumulation "
            "fp drift is larger than expected.",
        )


class WedgeDispatchParityTests(unittest.TestCase):
    """The actual validation gate: dispatch-mode receipt must match
    baseline tokenSequence and per-step logits digests element-wise.
    Skips when the wedge run hasn't happened yet (mode=pending or
    mode=compile_and_execute)."""

    def setUp(self) -> None:
        self.wedge = _load_or_skip(self, WEDGE_RECEIPT)
        if self.wedge.get("mode") != "dispatch":
            self.skipTest(
                f"wedge receipt is in mode={self.wedge.get('mode')!r}; "
                f"parity gate fires only when a real simfabric "
                f"b_dtype=.q4k_block256 run has produced a dispatch "
                f"receipt. Run "
                f"bench/runners/csl-runners/"
                f"int4ple_compile_target_sim_runner.py with the "
                f"q4k dispatch flag, then "
                f"bench/tools/synthesize_q4k_summa_dispatch_receipt.py "
                f"--mode dispatch --source-receipt PATH."
            )
        self.witness = _load_or_skip(self, BASELINE_WITNESS)

    def test_verdict_pass(self) -> None:
        self.assertEqual(self.wedge.get("verdict"), "pass")

    def test_token_sequence_bit_identical_to_baseline(self) -> None:
        wedge_tokens = self.wedge.get("tokenSequence") or []
        witness_tokens = self.witness.get("tokenSequence") or []
        self.assertEqual(
            list(wedge_tokens),
            list(witness_tokens),
            "tokenSequence drift between baseline (f32_dense) and "
            "wedge (q4k_block256). The wedge claims algorithm-exact "
            "dequant; any drift is a hard regression and the wedge "
            "MUST be reverted.",
        )

    def test_per_step_logits_digests_bit_identical_to_baseline(self) -> None:
        wedge_digests = self.wedge.get("perStepLogitsDigests") or []
        witness_digests = (
            self.witness.get("perStepLogitsDigests") or []
        )
        self.assertEqual(
            list(wedge_digests),
            list(witness_digests),
            "perStepLogitsDigests drift between baseline and wedge. "
            "The dequant arithmetic is supposed to be byte-identical "
            "to the Doppler reference path; any drift here means "
            "either the dequant code is wrong or the SUMMA tile "
            "alignment is broken.",
        )

    def test_wedge_num_steps_matches_baseline(self) -> None:
        baseline_n = self.witness.get("numSteps")
        wedge_n = self.wedge.get("numSteps")
        self.assertEqual(
            wedge_n,
            baseline_n,
            "wedge ran a different number of steps than the baseline; "
            "the comparison is not apples-to-apples.",
        )


if __name__ == "__main__":
    unittest.main()
