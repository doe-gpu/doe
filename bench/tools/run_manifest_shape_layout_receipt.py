#!/usr/bin/env python3
"""Per-kernel manifest-shape layout receipt (layout-receipt).

Mitigates "Layout receipt (layout-receipt)" from
docs/cerebras-model-ledgers.md (Manifest-shape simfabric proof plan):

  > Per kernel, dispatch with manifest-shape inputs; record
  > `inputBytes`, `outputBytes`, `outputDigest`, `dispatchExitCode`,
  > `bufferAlignment`. **No oracle compare.** Failure here is plumbing
  > (stride, layout, axis order), not numerics.

For each compileTarget in the steps-mode host plan, this tool:

  1. Reads `pe_program.metadata.json` to enumerate exports.
  2. Classifies each export as input vs output via
     `OUTPUT_SYMBOL_PATTERNS` (same heuristic
     `bench/tools/predict_simfabric_wallclock.py` already uses).
  3. Synthesizes zero-filled per-PE chunked `.npy` inputs at manifest
     shape, computed from `compile_params` and the export `sizeExpr`.
  4. Spawns `bench/runners/csl-runners/chain_step_adapter.py` under
     `cs_python_singularity.sh` to dispatch the kernel at manifest
     shape (or a hardware target via `--cmaddr`).
  5. Reads output `.npy` files, computes per-symbol sha256, sums input
     and output bytes, hashes the concatenated outputs as
     `outputDigest`.
  6. Emits a per-kernel `doe_manifest_shape_layout_receipt` JSON with
     `receiptClass: manifest_shape_layout`,
     `comparisonMode: no_oracle`, `dispatchExitCode`, and
     `bufferAlignment`. Receipt is gated by the receipt-hash hash spine
     (`bench/tools/_receipt_hash_guard.py`) before write.
  7. Aggregates a `summary.json` covering all kernels.

The receipt has no oracle compare — `outputDigest` is recorded for
audit / diff against future runs but the gate verdict is
`bound` whenever dispatch returned 0 with non-empty output buffers.
A non-zero exit code or unreadable outputs surface as `blocked` with
the typed reason.

Usage:

  python3 bench/tools/run_manifest_shape_layout_receipt.py \\
    --host-plan bench/out/r3-1-31b-manifest-fullgraph-compile-steps/host-plan.json \\
    --compile-root bench/out/r3-1-31b-manifest-fullgraph-compile-steps/compile \\
    --out-dir bench/out/r3-1-31b-manifest-simfabric-layout-receipt
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Callable


REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench.tools._receipt_hash_guard import (  # noqa: E402
    ReceiptHashSpineError,
    enforce_receipt_hash_spine,
)
from bench.tools.predict_simfabric_wallclock import (  # noqa: E402
    SizeExprError,
    evaluate_size_expr,
    inout_symbols_for_kernel,
    output_symbols_for_kernel,
)


CS_PYTHON_SINGULARITY = (
    REPO_ROOT / "runtime/zig/tools/cs_python_singularity.sh"
)
CHAIN_STEP_ADAPTER = (
    REPO_ROOT / "bench/runners/csl-runners/chain_step_adapter.py"
)
DEFAULT_HOST_PLAN = (
    REPO_ROOT
    / "bench/out/r3-1-31b-manifest-fullgraph-compile-steps/host-plan.json"
)
DEFAULT_COMPILE_ROOT = (
    REPO_ROOT
    / "bench/out/r3-1-31b-manifest-fullgraph-compile-steps/compile"
)
DEFAULT_OUT_DIR = (
    REPO_ROOT
    / "bench/out/r3-1-31b-manifest-simfabric-layout-receipt"
)

ELEM_BYTES: dict[str, int] = {
    "f32": 4,
    "u32": 4,
    "i32": 4,
    "f16": 2,
    "u16": 2,
    "i16": 2,
    "u8": 1,
    "i8": 1,
}


class LayoutReceiptError(RuntimeError):
    """Raised for tool-level errors that produce a blocked receipt."""


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--host-plan", type=Path, default=DEFAULT_HOST_PLAN)
    p.add_argument("--compile-root", type=Path, default=DEFAULT_COMPILE_ROOT)
    p.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    p.add_argument(
        "--kernel",
        action="append",
        default=None,
        help=(
            "Restrict the run to one or more named kernels. May be "
            "repeated. Default: every entry in compileTargets."
        ),
    )
    p.add_argument(
        "--cmaddr",
        default="",
        help=(
            "Optional CM endpoint for hardware dispatch. Empty (default) "
            "runs against simfabric."
        ),
    )
    p.add_argument(
        "--timeout-seconds",
        type=int,
        default=600,
        help="Per-kernel subprocess timeout.",
    )
    p.add_argument(
        "--cs-python",
        type=Path,
        default=CS_PYTHON_SINGULARITY,
    )
    p.add_argument(
        "--adapter",
        type=Path,
        default=CHAIN_STEP_ADAPTER,
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help=(
            "Synthesize inputs and assemble the dispatch command but do "
            "not spawn cs_python. Receipt records "
            "verdict=blocked,blocker=dry_run."
        ),
    )
    return p.parse_args()


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


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


def classify_exports(
    exports: list[dict[str, Any]],
    *,
    kernel_name: str | None = None,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Partition exports into (inputs, outputs).

    Outputs are detected through predicted-wallclock's shared symbol classifier.
    Bidirectional symbols are treated as outputs — the layout receipt's
    point is that buffers move bytes; reading zero-filled state in is
    still valid plumbing.
    """
    inputs: list[dict[str, Any]] = []
    outputs: list[dict[str, Any]] = []
    output_symbols = output_symbols_for_kernel(kernel_name)
    inout_symbols = inout_symbols_for_kernel(kernel_name)
    for export in exports:
        symbol = export.get("symbol")
        if symbol in inout_symbols:
            inputs.append(export)
            outputs.append(export)
            continue
        if symbol in output_symbols:
            outputs.append(export)
        else:
            inputs.append(export)
    return inputs, outputs


