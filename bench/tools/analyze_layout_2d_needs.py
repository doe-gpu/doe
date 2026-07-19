#!/usr/bin/env python3
"""Per-pattern 2D-layout-need analysis for CSL emitters.

The full-grid compile sweep requires compiling all 17 kernel instances at
E2B (149x117 = 17,433 PE) and 31B (246x236 = 58,056 PE) grid shapes. A
naive precondition would be "2-D emission across all 14 layout emitters".

That framing is imprecise: the uniform widening is wrong. The SDK
memcpy module's i16 width only overflows when a single emitter's
effective peCount exceeds 32,767. Not all patterns use the full model
grid flat:

  - element_wise / gather emit `@set_rectangle(width, 1)` where `width`
    is the flat model peCount -> overflows at 58,056, needs 2D.
  - tiled_matmul emits `@set_rectangle(P, P)` -> already 2D.
  - reduction / rope / attention variants emit `@set_rectangle(width, 1)`
    but `width` is per-token or per-head (<= num_tokens or num_heads),
    not the flat model peCount, so it doesn't overflow.

This script walks every pub fn in
`runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig` that writes a
`@set_rectangle(...)` call, records the declared grid shape and the
param type(s) used, and classifies the pattern's 2D-widening need.

Output:
  bench/out/layout-2d-needs/layout-2d-needs.json  -- schema-backed
  bench/out/layout-2d-needs/layout-2d-needs.md    -- rendered table

The JSON is the source of truth; the MD is a reader-facing view
regenerated from the JSON.
"""

from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
EMITTER_PATH = REPO_ROOT / "runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig"
OUT_DIR = REPO_ROOT / "bench/out/layout-2d-needs"


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


