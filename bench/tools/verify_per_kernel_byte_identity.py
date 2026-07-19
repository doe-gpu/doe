#!/usr/bin/env python3
"""Verify per-kernel byte identity between two host-plan compile roots (attention-canary precondition).

Mitigates the attention-canary precondition from
docs/cerebras-model-ledgers.md (Manifest-shape simfabric proof plan):

  > The host-plan tool already accepts `--num-layers`; verify in
  > runtime/zig/src/spatial/csl/csl_host_plan_tool.zig that 1-layer emission keeps
  > the per-kernel artifacts identical to the 60-layer emission
  > (kernel CSL is per-class, not per-layer-instance).

The property: per-kernel files emitted under
`<compile_root>/<kernel>/{layout.csl, pe_program.csl,
pe_program.metadata.json}` are byte-identical between two emissions
that differ only in `model_config.numLayers` (or any other parameter
that affects layer count, not kernel identity). A divergence here is
a kernel-emit bug — the kernel CSL would be a function of layer
instance rather than layer class, breaking the 1-layer attention-canary setup.

The tool compares any two compile roots produced by
`doe-csl-host-plan-tool`; it's contract-only and does not invoke the
Zig tool. Receipt:

  - per-kernel sha256 for layout.csl, pe_program.csl,
    pe_program.metadata.json
  - boolean match flags for each artifact
  - aggregate verdict `bound` iff every shared kernel matches

Usage:

  python3 bench/tools/verify_per_kernel_byte_identity.py \\
    --left  bench/out/r3-1-31b-manifest-fullgraph-compile-steps/compile \\
    --right bench/out/r3-1-31b-manifest-fullgraph-compile-1L-steps/compile \\
    --out   bench/out/r3-1-31b-manifest-shape-1L-identity/receipt.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench.tools._receipt_hash_guard import (  # noqa: E402
    ReceiptHashSpineError,
    enforce_receipt_hash_spine,
)


PER_KERNEL_FILES = ("layout.csl", "pe_program.csl", "pe_program.metadata.json")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "--left",
        type=Path,
        required=True,
        help="First compile root (e.g. 60-layer emission).",
    )
    p.add_argument(
        "--right",
        type=Path,
        required=True,
        help="Second compile root (e.g. 1-layer emission).",
    )
    p.add_argument(
        "--out",
        type=Path,
        required=True,
        help="Receipt output path.",
    )
    p.add_argument(
        "--label-left",
        default="left",
        help="Free-form label for the first root (e.g. '48L').",
    )
    p.add_argument(
        "--label-right",
        default="right",
        help="Free-form label for the second root (e.g. '1L').",
    )
    return p.parse_args()


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _try_relative(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def _list_kernels(root: Path) -> set[str]:
    """Kernel dirs are children of `root` that contain at least one
    of the PER_KERNEL_FILES. Drives the comparison without hard-coding
    the kernel list — host plans evolve and we don't want this tool
    rejecting an unfamiliar kernel name out of hand."""
    if not root.is_dir():
        return set()
    out: set[str] = set()
    for entry in root.iterdir():
        if not entry.is_dir():
            continue
        for name in PER_KERNEL_FILES:
            if (entry / name).is_file():
                out.add(entry.name)
                break
    return out


def compare_kernel(
    *,
    name: str,
    left_root: Path,
    right_root: Path,
) -> dict[str, Any]:
    """Compare the three per-kernel files between two compile roots.

    Each artifact records its sha256 on either side and a `match`
    flag. Missing artifacts produce sha256=null on the missing side
    and `match: false`.
    """
    record: dict[str, Any] = {"kernel": name, "artifacts": {}}
    everything_matches = True
    for filename in PER_KERNEL_FILES:
        lp = left_root / name / filename
        rp = right_root / name / filename
        left_hash = _sha256_file(lp) if lp.is_file() else None
        right_hash = _sha256_file(rp) if rp.is_file() else None
        match = (
            left_hash is not None
            and right_hash is not None
            and left_hash == right_hash
        )
        if not match:
            everything_matches = False
        record["artifacts"][filename] = {
            "leftSha256": left_hash,
            "rightSha256": right_hash,
            "match": match,
        }
    record["match"] = everything_matches
    return record


def build_receipt(
    *,
    left_root: Path,
    right_root: Path,
    label_left: str,
    label_right: str,
) -> dict[str, Any]:
    left_kernels = _list_kernels(left_root)
    right_kernels = _list_kernels(right_root)
    shared = sorted(left_kernels & right_kernels)
    left_only = sorted(left_kernels - right_kernels)
    right_only = sorted(right_kernels - left_kernels)

    kernel_records = [
        compare_kernel(
            name=name, left_root=left_root, right_root=right_root
        )
        for name in shared
    ]

    match_count = sum(1 for r in kernel_records if r["match"])
    mismatch_count = len(kernel_records) - match_count

    blocker: str | None = None
    if not shared:
        blocker = "no_shared_kernels"
    elif left_only or right_only:
        blocker = "kernel_set_mismatch"
    elif mismatch_count > 0:
        blocker = "per_kernel_byte_mismatch"

    verdict = "blocked" if blocker else "bound"

    return {
        "schemaVersion": 1,
        "artifactKind": "doe_per_kernel_byte_identity_receipt",
        "receiptClass": "manifest_shape_per_kernel_identity",
        "comparisonMode": "no_oracle",
        "leftCompileRoot": _try_relative(left_root),
        "rightCompileRoot": _try_relative(right_root),
        "leftLabel": label_left,
        "rightLabel": label_right,
        "leftOnlyKernels": left_only,
        "rightOnlyKernels": right_only,
        "kernels": kernel_records,
        "totals": {
            "sharedKernelCount": len(shared),
            "matchCount": match_count,
            "mismatchCount": mismatch_count,
            "leftOnlyCount": len(left_only),
            "rightOnlyCount": len(right_only),
        },
        "verdict": verdict,
        "blocker": blocker,
        "claim": {
            "scope": (
                "Per-kernel byte identity between two host-plan compile "
                "roots. Bound iff every shared kernel emits the same "
                "layout.csl, pe_program.csl, and pe_program.metadata.json "
                "bytes on both sides — the property attention-canary needs so a "
                "1-layer emission can stand in for the 60-layer one when "
                "verifying first-token parity at L=1."
            ),
            "notWhat": (
                "Not a numerical or hardware claim. Does not invoke the "
                "Zig host-plan tool; the caller is responsible for "
                "producing both compile roots from configurations that "
                "differ only in numLayers."
            ),
        },
    }


def main() -> int:
    args = parse_args()
    if not args.left.is_dir():
        sys.stderr.write(
            f"verify_per_kernel_byte_identity: --left {args.left} is "
            "not a directory\n"
        )
        return 2
    if not args.right.is_dir():
        sys.stderr.write(
            f"verify_per_kernel_byte_identity: --right {args.right} is "
            "not a directory\n"
        )
        return 2

    receipt = build_receipt(
        left_root=args.left,
        right_root=args.right,
        label_left=args.label_left,
        label_right=args.label_right,
    )
    try:
        enforce_receipt_hash_spine(receipt, repo_root=REPO_ROOT)
    except ReceiptHashSpineError as err:
        sys.stderr.write(
            f"verify_per_kernel_byte_identity: hash spine rejected: "
            f"{err}\n"
        )
        return 2

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(
        json.dumps(receipt, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(
        f"wrote {args.out} (verdict={receipt['verdict']}, "
        f"shared={receipt['totals']['sharedKernelCount']}, "
        f"match={receipt['totals']['matchCount']}, "
        f"mismatch={receipt['totals']['mismatchCount']})"
    )
    return 0 if receipt["verdict"] == "bound" else 1


if __name__ == "__main__":
    sys.exit(main())