def _evaluate_chunk(
    export: dict[str, Any],
    bindings: dict[str, int],
) -> int | None:
    expr = export.get("sizeExpr", "")
    try:
        return int(evaluate_size_expr(expr, bindings))
    except SizeExprError:
        return None


def _elem_bytes(export: dict[str, Any]) -> int:
    return ELEM_BYTES.get(export.get("elemType", "f32"), 4)


def synthesize_zero_input(
    *,
    target_path: Path,
    pe_count: int,
    per_pe_chunk: int,
    elem_type: str,
) -> int:
    """Write a zero-filled `.npy` of shape (pe_count * per_pe_chunk,)
    in the elem_type's numpy dtype. Returns the byte length.

    numpy is imported lazily so the module stays importable in
    environments that lack it (the gate-side receipt builder is pure
    JSON).
    """
    import numpy as np  # local import keeps top-level lightweight

    dtype_map = {
        "f32": np.float32,
        "u32": np.uint32,
        "i32": np.int32,
        "f16": np.float16,
        "u16": np.uint16,
        "i16": np.int16,
        "u8": np.uint8,
        "i8": np.int8,
    }
    dtype = dtype_map.get(elem_type, np.float32)
    arr = np.zeros(pe_count * per_pe_chunk, dtype=dtype)
    target_path.parent.mkdir(parents=True, exist_ok=True)
    np.save(target_path, arr)
    return target_path.stat().st_size


def _adapter_dtype_token(elem_type: str) -> str:
    """The chain_step_adapter only accepts f32 / u32 today. Map other
    32-bit dtypes to their adapter token; refuse <32-bit dtypes."""
    if elem_type in ("f32", "u32"):
        return elem_type
    if elem_type == "i32":
        return "u32"
    raise LayoutReceiptError(
        f"chain_step_adapter does not support elemType {elem_type!r} yet "
        "(only f32 and u32 are wired). Manifest-shape kernels using "
        "f16/i16/etc need a follow-up to widen the adapter dtype map."
    )