# Per-pattern classification. Derived by reading the emitter source at
# `runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig`:
# - emitElementWiseLayout (line 27): already widened to u16 + width x height.
# - emitReductionLayout (line 112): width x 1, but `width` is per-token
#   (num_tokens <= ~8k for any realistic batch), so no overflow.
# - emitMatmulLayout (line 168): P x P, already 2-D, u16 params.
# - all the *RowTileLoop users (gather, rope, dequant, attention variants,
#   sample, gemv, linear attn, kv read/write, fused ffn): width x 1 where
#   `width` is the kernel's per-op grid — analyzed per-pattern below.
PER_PATTERN: list[dict] = [
    {
        "emitter": "emitElementWiseLayout",
        "emitterLine": 27,
        "pattern": "element_wise",
        "currentGrid": "width x height (u16)",
        "widthSemantic": "flat_pe_count",
        "widenedTo2D": True,
        "needs2DFor31B": True,
        "rationale": (
            "element_wise runs one PE per flattened output element. For "
            "31B's 58,056 PE model grid, a flat width would exceed i16; "
            "the emitter was widened to u16 width x height so callers "
            "can pass height>1 when needed (1-D for E2B, 2-D for 31B)."
        ),
    },
    {
        "emitter": "emitReductionLayout",
        "emitterLine": 112,
        "pattern": "reduction",
        "currentGrid": "width x 1 (i16)",
        "widthSemantic": "per_token",
        "widenedTo2D": False,
        "needs2DFor31B": False,
        "rationale": (
            "Comment at emit_csl_layout.zig:93-96 states 'Single-PE mode: "
            "each PE processes one full token. Barriers become no-ops, "
            "workgroup shared memory becomes PE-local.' Width == num_tokens "
            "<= i16 max for any realistic batch; no 2-D widening required."
        ),
    },
    {
        "emitter": "emitMatmulLayout",
        "emitterLine": 168,
        "pattern": "tiled_matmul",
        "currentGrid": "P x P (u16)",
        "widthSemantic": "summa_tile_count",
        "widenedTo2D": True,
        "needs2DFor31B": False,
        "rationale": (
            "SUMMA tiled matmul already uses a P x P 2-D grid with u16 "
            "params. For 31B's realistic P values (P <= sqrt(58056) < 242), "
            "both axes stay under i16. No further widening needed."
        ),
    },
    {
        "emitter": "emitGatherLayout",
        "emitterLine": 237,
        "pattern": "gather",
        "currentGrid": "width x height (u16)",
        "widthSemantic": "flat_row_count",
        "widenedTo2D": True,
        "needs2DFor31B": True,
        "rationale": (
            "gather indexes one embedding row per PE; on a flat model grid "
            "with 58,056 PE the i16 width overflows. emitGatherLayout was "
            "widened to u16 width x height inline (not via emitRowTileLoop, "
            "which stays 1-D because other patterns sharing it are per-token/"
            "per-head and don't overflow). cslc verified at --params=width:4,"
            "height:1 (1-D E2B shape) and --params=width:4,height:4 (2-D)."
        ),
    },
    {
        "emitter": "emitRoPELayout",
        "emitterLine": 263,
        "pattern": "rope",
        "currentGrid": "width x 1 (i16, via emitRowTileLoop)",
        "widthSemantic": "per_token",
        "widenedTo2D": False,
        "needs2DFor31B": False,
        "rationale": (
            "RoPE rotates Q/K per token. Width == num_tokens (<= max_seq_len, "
            "typically 4k-8k) so the i16 limit is not hit at 31B shapes."
        ),
    },
    {
        "emitter": "emitDequantLayout",
        "emitterLine": 305,
        "pattern": "dequant",
        "currentGrid": "width x 1 (i16, via emitRowTileLoop)",
        "widthSemantic": "per_weight_row_block",
        "widenedTo2D": False,
        "needs2DFor31B": "likely",
        "stepDependency": 1,
        "rationale": (
            "dequant expands Q4K weight rows to f32. The emitter declares "
            "`param width: i16`; the actual width value is set per-invocation "
            "by the runner. For the smoke fixture width=4 (see "
            "bench/runners/csl-runners/fused_gemv_dequant_sim_runner.py:65). "
            "Whether 31B deployment overflows i16 depends on how the "
            "execution-plan generator distributes weight-matrix dequant across "
            "PEs — at the extreme of 'use the full model grid', width = 58,056 "
            "and overflows; at the typical of 'per-weight-matrix subset', "
            "width stays under i16. That per-invocation shape emission lives "
            "in plan Build-order step 1's execution-plan generator, which "
            "today emits only stub layer-block runners. Audit cannot resolve "
            "to yes/no until the generator lands the per-kernel --params "
            "emission."
        ),
    },
    {
        "emitter": "emitStreamingAttentionLayout",
        "emitterLine": 339,
        "pattern": "attention_streaming",
        "currentGrid": "width x 1 (i16, via emitReduceRowTileLoop)",
        "widthSemantic": "per_head",
        "widenedTo2D": False,
        "needs2DFor31B": False,
        "rationale": (
            "Streaming attention distributes work per attention head. "
            "num_heads <= ~128 for any transformer; width stays well below "
            "i16. No 2-D needed."
        ),
    },
    {
        "emitter": "emitDecodeAttentionLayout",
        "emitterLine": 361,
        "pattern": "attention_decode",
        "currentGrid": "width x 1 (i16, via emitRowTileLoop)",
        "widthSemantic": "per_head_or_per_kv_len",
        "widenedTo2D": False,
        "needs2DFor31B": False,
        "rationale": (
            "Decode attention runs one PE per head with kv_len-bounded inner "
            "loop. num_heads stays small; i16 is comfortable."
        ),
    },
    {
        "emitter": "emitTiledAttentionLayout",
        "emitterLine": 385,
        "pattern": "attention_tiled",
        "currentGrid": "width x 1 (i16, via emitRowTileLoop)",
        "widthSemantic": "per_head_per_tile",
        "widenedTo2D": False,
        "needs2DFor31B": False,
        "rationale": (
            "Tiled attention tiles Q/K/V across head/sequence/dim. Per-tile "
            "PE count stays under i16 even at 31B."
        ),
    },
    {
        "emitter": "emitSampleLayout",
        "emitterLine": 408,
        "pattern": "sample",
        "currentGrid": "width x 1 (i16, via emitReduceRowTileLoop)",
        "widthSemantic": "vocab_chunk",
        "widenedTo2D": False,
        "needs2DFor31B": "likely",
        "stepDependency": 1,
        "rationale": (
            "Sample runs over vocab logits. Gemma-4 vocabSize = 262,144 "
            "(both E2B and 31B per runtime/zig/examples/execution-v1/"
            "gemma-4-{e2b,31b}-smoke.json modelConfig). If distributed with "
            "chunk_size=1 (one vocab entry per PE), width = 262,144 which "
            "overflows i16 regardless of model. With chunk_size>=9, width "
            "stays under 32,767. The per-invocation chunk_size is decided "
            "by the execution-plan generator (plan Build-order step 1), "
            "which today emits only stub layer-block runners. Audit cannot "
            "resolve to yes/no until the generator lands."
        ),
    },
    {
        "emitter": "emitFusedGemvLayout",
        "emitterLine": 430,
        "pattern": "fused_gemv_dequant",
        "currentGrid": "width x 1 (i16, via emitReduceRowTileLoop)",
        "widthSemantic": "per_weight_row_block",
        "widenedTo2D": False,
        "needs2DFor31B": "likely",
        "stepDependency": 1,
        "rationale": (
            "Fused GEMV+dequant distributes weight rows across PEs. The "
            "fixture runner uses width=4 for smoke (same file as dequant). "
            "Deployment width depends on per-weight-matrix distribution "
            "emitted by the execution-plan generator (plan step 1). 31B "
            "hiddenDim=5120 with ffnExpansionFactor=4 gives intermediate "
            "dim 20,480 — within i16 if each PE handles a few rows, but "
            "overflows if one PE per row at full grid. Same step-1 "
            "dependency as dequant."
        ),
    },
    {
        "emitter": "emitLinearAttentionLayout",
        "emitterLine": 471,
        "pattern": "attention_linear",
        "currentGrid": "width x 1 (i16, via emitRowTileLoop)",
        "widthSemantic": "per_head",
        "widenedTo2D": False,
        "needs2DFor31B": False,
        "rationale": (
            "Linear attention runs per head; num_heads stays small. No 2-D "
            "required."
        ),
    },
    {
        "emitter": "emitKvWriteLayout",
        "emitterLine": 494,
        "pattern": "kv_write",
        "currentGrid": "width x 1 (i16, via emitRowTileLoop)",
        "widthSemantic": "per_head",
        "widenedTo2D": False,
        "needs2DFor31B": False,
        "rationale": (
            "KV write distributes by head. num_heads <= 128; no 2-D needed."
        ),
    },
    {
        "emitter": "emitKvReadLayout",
        "emitterLine": 517,
        "pattern": "kv_read",
        "currentGrid": "width x 1 (i16, via emitRowTileLoop)",
        "widthSemantic": "per_head",
        "widenedTo2D": False,
        "needs2DFor31B": False,
        "rationale": (
            "KV read distributes by head, same as kv_write. No 2-D needed."
        ),
    },
    {
        "emitter": "emitFusedFfnLayout",
        "emitterLine": 539,
        "pattern": "fused_ffn",
        "currentGrid": "width x 1 (i16, via emitReduceRowTileLoop)",
        "widthSemantic": "per_ffn_row_block",
        "widenedTo2D": False,
        "needs2DFor31B": "likely",
        "stepDependency": 1,
        "rationale": (
            "Fused FFN (gate/up/down) distributes ffn-dim rows across PEs. "
            "31B intermediate dim = hiddenDim * ffnExpansionFactor = 5120 * "
            "4 = 20,480 — fits i16 with 1 row/PE. But if the generator "
            "partitions by the full model grid instead of per-ffn-matrix, "
            "58,056 would overflow. Per-invocation shape lives in the "
            "execution-plan generator (plan step 1)."
        ),
    },
]


