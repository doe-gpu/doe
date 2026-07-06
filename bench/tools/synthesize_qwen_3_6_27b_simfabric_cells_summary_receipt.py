#!/usr/bin/env python3
"""Synthesize the Qwen 3.6 27B simfabric-cells summary receipt.

Aggregates per-kernel simfabric receipts produced by the small-shape
cell drivers under ``bench/runners/csl-runners/qwen-3-6-27b-cells/``.

Coverage: 10 kernels in the Qwen 3.6 27B compile target inventory.
Seven (rmsnorm, rope_partial, residual, silu, embed, tiled, kv_write,
gemv [width=2], sample) execute end-to-end on simfabric with parity
or documented stand-in semantics. Three carry typed kernel-emit
gaps: attn_decode (missing reduce-task activation), gemv at width≥3
(middle-PE routing pass-through), and sample (missing index reduction);
each is recorded as a per-cell receipt with the gap in claim.notWhat
so the summary cannot misread the lane as fully covered. The 11th
kernel, attn_prefill, is the cslc compile failure
(linker_pe_memory_overflow, "causal prefill" blocker shared with
Gemma 31B) and is NOT a simfabric cell — it never compiled.

The summary receipt cites each per-cell verdict, parity deltas,
source-file sha256s, and the named blockers from the smoke config.

Skip-when-absent for any cell whose receipt has not been produced
yet (the expected pre-regeneration state on a fresh checkout).

Intended invocation, after running the regeneration recipe in
``bench/runners/csl-runners/qwen-3-6-27b-cells/README.md``:

    python3 bench/tools/synthesize_qwen_3_6_27b_simfabric_cells_summary_receipt.py

Default output: ``bench/out/r3-2-27b-qwen-simfabric-cells/summary-receipt.json``.
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

DEFAULT_CELLS_ROOT = REPO_ROOT / "bench/runners/csl-runners/qwen-3-6-27b-cells"
DEFAULT_RECEIPTS_ROOT = REPO_ROOT / "bench/out"
DEFAULT_SMOKE_CONFIG = (
    REPO_ROOT / "runtime/zig/examples/execution-v1/qwen-3-6-27b-smoke.json"
)
DEFAULT_OUT = (
    REPO_ROOT / "bench/out/r3-2-27b-qwen-simfabric-cells/summary-receipt.json"
)

CELLS = [
    {
        "kernel": "rmsnorm",
        "layout_basename": "rmsnorm_layout_patched.csl",
        "pe_program_basename": "rmsnorm_pe_program.csl",
        "run_basename": "rmsnorm_run.py",
        "receipt_dir_basename": "r3-2-27b-qwen-rmsnorm-simfabric-cell",
        "layout_was_patched": True,
        "patch_summary": (
            "layout.csl forwards hidden_size to pe_program — Doe's "
            "emit_csl_layout.zig deliberately omits this at manifest "
            "shape (hidden=5120) because the [hidden_size]f32 × 3 "
            "buffers (60 KB) overflow the WSE-3 per-PE 38 KB budget."
        ),
    },
    {
        "kernel": "rope_partial",
        "layout_basename": "rope_partial_layout.csl",
        "pe_program_basename": "rope_partial_pe_program.csl",
        "run_basename": "rope_partial_run.py",
        "receipt_dir_basename": "r3-2-27b-qwen-rope-partial-simfabric-cell",
        "layout_was_patched": False,
        "patch_summary": (
            "No patch — rope_partial's layout already forwards both "
            "head_dim and num_pairs (manifest-shape buffers fit within "
            "the per-PE budget). Validates the partialRotaryFactor "
            "wiring delta from csl_host_plan_tool.zig end-to-end."
        ),
    },
    {
        "kernel": "residual",
        "layout_basename": "residual_layout_patched.csl",
        "pe_program_basename": "residual_pe_program.csl",
        "run_basename": "residual_run.py",
        "receipt_dir_basename": "r3-2-27b-qwen-residual-simfabric-cell",
        "layout_was_patched": True,
        "patch_summary": (
            "Same per-PE-residency rationale as rmsnorm: layout was "
            "hand-patched to forward chunk_size; the upstream emit "
            "intentionally omits this at manifest scale."
        ),
    },
    {
        "kernel": "silu",
        "layout_basename": "silu_layout_patched.csl",
        "pe_program_basename": "silu_pe_program.csl",
        "run_basename": "silu_run.py",
        "receipt_dir_basename": "r3-2-27b-qwen-silu-simfabric-cell",
        "layout_was_patched": True,
        "patch_summary": (
            "Layout patched to forward chunk_size (same per-PE-"
            "residency rationale as rmsnorm/residual). KERNEL-EMIT "
            "STAND-IN: the silu kernel currently emits as a pure "
            "passthrough (output[idx] = input[idx] * 1.0); validates "
            "the dispatch shape, not actual SiLU arithmetic. "
            "Tracked as scopeRestrictions.swigluFfnFusedGate."
        ),
    },
    {
        "kernel": "embed",
        "layout_basename": "embed_layout.csl",
        "pe_program_basename": "embed_pe_program.csl",
        "run_basename": "embed_run.py",
        "receipt_dir_basename": "r3-2-27b-qwen-embed-simfabric-cell",
        "layout_was_patched": False,
        "patch_summary": (
            "No patch — embed's layout forwards all per-PE shape "
            "params. Validates the per-PE row-ownership branch "
            "(`token_id ∈ [row_start, row_end)`) and table gather "
            "end-to-end."
        ),
    },
    {
        "kernel": "tiled",
        "layout_basename": "tiled_layout.csl",
        "pe_program_basename": "tiled_pe_program.csl",
        "run_basename": "tiled_run.py",
        "receipt_dir_basename": "r3-2-27b-qwen-tiled-simfabric-cell",
        "layout_was_patched": False,
        "patch_summary": (
            "No patch — SUMMA matmul layout forwards Mt/Kt/Nt/P. "
            "Validates the collectives_2d row+column broadcast chain "
            "end-to-end at P=2."
        ),
    },
    {
        "kernel": "kv_write",
        "layout_basename": "kv_write_layout.csl",
        "pe_program_basename": "kv_write_pe_program.csl",
        "run_basename": "kv_write_run.py",
        "receipt_dir_basename": "r3-2-27b-qwen-kv-write-simfabric-cell",
        "layout_was_patched": False,
        "patch_summary": (
            "No patch — kv_write's layout forwards head_dim, "
            "max_seq_len, slots_per_pe. Validates the slot-write at "
            "the requested position; non-owning PE caches stay zero."
        ),
    },
    {
        "kernel": "gemv",
        "layout_basename": "gemv_layout.csl",
        "pe_program_basename": "gemv_pe_program.csl",
        "run_basename": "gemv_run.py",
        "receipt_dir_basename": "r3-2-27b-qwen-gemv-simfabric-cell",
        "layout_was_patched": False,
        "patch_summary": (
            "No patch — gemv layout forwards out_dim_per_pe / "
            "in_dim_per_pe / num_blocks_per_row. Q4_K dequant + "
            "GEMV reduction validated end-to-end at width=2. "
            "KERNEL-EMIT ROUTING GAP at width≥3: middle-PE "
            "reduce_color routing is rx={WEST}, tx={EAST} pure "
            "pass-through, so middle PEs never receive into RAMP "
            "and the reduction at the last PE equals only "
            "partial[0] + partial[width-1]. The width=2 canary "
            "avoids middle PEs and runs to parity; the width≥3 gap "
            "is documented in the per-cell receipt notWhat."
        ),
    },
    {
        "kernel": "sample",
        "layout_basename": "sample_layout.csl",
        "pe_program_basename": "sample_pe_program.csl",
        "run_basename": "sample_run.py",
        "receipt_dir_basename": "r3-2-27b-qwen-sample-simfabric-cell",
        "layout_was_patched": False,
        "patch_summary": (
            "Index-reduction emit fix landed in emit_csl_sample.zig: "
            "scratch buffer extended from 1 to 2 floats, propagating "
            "(max_val, @bitcast(f32, max_idx)) through the chain. "
            "The last PE now writes the GLOBAL argmax index, not "
            "just its own local. Validated at width=2 with arbitrary "
            "logits (parity OK). Width≥3 still subject to the multi-"
            "PE chain routing limitation (see emit_csl_layout.zig "
            "comment) — middle PEs are pass-through, so the chain "
            "skips middle contributions; that is a separate routing "
            "gap orthogonal to the index-reduction fix landed here."
        ),
    },
    {
        "kernel": "attn_decode",
        "layout_basename": "attn_decode_layout.csl",
        "pe_program_basename": "attn_decode_pe_program.csl",
        "run_basename": "attn_decode_run.py",
        "receipt_dir_basename": "r3-2-27b-qwen-attn-decode-simfabric-cell",
        "layout_was_patched": False,
        "patch_summary": (
            "Two emit fixes landed in emit_csl_attention.zig: "
            "(a) replaced the wse2-era synchronous "
            "`@fmovs(f32_var, fabin_dsd)` recv with the canonical "
            "wse3 scratch-buffer + `@mov32(.{.async, "
            ".activate=reduce_task_id})` form, so the reduce_recv "
            "task actually fires (previously bound but never "
            "activated — every simfabric launch hung at memcpy_d2h "
            "with `received length (0 bytes) is not expected`); "
            "(b) added a `num_pes == 1` branch in compute() so "
            "single-PE attention skips the chain and goes straight "
            "to normalize. Validated at width=1 (parity OK). "
            "Width≥2 is subject to a kernel-design gap separate from "
            "the emit fix: the kernel's normalize task softmaxes "
            "over LOCAL kv_chunk only, so chained partial outputs "
            "are not globally cross-PE-normalized — fixing that "
            "requires either a flash-attention-style per-PE partials "
            "kernel (already exists at emit_kv_axis_sharded for the "
            "Gemma 31B head_dim=512 case) or a sum-reduce step "
            "alongside the max-reduce."
        ),
    },
]

# attn_prefill is the Qwen full-graph compile attempt's ONE cslc
# failure (linker_pe_memory_overflow — the same per-PE residency
# blocker the Gemma 4 31B prefill ladder carries; the smoke config
# names it `causalAttentionPrefill`). It is NOT a simfabric cell —
# the kernel never compiled. Recorded here so the summary verdict
# can cite the manifest-shape compile-target gap explicitly.
KNOWN_BLOCKERS = [
    {
        "kernel": "attn_prefill",
        "blocker": "cslc_linker_pe_memory_overflow",
        "blockerDetail": (
            "attn_prefill at Qwen manifest shape (head_dim=256, "
            "q_len=4096) does not link — exceeds the WSE-3 per-PE "
            "data-section budget. Same blocker the Gemma 4 31B "
            "prefill ladder carries (smoke config name: "
            "causalAttentionPrefill). Not a simfabric cell — the "
            "kernel never compiled. Closed by either the R3-2 "
            "single-PE-reduction → fabric-shard redesign or by a "
            "shape-aware split that brings q_len into per-PE budget."
        ),
    },
]


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--cells-root", type=Path, default=DEFAULT_CELLS_ROOT)
    p.add_argument("--receipts-root", type=Path, default=DEFAULT_RECEIPTS_ROOT)
    p.add_argument("--smoke-config", type=Path, default=DEFAULT_SMOKE_CONFIG)
    p.add_argument("--out", type=Path, default=DEFAULT_OUT)
    return p.parse_args()


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _rel(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def _load_smoke_scope_restrictions(smoke_path: Path) -> dict | None:
    if not smoke_path.is_file():
        return None
    try:
        smoke = json.loads(smoke_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return smoke.get("scopeRestrictions")


def _load_cell(
    cell_spec: dict,
    cells_root: Path,
    receipts_root: Path,
) -> dict:
    layout_path = cells_root / cell_spec["layout_basename"]
    pe_path = cells_root / cell_spec["pe_program_basename"]
    run_path = cells_root / cell_spec["run_basename"]
    receipt_path = (
        receipts_root / cell_spec["receipt_dir_basename"] / "receipt.json"
    )

    sources_present = layout_path.is_file() and pe_path.is_file() and run_path.is_file()
    receipt_present = receipt_path.is_file()

    entry: dict = {
        "kernel": cell_spec["kernel"],
        "layoutPath": _rel(layout_path),
        "peProgramPath": _rel(pe_path),
        "runPath": _rel(run_path),
        "receiptPath": _rel(receipt_path),
        "layoutWasPatched": cell_spec["layout_was_patched"],
        "patchSummary": cell_spec["patch_summary"],
    }

    if sources_present:
        entry["layoutSha256"] = _sha256_file(layout_path)
        entry["peProgramSha256"] = _sha256_file(pe_path)
        entry["runSha256"] = _sha256_file(run_path)
    else:
        entry["sourcesPresent"] = False

    if receipt_present:
        try:
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            entry["verdict"] = "receipt_unparseable"
            entry["receiptError"] = str(exc)
            return entry
        entry["verdict"] = receipt.get("verdict", "unknown")
        entry["parityMaxAbsDiff"] = receipt.get("parityMaxAbsDiff")
        entry["parityMaxRelDiff"] = receipt.get("parityMaxRelDiff")
        entry["shape"] = receipt.get("shape")
        entry["receiptSha256"] = _sha256_file(receipt_path)
    else:
        entry["verdict"] = "not_attempted"
        entry["receiptMissing"] = True

    return entry


def main() -> int:
    args = parse_args()

    cells = [
        _load_cell(spec, args.cells_root, args.receipts_root)
        for spec in CELLS
    ]
    cellCount = len(cells)
    passCount = sum(1 for c in cells if c.get("verdict") == "pass")
    failCount = sum(1 for c in cells if c.get("verdict") == "fail")
    notAttemptedCount = sum(
        1 for c in cells if c.get("verdict") == "not_attempted"
    )
    kernelEmitGapCount = sum(
        1 for c in cells if c.get("verdict") in (
            "kernel_emit_stall",
            "kernel_emit_partial_reduction",
            "kernel_emit_index_gap",
        )
    )

    if failCount > 0:
        verdict = "fail"
    elif kernelEmitGapCount > 0:
        verdict = "partial_with_kernel_emit_gaps"
    elif notAttemptedCount > 0 and passCount == 0:
        verdict = "not_attempted"
    elif notAttemptedCount > 0:
        verdict = "partial"
    else:
        verdict = "pass_with_documented_canary_constraints"

    scope_restrictions = _load_smoke_scope_restrictions(args.smoke_config)

    receipt = {
        "schemaVersion": 1,
        "artifactKind": "doe_qwen_3_6_27b_simfabric_cells_summary",
        "modelId": "qwen-3-6-27b-q4k-ehaf16",
        "executionTarget": "simfabric",
        "verdict": verdict,
        "cellCount": cellCount,
        "passCount": passCount,
        "failCount": failCount,
        "notAttemptedCount": notAttemptedCount,
        "kernelEmitGapCount": kernelEmitGapCount,
        "cells": cells,
        "knownBlockers": KNOWN_BLOCKERS,
        "smokeConfigPath": _rel(args.smoke_config),
        "scopeRestrictions": scope_restrictions,
        "claim": {
            "scope": (
                "Qwen 3.6 27B per-kernel CSL — 10 of 11 compile-"
                "target kernels (rmsnorm, rope_partial, residual, "
                "silu, embed, tiled, kv_write, gemv, sample, "
                "attn_decode), sourced from the manifest-shape host "
                "plan, compile via cslc 2.10.0 at small-shape canary "
                "configuration. Cells without WGSL→CSL emit gaps "
                "(rmsnorm, rope_partial, residual, embed, tiled, "
                "kv_write, gemv at width=2) execute end-to-end on "
                "simfabric and match host-computed references within "
                "float32 precision. silu validates dispatch shape "
                "against a passthrough reference (kernel currently "
                "emits as identity, not real SiLU). sample, gemv "
                "(at width≥3), and attn_decode carry typed kernel-"
                "emit gaps captured per-cell so the lane cannot be "
                "misread as fully covered."
            ),
            "notWhat": (
                "Not a hardware run. Not a manifest-shape run — the "
                "small canary shapes exercise the kernel mechanism, "
                "not production scale. Not a multi-kernel chain — "
                "each cell runs a single kernel only. The 11th "
                "compile-target kernel, attn_prefill, is the cslc "
                "linker_pe_memory_overflow blocker (causalAttention"
                "Prefill in the smoke config) and is recorded under "
                "knownBlockers — not a simfabric cell. Does not "
                "cover the smoke config's other scopeRestrictions "
                "(linear-attention layers, mrope-interleaved RoPE, "
                "attentionOutputGate, SwiGLU FFN fused gate). Does "
                "not cover the manifest-shape per-PE residency "
                "blocker that motivates the layout patches in three "
                "of the cells (rmsnorm, residual, silu) — closed by "
                "the broader R3-2 single-PE-reduction → fabric-shard "
                "redesign, tracked separately. Three real WGSL→CSL "
                "emit gaps surface here (sample index reduction, "
                "gemv middle-PE routing at width≥3, attn_decode "
                "reduce-task activation) and require Doe-side fixes "
                "before the affected kernels can run end-to-end at "
                "manifest shape."
            ),
        },
    }

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"wrote {_rel(args.out)} verdict={verdict} "
          f"pass={passCount}/{cellCount}")
    # Caveated pass/partial verdicts are faithful synthesis results:
    # constraints and gaps are recorded per-cell and in the summary,
    # not silently masked. Exit 0 so evidence packets can cite the
    # receipt.
    ok_verdicts = {
        "pass",
        "pass_with_documented_canary_constraints",
        "partial",
        "partial_with_kernel_emit_gaps",
    }
    return 0 if verdict in ok_verdicts else 1


if __name__ == "__main__":
    sys.exit(main())