def build_dispatch_command(
    *,
    cs_python: Path,
    adapter: Path,
    compile_dir: Path,
    width: int,
    height: int,
    chunk_size: int,
    input_specs: list[str],
    output_specs: list[str],
    cmaddr: str,
) -> list[str]:
    cmd: list[str] = [
        str(cs_python),
        str(adapter),
        "--compile-dir",
        str(compile_dir),
        "--width",
        str(width),
        "--height",
        str(height),
        "--chunk-size",
        str(chunk_size),
    ]
    for spec in input_specs:
        cmd.extend(["--input", spec])
    for spec in output_specs:
        cmd.extend(["--output", spec])
    if cmaddr:
        cmd.extend(["--cmaddr", cmaddr])
    return cmd


def run_dispatch_subprocess(
    command: list[str],
    *,
    timeout_seconds: int,
    env: dict[str, str] | None = None,
) -> tuple[int, str, str, bool]:
    """Spawn the dispatch command. Returns (exit_code, stdout, stderr, timed_out).

    Factored out so tests can swap a stub.
    """
    try:
        proc = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=None if timeout_seconds <= 0 else timeout_seconds,
            env=env or os.environ.copy(),
            cwd=str(REPO_ROOT),
        )
    except subprocess.TimeoutExpired as err:
        return (
            -1,
            (err.stdout or "") if isinstance(err.stdout, str) else "",
            (err.stderr or "") if isinstance(err.stderr, str) else "",
            True,
        )
    return proc.returncode, proc.stdout, proc.stderr, False


def _tail(text: str, lines: int = 20) -> list[str]:
    return text.splitlines()[-lines:] if text else []


def build_kernel_receipt(
    *,
    kernel: str,
    compile_dir: Path,
    compile_params: dict[str, int],
    inputs: list[dict[str, Any]],
    outputs: list[dict[str, Any]],
    dispatch_command: list[str],
    dispatch_exit_code: int | None,
    dispatch_stdout: str,
    dispatch_stderr: str,
    dispatch_timed_out: bool,
    host_plan_path: Path,
    host_plan_hash: str,
    cmaddr: str,
    blocker: str | None,
) -> dict[str, Any]:
    """Assemble a per-kernel receipt body.

    The function takes already-realized per-symbol records (inputs and
    outputs) — building the records is the caller's job because in
    test contexts the dispatch might be stubbed and `outputs[i].sha256`
    must match whatever the stub wrote.
    """
    total_input_bytes = sum(int(item.get("totalBytes", 0)) for item in inputs)
    total_output_bytes = sum(int(item.get("totalBytes", 0)) for item in outputs)

    aggregate = hashlib.sha256()
    for item in outputs:
        digest_hex = item.get("sha256")
        if isinstance(digest_hex, str) and digest_hex:
            aggregate.update(digest_hex.encode("ascii"))
    output_digest = aggregate.hexdigest() if outputs else ""

    if blocker is None:
        if dispatch_exit_code != 0 or dispatch_timed_out:
            blocker = (
                "dispatch_timed_out"
                if dispatch_timed_out
                else f"dispatch_exit_code_{dispatch_exit_code}"
            )
        elif total_output_bytes == 0 and outputs:
            blocker = "outputs_empty_after_dispatch"

    verdict = "blocked" if blocker else "bound"

    receipt: dict[str, Any] = {
        "schemaVersion": 1,
        "artifactKind": "doe_manifest_shape_layout_receipt",
        "receiptClass": "manifest_shape_layout",
        "comparisonMode": "no_oracle",
        "kernel": kernel,
        "compileDir": _try_relative(compile_dir),
        "compileParams": dict(compile_params),
        "hostPlanPath": _try_relative(host_plan_path),
        "hostPlanHash": host_plan_hash,
        "cmaddr": cmaddr or "",
        "executionTarget": "system" if cmaddr else "simfabric",
        "inputs": list(inputs),
        "outputs": list(outputs),
        "totalInputBytes": total_input_bytes,
        "totalOutputBytes": total_output_bytes,
        "outputDigest": output_digest,
        "dispatchExitCode": dispatch_exit_code,
        "dispatchTimedOut": dispatch_timed_out,
        "bufferAlignment": _output_alignment(outputs),
        "subprocess": {
            "command": list(dispatch_command),
            "stdoutTail": _tail(dispatch_stdout),
            "stderrTail": _tail(dispatch_stderr),
        },
        "verdict": verdict,
        "blocker": blocker,
        "claim": {
            "scope": (
                "Per-kernel manifest-shape dispatch with zero-filled "
                "inputs; records bytes-in / bytes-out, output digest, "
                "dispatch exit code, and buffer alignment. No oracle "
                "compare — failure isolates plumbing (stride, layout, "
                "axis order) from numerics."
            ),
            "notWhat": (
                "Not a parity claim and not a numerical correctness "
                "claim. Output digests are zero-input-deterministic "
                "given a stable kernel; per-kernel manifest-shape produces the per-kernel "
                "Doppler-probe parity claim, attention-canary+ binds parity to "
                "the frozen reference fixture."
            ),
        },
    }
    return receipt