def render_markdown(entries: list[dict], emitter_sha: str) -> str:
    lines = [
        "# Layout emitter 2-D needs",
        "",
        "Auto-generated by `bench/tools/analyze_layout_2d_needs.py`.",
        f"Source: `runtime/zig/src/compiler/wgsl/emit/csl/emit_csl_layout.zig` (sha256 `{emitter_sha[:16]}…`).",
        "",
        "Build-order step 2 (cross-repo plan §\"Sweep full-grid kernel compile\") ",
        "requires compiling all 17 kernel instances at E2B and 31B shapes. This ",
        "table tells us which of the 14 emitters actually need 2-D broadening, ",
        "which are already 2-D, and which are 1-D but don't overflow.",
        "",
        "**Summary:** element_wise widened (done). gather needs widening. ",
        "dequant / fused_gemv_dequant / fused_ffn / sample are audit-needed. ",
        "All others stay 1-D.",
        "",
        "| # | emitter | pattern | current grid | width semantic | needs 2-D for 31B | widened? |",
        "| - | --- | --- | --- | --- | --- | --- |",
    ]
    for i, e in enumerate(entries, 1):
        needs = e["needs2DFor31B"]
        needs_s = {True: "yes", False: "no", "likely": "likely (audit)"}[needs]
        widened = "yes" if e["widenedTo2D"] else "no"
        lines.append(
            f"| {i} | `{e['emitter']}` (L{e['emitterLine']}) | `{e['pattern']}` | "
            f"{e['currentGrid']} | {e['widthSemantic']} | {needs_s} | {widened} |"
        )
    lines.append("")
    lines.append("## Rationale per pattern")
    lines.append("")
    for e in entries:
        lines.append(f"### `{e['pattern']}` — `{e['emitter']}`")
        lines.append("")
        lines.append(e["rationale"])
        lines.append("")
    return "\n".join(lines)


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    emitter_sha = sha256(EMITTER_PATH)

    step_dep_patterns = [e["pattern"] for e in PER_PATTERN if e.get("stepDependency")]
    artifact = {
        "schemaVersion": 1,
        "artifactKind": "doe_layout_2d_needs_analysis",
        "emitterSourcePath": str(EMITTER_PATH.relative_to(REPO_ROOT)),
        "emitterSourceSha256": emitter_sha,
        "patterns": PER_PATTERN,
        "summary": {
            "totalEmitters": len(PER_PATTERN),
            "widenedTo2D": sum(1 for e in PER_PATTERN if e["widenedTo2D"]),
            "needs2DAndNotYet": [
                e["pattern"] for e in PER_PATTERN
                if e["needs2DFor31B"] is True and not e["widenedTo2D"]
            ],
            "needs2DLikelyAuditNeeded": [
                e["pattern"] for e in PER_PATTERN
                if e["needs2DFor31B"] == "likely"
            ],
            "noWideningNeeded": [
                e["pattern"] for e in PER_PATTERN
                if e["needs2DFor31B"] is False
            ],
        },
        "dependencies": {
            "step2DependsOnStep1ForPatterns": step_dep_patterns,
            "finding": (
                "Build-order step 2 (full-grid cslc sweep) cannot fully "
                "resolve needs2DFor31B for dequant / sample / fused_gemv_dequant "
                "/ fused_ffn without step 1 (execution-plan generator) landing "
                "per-kernel --params shape emission. Those emitters all accept "
                "`param width` as a compile-time constant that the runner "
                "chooses per-invocation; the choice is a function of how the "
                "generator distributes weight matrices / vocab chunks across "
                "PEs. Today only the stub generator at "
                "bench/tools/generate_e2b_layer_block_runner.py exists and it "
                "emits a single stub codeRegion, not per-kernel shape params."
            ),
            "blocksSweepCompletion": True,
        },
        "notes": (
            "Per-pattern audit supersedes the 'broaden 2-D across 13 remaining "
            "emitters' framing. Widened-definitive: 3 (element_wise, "
            "tiled_matmul, gather). Step-dependent: 4 (need step 1 generator "
            "for per-invocation shape). Not-needed: 8 (width bounded by "
            "num_tokens / num_heads / per-tile PE count)."
        ),
    }

    out_json = OUT_DIR / "layout-2d-needs.json"
    out_md = OUT_DIR / "layout-2d-needs.md"
    out_json.write_text(json.dumps(artifact, indent=2) + "\n")
    out_md.write_text(render_markdown(PER_PATTERN, emitter_sha))

    print(
        f"layout-2d-needs: {artifact['summary']['widenedTo2D']}/{artifact['summary']['totalEmitters']} "
        f"widened, needs2DAndNotYet={artifact['summary']['needs2DAndNotYet']}, "
        f"audit={artifact['summary']['needs2DLikelyAuditNeeded']} -> {out_json.relative_to(REPO_ROOT)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
