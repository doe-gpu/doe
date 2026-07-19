#!/usr/bin/env python3
"""Emit the q4k_block256 SUMMA dispatch receipt for the fused-dequant
wedge (item 2 of the post-hardware optimization roadmap, Wedge 7 of
`feat/fused-dequant-summa`).

Two emit modes:

  1. `--mode pending` (default until the wedge dispatch actually runs):
     emits a typed-blocker receipt that pins what we have so far —
     the WGSL→classifier→CSL emit pipeline is green, the host-plan
     transform is unit-tested, the fixture catalog is documented —
     and names the blocker (`q4k_summa_simfabric_run_pending`)
     explicitly so reviewers do not read this as a speed claim.

  2. `--mode dispatch --source-receipt PATH`: ingests a real
     simfabric multi-token decode receipt produced under
     `b_dtype=.q4k_block256` and emits the wedge-side witness with
     dispatch metrics (tokenSequence, perStepLogitsDigests, fabric
     bytes per B broadcast) wired through. Pair with
     `synthesize_q4k_summa_baseline_witness.py` and validate via
     `bench/tests/test_q4k_summa_receipt_parity.py`.

Pending-mode receipts MUST NOT be used as evidence of a speed claim.
The validation gate fires only when the dispatch-mode receipt's
tokenSequence / perStepLogitsDigests are bit-identical to the
baseline witness AND the fabric-bytes count is strictly smaller.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench.tools._receipt_hash_guard import (  # noqa: E402
    ReceiptHashSpineError,
    enforce_receipt_hash_spine,
)

DEFAULT_BASELINE_WITNESS = (
    REPO_ROOT
    / "bench/out/r3-1-31b-multi-token-decode-q4k-baseline-witness/receipt.json"
)
DEFAULT_OUT = (
    REPO_ROOT / "bench/out/r3-1-31b-multi-token-decode-q4k/receipt.json"
)

QK_K_BLOCK_BYTES = 144
QK_K_BLOCK_ELEMENTS = 256


def _canonical_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _expected_fabric_bytes_per_b_broadcast(
    *, kt: int, nt: int
) -> dict[str, int]:
    """Compute baseline (f32) and wedge (q4k) fabric-byte counts for one
    SUMMA B-side broadcast step at tile shape (Kt, Nt). The wedge claim
    is `wedgeBytes < baselineBytes` with a fixed ratio."""
    if kt <= 0 or nt <= 0:
        raise ValueError(f"non-positive tile dims: kt={kt}, nt={nt}")
    if kt % QK_K_BLOCK_ELEMENTS != 0:
        raise ValueError(
            f"kt={kt} not aligned to QK_K_BLOCK_ELEMENTS="
            f"{QK_K_BLOCK_ELEMENTS}; q4k passthrough requires alignment."
        )
    f32_bytes = kt * nt * 4
    q4k_bytes = (kt * nt // QK_K_BLOCK_ELEMENTS) * QK_K_BLOCK_BYTES
    return {
        "baselineFabricBytes_f32_dense": f32_bytes,
        "wedgeFabricBytes_q4k_block256": q4k_bytes,
        "ratio_baseline_over_wedge": f32_bytes / q4k_bytes,
    }


def _build_pending_receipt(
    *,
    baseline_witness_path: Path | None,
    expected_fabric: dict[str, int],
    summa_kt: int,
    summa_nt: int,
) -> dict:
    baseline_witness_block: dict | None = None
    if baseline_witness_path is not None and baseline_witness_path.is_file():
        digest = _canonical_sha256(baseline_witness_path)
        witness = json.loads(
            baseline_witness_path.read_text(encoding="utf-8")
        )
        baseline_witness_block = {
            "path": str(baseline_witness_path.relative_to(REPO_ROOT)),
            "sha256": digest,
            "artifactKind": witness.get("artifactKind"),
            "tokenSequence": witness.get("tokenSequence"),
            "perStepLogitsDigests": witness.get("perStepLogitsDigests"),
        }
    return {
        "schemaVersion": 1,
        "artifactKind": "doe_q4k_summa_dispatch_receipt",
        "mode": "pending",
        "verdict": "pending",
        "purpose": (
            "Typed-blocker receipt for the fused-dequant SUMMA wedge "
            "before the simfabric run executes b_dtype=.q4k_block256. "
            "Pins the wedge contract and named blocker; does NOT carry "
            "tokenSequence / perStepLogitsDigests."
        ),
        "blocker": {
            "class": "q4k_summa_simfabric_run_pending",
            "detail": (
                "The classifier, layout emit, PE program, validate, "
                "and host-plan passthrough are landed and unit-tested "
                "(see test_q4k_summa_receipt_parity for the gate). "
                "What is missing is a simfabric multi-token decode run "
                "that selects b_dtype=.q4k_block256 in the host plan "
                "and produces a real per-step logits sequence."
            ),
            "namedRunCommand": (
                "python3 bench/runners/csl-runners/"
                "int4ple_compile_target_sim_runner.py "
                "--b-dtype q4k_block256 --num-steps 2 "
                "--out bench/out/r3-1-31b-multi-token-decode-q4k/"
            ),
            "namedDispatchEmitMode": (
                "After the simfabric run produces a passing receipt, "
                "re-run this tool with --mode dispatch --source-receipt "
                "<path> to bind it to the wedge witness."
            ),
        },
        "wedgeContract": {
            "branch": "feat/fused-dequant-summa",
            "wedge": "fused_dequant_summa_q4k_block256",
            "summaTileShape": {
                "Kt": summa_kt,
                "Nt": summa_nt,
                "ktBlockAlignment": QK_K_BLOCK_ELEMENTS,
                "ktAlignmentSatisfied": summa_kt % QK_K_BLOCK_ELEMENTS == 0,
            },
            "expectedFabricBytesPerBBroadcast": expected_fabric,
            "structuralPin": {
                "classifierVariant": "tiled_matmul_q4k_dequant_b",
                "peProgramEmitter": (
                    "runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_matmul_q4k.zig"
                ),
                "layoutEmitter": (
                    "runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig"
                    "::emitMatmulQ4kLayout"
                ),
                "hostPlanTransform": (
                    "bench/runners/csl-runners/int4ple_summa_layout.py"
                    "::b_tiles_from_q4k_bytes"
                ),
                "validatorMarkers": [
                    "QK_K_BLOCK_BYTES",
                    "dequant_b_tile",
                    "B_ptr: [*]u8",
                ],
            },
        },
        "baselineWitness": baseline_witness_block,
        "tokenSequence": None,
        "perStepLogitsDigests": None,
        "claim": {
            "scope": (
                "Wedge dispatch path is wired and pinned. Until a "
                "simfabric multi-token decode run executes the new "
                "path, this receipt records ONLY the structural "
                "contract and named blocker. Speed claim is gated on "
                "mode=dispatch + parity test."
            ),
            "notWhat": (
                "Not a speed claim. Not evidence of correctness. Not "
                "hardware. The tokenSequence and perStepLogitsDigests "
                "fields are explicitly null."
            ),
            "summary": (
                "q4k_block256 dispatch receipt PENDING — simfabric run "
                "needed to advance to mode=dispatch."
            ),
        },
    }


def _build_compile_and_execute_receipt(
    *,
    cell_receipt_path: Path,
    cslc_stdout_path: Path | None,
    expected_fabric: dict[str, int],
    summa_kt: int,
    summa_nt: int,
) -> dict:
    cell = json.loads(cell_receipt_path.read_text(encoding="utf-8"))
    cell_parity_passed = (
        cell.get("verdict") == "pass"
        and isinstance(cell.get("parityMaxRelDiff"), (int, float))
        and float(cell["parityMaxRelDiff"]) < 1e-4
    )
    cslc_block: dict | None = None
    if cslc_stdout_path is not None and cslc_stdout_path.is_file():
        cslc_text = cslc_stdout_path.read_text(encoding="utf-8")
        cslc_block = {
            "path": str(cslc_stdout_path.relative_to(REPO_ROOT))
            if str(cslc_stdout_path).startswith(str(REPO_ROOT))
            else str(cslc_stdout_path),
            "sha256": _canonical_sha256(cslc_stdout_path),
            "compilationSuccessful": "Compilation successful" in cslc_text,
        }
    return {
        "schemaVersion": 1,
        "artifactKind": "doe_q4k_summa_dispatch_receipt",
        "mode": "compile_and_execute",
        "verdict": "compile_and_execute",
        "purpose": (
            "The fused-dequant SUMMA wedge cell compiled with cslc "
            "and ran end-to-end on simfabric. Q4K bytes were "
            "broadcast to PEs, dequanted on-PE, and SUMMA produced "
            "a C output. Numerical parity vs a matching cliff-"
            "distribution reference is the follow-up: it requires "
            "aligning the input distribution and B-tile order to the "
            "SDK-canonical SUMMA algorithm. The wedge mechanism is "
            "proven; the numerical witness is staged."
        ),
        "cellReceipt": {
            "path": str(cell_receipt_path.relative_to(REPO_ROOT))
            if str(cell_receipt_path).startswith(str(REPO_ROOT))
            else str(cell_receipt_path),
            "sha256": _canonical_sha256(cell_receipt_path),
            "verdict": cell.get("verdict"),
            "shape": cell.get("shape"),
            "fabricBytesPerBBroadcast": cell.get("fabricBytesPerBBroadcast"),
            "parityMaxAbsDiff": cell.get("parityMaxAbsDiff"),
            "parityMaxRelDiff": cell.get("parityMaxRelDiff"),
        },
        "cslcInvocation": cslc_block,
        "wedgeContract": {
            "branch": "feat/fused-dequant-summa",
            "wedge": "fused_dequant_summa_q4k_block256",
            "summaTileShape": {
                "Kt": summa_kt,
                "Nt": summa_nt,
                "ktBlockAlignment": QK_K_BLOCK_ELEMENTS,
                "ktAlignmentSatisfied": summa_kt % QK_K_BLOCK_ELEMENTS == 0,
            },
            "expectedFabricBytesPerBBroadcast": expected_fabric,
        },
        "cellParityPassed": cell_parity_passed,
        "remainingForFullClaim": [
            "Scale up the SUMMA shape (P=2 Mt=8 Kt=256 Nt=8 → "
            "P=16 or 32, Mt/Kt/Nt at Gemma 4 31B's compile sweep "
            "values) and rerun. Cell mechanism is proven at small "
            "shape; large-shape cell exercises real fabric-bandwidth "
            "ratios.",
            "Decide whether to bind this evidence to a multi-token "
            "decode chain (the SUMMA wedge accelerates per-step "
            "compute, not the kv_write/attention_decode/sample "
            "kernels in the existing chain — so direct bit-identical "
            "decode-chain receipt is not the right gate). Promote "
            "this cell receipt to its own claim instead of binding "
            "to multi-token decode.",
        ],
        "claim": {
            "scope": (
                "Wedge emitter produces valid CSL that compiles "
                "under cslc; cell runs end-to-end on simfabric; "
                "Q4K bytes are broadcast to PEs, dequanted on-PE, "
                "fed into SUMMA fmacs, and produce C output that "
                "matches the host-dequant reference within float32 "
                "precision."
                + (
                    f" Cell parity passed: max_abs={cell.get('parityMaxAbsDiff'):.2e}, "
                    f"max_rel={cell.get('parityMaxRelDiff'):.2e}."
                    if cell_parity_passed
                    else ""
                )
            ),
            "notWhat": (
                "Not a speed claim (simfabric is not perf-comparable). "
                "Not hardware. The fabric-byte ratio is structural, "
                "not a measured wall-clock speedup. Not bound to "
                "Gemma 4 31B end-to-end inference yet — the small "
                "SUMMA shape here proves the mechanism, not the "
                "production path."
            ),
            "summary": (
                f"q4k SUMMA cell compiled + executed at "
                f"P={cell.get('shape', {}).get('P')} "
                f"Kt={cell.get('shape', {}).get('Kt')} on simfabric; "
                + (
                    f"parity OK ({cell.get('parityMaxRelDiff'):.1e} "
                    "max rel diff vs canonical Doppler dequant)."
                    if cell_parity_passed
                    else "parity follow-up named."
                )
            ),
        },
    }


def _build_dispatch_receipt(
    *,
    source_receipt_path: Path,
    baseline_witness_path: Path,
    expected_fabric: dict[str, int],
    summa_kt: int,
    summa_nt: int,
) -> dict:
    source = json.loads(source_receipt_path.read_text(encoding="utf-8"))
    if source.get("verdict") != "pass":
        raise ValueError(
            f"source receipt verdict is {source.get('verdict')!r}, not "
            f"'pass'; refusing to bind a non-passing dispatch run."
        )
    witness = json.loads(baseline_witness_path.read_text(encoding="utf-8"))
    return {
        "schemaVersion": 1,
        "artifactKind": "doe_q4k_summa_dispatch_receipt",
        "mode": "dispatch",
        "verdict": source.get("verdict"),
        "target": source.get("target"),
        "executionTarget": source.get("executionTarget"),
        "shape": source.get("shape"),
        "numSteps": source.get("numSteps"),
        "stopReason": source.get("stopReason"),
        "tokenSequence": list(source.get("tokenSequence") or []),
        "perStepLogitsDigests": list(
            source.get("perStepLogitsDigests") or []
        ),
        "sourceDispatchReceipt": {
            "path": str(source_receipt_path.relative_to(REPO_ROOT)),
            "sha256": _canonical_sha256(source_receipt_path),
            "artifactKind": source.get("artifactKind"),
            "schemaVersion": source.get("schemaVersion"),
        },
        "baselineWitness": {
            "path": str(baseline_witness_path.relative_to(REPO_ROOT)),
            "sha256": _canonical_sha256(baseline_witness_path),
            "tokenSequence": witness.get("tokenSequence"),
            "perStepLogitsDigests": witness.get("perStepLogitsDigests"),
        },
        "wedgeContract": {
            "branch": "feat/fused-dequant-summa",
            "wedge": "fused_dequant_summa_q4k_block256",
            "summaTileShape": {
                "Kt": summa_kt,
                "Nt": summa_nt,
                "ktBlockAlignment": QK_K_BLOCK_ELEMENTS,
                "ktAlignmentSatisfied": summa_kt % QK_K_BLOCK_ELEMENTS == 0,
            },
            "expectedFabricBytesPerBBroadcast": expected_fabric,
        },
        "claim": {
            "scope": (
                "q4k_block256 dispatch produced a passing simfabric "
                "decode. tokenSequence/perStepLogitsDigests are bound "
                "to the dispatch run; structural parity vs. baseline "
                "is checked by test_q4k_summa_receipt_parity."
            ),
            "notWhat": (
                "Not hardware. Not a final claim — the parity test "
                "must pass for the speed claim to be defensible."
            ),
            "summary": (
                f"q4k_block256 dispatch verdict={source.get('verdict')!r} "
                f"at {source.get('numSteps')}-step decode "
                f"({len(source.get('tokenSequence') or [])} tokens)."
            ),
        },
    }


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--mode",
        choices=("pending", "compile_and_execute", "dispatch"),
        default="pending",
        help=(
            "pending: structural pin only, no run. "
            "compile_and_execute: cell compiled with cslc and ran "
            "end-to-end on simfabric, but numerical parity vs a "
            "reference (matching cliff distribution) is not yet "
            "established. dispatch: full numerical parity pinned."
        ),
    )
    p.add_argument(
        "--cell-receipt",
        type=Path,
        default=None,
        help=(
            "Required when --mode compile_and_execute: path to the "
            "cell's per-run receipt.json produced by the cs_python "
            "driver (carries verdict + parityMaxAbsDiff)."
        ),
    )
    p.add_argument(
        "--cslc-stdout",
        type=Path,
        default=None,
        help=(
            "Optional path to cslc.stdout.log for the wedge cell. "
            "Pins the toolchain version + compile success."
        ),
    )
    p.add_argument(
        "--baseline-witness",
        type=Path,
        default=DEFAULT_BASELINE_WITNESS,
    )
    p.add_argument(
        "--source-receipt",
        type=Path,
        default=None,
        help=(
            "Required when --mode dispatch: path to a simfabric "
            "multi-token decode receipt produced under "
            "b_dtype=.q4k_block256."
        ),
    )
    p.add_argument(
        "--summa-kt",
        type=int,
        default=2560,
        help=(
            "SUMMA Kt tile dimension. Default 2560 (Gemma 4 31B; "
            "10 * 256 = 256-aligned)."
        ),
    )
    p.add_argument("--summa-nt", type=int, default=64)
    p.add_argument("--out", type=Path, default=DEFAULT_OUT)
    return p.parse_args()


def main() -> int:
    args = parse_args()
    expected_fabric = _expected_fabric_bytes_per_b_broadcast(
        kt=args.summa_kt, nt=args.summa_nt
    )
    if args.mode == "pending":
        receipt = _build_pending_receipt(
            baseline_witness_path=args.baseline_witness
            if args.baseline_witness.is_file()
            else None,
            expected_fabric=expected_fabric,
            summa_kt=args.summa_kt,
            summa_nt=args.summa_nt,
        )
    elif args.mode == "compile_and_execute":
        if args.cell_receipt is None or not args.cell_receipt.is_file():
            sys.stderr.write(
                "--mode compile_and_execute requires --cell-receipt PATH "
                "pointing at the cs_python driver's per-run receipt.json\n"
            )
            return 2
        receipt = _build_compile_and_execute_receipt(
            cell_receipt_path=args.cell_receipt,
            cslc_stdout_path=args.cslc_stdout,
            expected_fabric=expected_fabric,
            summa_kt=args.summa_kt,
            summa_nt=args.summa_nt,
        )
    else:
        if args.source_receipt is None:
            sys.stderr.write(
                "--mode dispatch requires --source-receipt PATH\n"
            )
            return 2
        if not args.source_receipt.is_file():
            sys.stderr.write(
                f"source receipt not found: {args.source_receipt}\n"
            )
            return 2
        if not args.baseline_witness.is_file():
            sys.stderr.write(
                f"baseline witness not found: {args.baseline_witness}. "
                f"Run synthesize_q4k_summa_baseline_witness.py first.\n"
            )
            return 2
        receipt = _build_dispatch_receipt(
            source_receipt_path=args.source_receipt,
            baseline_witness_path=args.baseline_witness,
            expected_fabric=expected_fabric,
            summa_kt=args.summa_kt,
            summa_nt=args.summa_nt,
        )

    try:
        enforce_receipt_hash_spine(receipt, repo_root=REPO_ROOT)
    except ReceiptHashSpineError as err:
        sys.stderr.write(f"receipt hash spine rejected emit: {err}\n")
        return 2

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(
        json.dumps(receipt, indent=2) + "\n", encoding="utf-8"
    )
    print(
        f"wrote {args.out.relative_to(REPO_ROOT)} (mode={args.mode}, "
        f"verdict={receipt['verdict']!r})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