def _output_alignment(outputs: list[dict[str, Any]]) -> int:
    """Worst-case (smallest) byte alignment across the output buffers.

    The chain_step_adapter writes 32-bit packed buffers (MEMCPY_32BIT),
    so 32-bit elements are naturally 4-byte aligned. When the adapter
    grows to support 16-bit dtypes, the alignment per output reflects
    that; until then this is uniform across outputs.
    """
    if not outputs:
        return 0
    return min(int(item.get("elemBytes", 4)) for item in outputs)


def _materialize_inputs(
    *,
    kernel: str,
    target: dict[str, Any],
    metadata: dict[str, Any],
    scratch_dir: Path,
) -> tuple[
    list[dict[str, Any]],
    list[dict[str, Any]],
    list[str],
    list[str],
    int,
]:
    """Write zero inputs and prepare output paths.

    Returns (input_records, output_records, input_specs, output_specs,
    chunk_size_default).
    """
    bindings = dict(target.get("compileParams") or {})
    width = int(bindings.get("width") or 0)
    height = int(bindings.get("height") or 1)
    pe_count = max(1, width * height)
    inputs_meta, outputs_meta = classify_exports(
        list(metadata.get("exports") or []),
        kernel_name=kernel,
    )

    input_records: list[dict[str, Any]] = []
    output_records: list[dict[str, Any]] = []
    input_specs: list[str] = []
    output_specs: list[str] = []

    chunk_size_default = 0
    for export in inputs_meta:
        chunk = _evaluate_chunk(export, bindings)
        if chunk is None:
            raise LayoutReceiptError(
                f"kernel {kernel!r}: unable to evaluate sizeExpr for input "
                f"symbol {export.get('symbol')!r}"
            )
        if chunk_size_default == 0:
            chunk_size_default = chunk
        elem_type = export.get("elemType", "f32")
        elem_bytes = _elem_bytes(export)
        symbol = export.get("symbol", "")
        path = scratch_dir / "in" / f"{symbol}.npy"
        synthesize_zero_input(
            target_path=path,
            pe_count=pe_count,
            per_pe_chunk=chunk,
            elem_type=elem_type,
        )
        sha = _sha256_file(path)
        total_elems = pe_count * chunk
        input_records.append(
            {
                "symbol": symbol,
                "path": _try_relative(path),
                "elemType": elem_type,
                "elemBytes": elem_bytes,
                "perPeChunk": chunk,
                "totalElements": total_elems,
                "totalBytes": total_elems * elem_bytes,
                "sha256": sha,
            }
        )
        adapter_dtype = _adapter_dtype_token(elem_type)
        input_specs.append(
            f"{symbol}:{path}:{adapter_dtype}:{chunk}"
        )

    for export in outputs_meta:
        chunk = _evaluate_chunk(export, bindings)
        if chunk is None:
            raise LayoutReceiptError(
                f"kernel {kernel!r}: unable to evaluate sizeExpr for output "
                f"symbol {export.get('symbol')!r}"
            )
        if chunk_size_default == 0:
            chunk_size_default = chunk
        elem_type = export.get("elemType", "f32")
        elem_bytes = _elem_bytes(export)
        symbol = export.get("symbol", "")
        path = scratch_dir / "out" / f"{symbol}.npy"
        path.parent.mkdir(parents=True, exist_ok=True)
        total_elems = pe_count * chunk
        output_records.append(
            {
                "symbol": symbol,
                "path": _try_relative(path),
                "elemType": elem_type,
                "elemBytes": elem_bytes,
                "perPeChunk": chunk,
                "totalElements": total_elems,
                "totalBytes": 0,  # filled in after dispatch
                "sha256": "",
                "absolutePath": str(path),  # for post-dispatch hashing
            }
        )
        adapter_dtype = _adapter_dtype_token(elem_type)
        output_specs.append(
            f"{symbol}:{path}:{adapter_dtype}:{chunk}"
        )

    return (
        input_records,
        output_records,
        input_specs,
        output_specs,
        chunk_size_default or 1,
    )


