#!/usr/bin/env python3
"""Trace-to-Countermodel Emitter for Lean 4 formal verification.

Converts physical GPU execution divergences, bounds faults, and
out-of-bounds trace records into executable Lean 4 counterexample theorems.

When an execution trace records an out-of-bounds access or precondition breach,
this tool produces a deterministic Lean fixture proving that the access violates
the safety invariant:
    ¬ (evalIndex expr < arrayLength)
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any, Dict, Optional


def sanitize_identifier(name: str) -> str:
    """Produce a valid Lean 4 identifier from a trace or workload name."""
    clean = re.sub(r"[^a-zA-Z0-9_]", "_", name)
    if clean and clean[0].isdigit():
        clean = f"trace_{clean}"
    return clean or "trace_divergence"


def format_lean_countermodel(
    trace_id: str,
    event: Dict[str, Any],
    *,
    theorem_name: Optional[str] = None,
) -> str:
    """Generate a Lean 4 counterexample file from a trace divergence event.

    Supported event kinds:
      - 1d_storage_bounds: single-dimension gid access exceeding buffer length
      - strided_affine_bounds: gid * stride + offset exceeding buffer length
      - loop_affine_bounds: gid * gid_stride + i * loop_stride + offset exceeding buffer length
    """
    ident = sanitize_identifier(theorem_name or f"counterexample_{trace_id}")
    kind = event.get("kind", "1d_storage_bounds")

    wid = int(event.get("workgroupId", 0))
    lid = int(event.get("localId", 0))
    ws = int(event.get("workgroupSize", 1))
    nwg = int(event.get("numWorkgroups", 1))
    buf_len = int(event.get("bufferLength", 0))

    lines = [
        f"-- Auto-generated counterexample fixture from trace: {trace_id}",
        "-- Proves that the recorded dispatch parameters violate the safety bound.",
        "import Doe.Shader.ComputeBounds",
        "import Doe.Shader.Tactics",
        "",
    ]

    if kind == "1d_storage_bounds":
        lines.extend([
            f"/-- Counterexample witness for trace `{trace_id}`.",
            "    Evaluates to false, proving the dispatch produces an out-of-bounds index. -/",
            f"theorem {ident}_violates_bound :",
            f"    ¬ (globalInvocationId {wid} {lid} {ws} < {buf_len}) := by",
            "  unfold globalInvocationId",
            "  decide",
            "",
        ])
    elif kind == "strided_affine_bounds":
        stride = int(event.get("stride", 1))
        offset = int(event.get("offset", 0))
        lines.extend([
            f"/-- Counterexample witness for strided affine trace `{trace_id}`. -/",
            f"theorem {ident}_violates_bound :",
            f"    ¬ (globalInvocationId {wid} {lid} {ws} * {stride} + {offset} < {buf_len}) := by",
            "  unfold globalInvocationId",
            "  decide",
            "",
        ])
    elif kind == "loop_affine_bounds":
        gid_stride = int(event.get("gidStride", 1))
        loop_stride = int(event.get("loopStride", 1))
        loop_idx = int(event.get("loopIndex", 0))
        offset = int(event.get("offset", 0))
        lines.extend([
            f"/-- Counterexample witness for loop-affine trace `{trace_id}`. -/",
            f"theorem {ident}_violates_bound :",
            f"    ¬ (globalInvocationId {wid} {lid} {ws} * {gid_stride} + {loop_idx} * {loop_stride} + {offset} < {buf_len}) := by",
            "  unfold globalInvocationId",
            "  decide",
            "",
        ])
    else:
        # Fallback raw arithmetic assertion
        idx_val = int(event.get("computedIndex", (wid * ws + lid)))
        lines.extend([
            f"/-- Generic counterexample witness for trace `{trace_id}`. -/",
            f"theorem {ident}_violates_bound :",
            f"    ¬ ({idx_val} < {buf_len}) := by",
            "  decide",
            "",
        ])

    return "\n".join(lines)


def emit_countermodel_from_file(input_path: Path, output_path: Path) -> str:
    """Read a trace divergence JSON file and write the corresponding Lean 4 fixture."""
    data = json.loads(input_path.read_text(encoding="utf-8"))
    trace_id = data.get("traceId") or data.get("id") or input_path.stem
    content = format_lean_countermodel(trace_id, data)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(content, encoding="utf-8")
    return content


def main() -> int:
    parser = argparse.ArgumentParser(description="Emit Lean 4 countermodel from trace divergence record.")
    parser.add_argument("--input", "-i", type=Path, required=True, help="Input trace divergence JSON file")
    parser.add_argument("--output", "-o", type=Path, required=True, help="Output .lean countermodel fixture file")
    args = parser.parse_args()

    if not args.input.is_file():
        print(f"Error: input file not found: {args.input}", file=sys.stderr)
        return 1

    emit_countermodel_from_file(args.input, args.output)
    print(f"Emitted Lean countermodel fixture: {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