def _hash_output_files(
    output_records: list[dict[str, Any]],
) -> None:
    """After dispatch, fill totalBytes + sha256 for each output record by
    hashing the file the adapter wrote."""
    for record in output_records:
        path = Path(record.pop("absolutePath", record["path"]))
        if not path.is_file():
            record["totalBytes"] = 0
            record["sha256"] = ""
            continue
        record["totalBytes"] = path.stat().st_size
        record["sha256"] = _sha256_file(path)


def _metadata_path_for_kernel(*, kernel: str, source_root: Path) -> Path:
    candidates = [
        source_root / kernel / "pe_program.metadata.json",
        source_root / "compile" / kernel / "pe_program.metadata.json",
        source_root / "compiled" / kernel / "pe_program.metadata.json",
    ]
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    return candidates[0]


def run_one_kernel(
    *,
    kernel: str,
    target: dict[str, Any],
    compile_root: Path,
    host_plan_path: Path,
    host_plan_hash: str,
    out_dir: Path,
    cmaddr: str,
    timeout_seconds: int,
    cs_python: Path,
    adapter: Path,
    dry_run: bool,
    dispatcher: Callable[..., tuple[int, str, str, bool]] | None = None,
) -> dict[str, Any]:
    """Run layout-receipt for a single kernel; returns the receipt body.

    `dispatcher` lets tests substitute a stub for run_dispatch_subprocess.
    """
    effective_source_root = (
        compile_root.parent
        if compile_root.name == "compiled"
        else compile_root
    )
    metadata_path = _metadata_path_for_kernel(
        kernel=kernel,
        source_root=effective_source_root,
    )
    if not metadata_path.is_file():
        raise LayoutReceiptError(
            f"kernel {kernel!r}: pe_program.metadata.json absent at "
            f"{metadata_path}"
        )
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    compile_params = {
        str(k): int(v)
        for k, v in (target.get("compileParams") or {}).items()
    }
    width = int(compile_params.get("width") or 0)
    height = int(compile_params.get("height") or 1)

    scratch_dir = out_dir / "scratch" / kernel
    scratch_dir.mkdir(parents=True, exist_ok=True)

    blocker: str | None = None
    try:
        (
            input_records,
            output_records,
            input_specs,
            output_specs,
            chunk_default,
        ) = _materialize_inputs(
            kernel=kernel,
            target=target,
            metadata=metadata,
            scratch_dir=scratch_dir,
        )
    except LayoutReceiptError as err:
        return build_kernel_receipt(
            kernel=kernel,
            compile_dir=compile_root / kernel,
            compile_params=compile_params,
            inputs=[],
            outputs=[],
            dispatch_command=[],
            dispatch_exit_code=None,
            dispatch_stdout="",
            dispatch_stderr=str(err),
            dispatch_timed_out=False,
            host_plan_path=host_plan_path,
            host_plan_hash=host_plan_hash,
            cmaddr=cmaddr,
            blocker=f"input_synthesis_failed: {err}",
        )

    compile_dir = compile_root / kernel
    command = build_dispatch_command(
        cs_python=cs_python,
        adapter=adapter,
        compile_dir=compile_dir,
        width=width,
        height=height,
        chunk_size=chunk_default,
        input_specs=input_specs,
        output_specs=output_specs,
        cmaddr=cmaddr,
    )

    if dry_run:
        # Strip the `absolutePath` helper field before emitting.
        for record in output_records:
            record.pop("absolutePath", None)
        return build_kernel_receipt(
            kernel=kernel,
            compile_dir=compile_dir,
            compile_params=compile_params,
            inputs=input_records,
            outputs=output_records,
            dispatch_command=command,
            dispatch_exit_code=None,
            dispatch_stdout="",
            dispatch_stderr="",
            dispatch_timed_out=False,
            host_plan_path=host_plan_path,
            host_plan_hash=host_plan_hash,
            cmaddr=cmaddr,
            blocker="dry_run",
        )

    if not cs_python.is_file():
        blocker = f"cs_python_unavailable: {cs_python}"
    elif not adapter.is_file():
        blocker = f"chain_step_adapter_missing: {adapter}"
    elif not (compile_dir / "bin").is_dir():
        blocker = f"compile_bin_missing: {compile_dir}/bin"

    if blocker is not None:
        for record in output_records:
            record.pop("absolutePath", None)
        return build_kernel_receipt(
            kernel=kernel,
            compile_dir=compile_dir,
            compile_params=compile_params,
            inputs=input_records,
            outputs=output_records,
            dispatch_command=command,
            dispatch_exit_code=None,
            dispatch_stdout="",
            dispatch_stderr="",
            dispatch_timed_out=False,
            host_plan_path=host_plan_path,
            host_plan_hash=host_plan_hash,
            cmaddr=cmaddr,
            blocker=blocker,
        )

    runner = dispatcher or run_dispatch_subprocess
    exit_code, stdout, stderr, timed_out = runner(
        command, timeout_seconds=timeout_seconds
    )

    _hash_output_files(output_records)

    return build_kernel_receipt(
        kernel=kernel,
        compile_dir=compile_dir,
        compile_params=compile_params,
        inputs=input_records,
        outputs=output_records,
        dispatch_command=command,
        dispatch_exit_code=exit_code,
        dispatch_stdout=stdout,
        dispatch_stderr=stderr,
        dispatch_timed_out=timed_out,
        host_plan_path=host_plan_path,
        host_plan_hash=host_plan_hash,
        cmaddr=cmaddr,
        blocker=None,
    )


def write_kernel_receipt(
    *,
    receipt: dict[str, Any],
    out_dir: Path,
) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    enforce_receipt_hash_spine(receipt, repo_root=REPO_ROOT)
    path = out_dir / f"{receipt['kernel']}.json"
    path.write_text(
        json.dumps(receipt, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return path


def write_summary(
    *,
    out_dir: Path,
    receipts: list[dict[str, Any]],
    host_plan_path: Path,
    host_plan_hash: str,
) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    summary = {
        "schemaVersion": 1,
        "artifactKind": "doe_manifest_shape_layout_summary",
        "receiptClass": "manifest_shape_layout_summary",
        "hostPlanPath": _try_relative(host_plan_path),
        "hostPlanHash": host_plan_hash,
        "kernels": [
            {
                "kernel": r["kernel"],
                "verdict": r["verdict"],
                "blocker": r["blocker"],
                "dispatchExitCode": r["dispatchExitCode"],
                "totalInputBytes": r["totalInputBytes"],
                "totalOutputBytes": r["totalOutputBytes"],
                "outputDigest": r["outputDigest"],
            }
            for r in receipts
        ],
        "totals": {
            "kernelCount": len(receipts),
            "boundCount": sum(1 for r in receipts if r["verdict"] == "bound"),
            "blockedCount": sum(
                1 for r in receipts if r["verdict"] == "blocked"
            ),
        },
    }
    enforce_receipt_hash_spine(summary, repo_root=REPO_ROOT)
    path = out_dir / "summary.json"
    path.write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return path


def main() -> int:
    args = parse_args()
    if not args.host_plan.is_file():
        sys.stderr.write(
            f"run_manifest_shape_layout_receipt: host-plan absent at "
            f"{args.host_plan}\n"
        )
        return 2
    host_plan = json.loads(args.host_plan.read_text(encoding="utf-8"))
    host_plan_hash = _sha256_file(args.host_plan)
    targets = host_plan.get("compileTargets") or []
    if args.kernel:
        kernel_filter = set(args.kernel)
        targets = [t for t in targets if t.get("name") in kernel_filter]
        if not targets:
            sys.stderr.write(
                f"run_manifest_shape_layout_receipt: no targets matched "
                f"--kernel filter {sorted(kernel_filter)!r}\n"
            )
            return 2

    receipts: list[dict[str, Any]] = []
    blocked_count = 0
    for target in targets:
        kernel = str(target.get("name") or "")
        if not kernel:
            continue
        try:
            receipt = run_one_kernel(
                kernel=kernel,
                target=target,
                compile_root=args.compile_root,
                host_plan_path=args.host_plan,
                host_plan_hash=host_plan_hash,
                out_dir=args.out_dir,
                cmaddr=args.cmaddr,
                timeout_seconds=args.timeout_seconds,
                cs_python=args.cs_python,
                adapter=args.adapter,
                dry_run=args.dry_run,
            )
        except LayoutReceiptError as err:
            receipt = build_kernel_receipt(
                kernel=kernel,
                compile_dir=args.compile_root / kernel,
                compile_params={
                    str(k): int(v)
                    for k, v in (target.get("compileParams") or {}).items()
                },
                inputs=[],
                outputs=[],
                dispatch_command=[],
                dispatch_exit_code=None,
                dispatch_stdout="",
                dispatch_stderr=str(err),
                dispatch_timed_out=False,
                host_plan_path=args.host_plan,
                host_plan_hash=host_plan_hash,
                cmaddr=args.cmaddr,
                blocker=f"runtime_error: {err}",
            )
        try:
            write_kernel_receipt(receipt=receipt, out_dir=args.out_dir)
        except ReceiptHashSpineError as err:
            sys.stderr.write(
                f"run_manifest_shape_layout_receipt: kernel {kernel!r} "
                f"hash spine rejected emit: {err}\n"
            )
            return 2
        receipts.append(receipt)
        if receipt["verdict"] == "blocked":
            blocked_count += 1

    try:
        write_summary(
            out_dir=args.out_dir,
            receipts=receipts,
            host_plan_path=args.host_plan,
            host_plan_hash=host_plan_hash,
        )
    except ReceiptHashSpineError as err:
        sys.stderr.write(
            f"run_manifest_shape_layout_receipt: summary hash spine "
            f"rejected emit: {err}\n"
        )
        return 2

    print(
        f"wrote {len(receipts)} kernel receipt(s) to {args.out_dir} "
        f"(blocked={blocked_count})"
    )
    return 1 if blocked_count else 0


if __name__ == "__main__":
    sys.exit(main())
