#!/usr/bin/env python3
"""Per-kernel manifest-shape dispatch runner with Doppler-probe inputs.

Mitigates "Per-kernel manifest-shape dispatch" from
docs/cerebras-model-ledgers.md (Manifest-shape simfabric proof plan):

  > Extend bench/runners/csl-runners/multi_token_decode_orchestrator.py
  > (or a new sibling manifest_kernel_probe_runner.py) to dispatch one
  > kernel at manifest shape with manifest-shape inputs, against
  > per-kernel Doppler probes from
  > bench/fixtures/tsir-real-doppler-transcripts/. Receipt:
  > bench/out/r3-1-31b-manifest-simfabric-per-kernel/<kernel>.json.

Differences from the layout-receipt step (`bench/tools/run_manifest_shape_layout_receipt.py`):

  - Inputs come from the per-kernel Doppler probe transcripts and the
    bootstrap input fixtures they cite (not zero-filled). The probe
    values are tiled/broadcast across the manifest-shape buffer; the
    receipt records the broadcast strategy + probe identity.
  - Receipt is `doe_manifest_shape_per_kernel_dispatch_receipt`,
    `receiptClass: manifest_shape_per_kernel_dispatch`.
  - Records `dispatchWallclockNs` so callers can derive the
    predicted-wallclock throughput calibration constant (`bytesPerCycle` =
    grandTotalOutputBytes / dispatchWallclockNs * cycles_per_ns).

Comparison to a Doppler reference oracle is **not** done here — that's
the attention-canary, full-prefill, and multi-token continuation steps
(parity steps against the frozen-Doppler reference fixture behind
`bench/tools/validate_frozen_doppler_reference.py`). This step's purpose
is calibration + per-kernel dispatch plumbing with non-zero inputs.

Usage:

  python3 bench/runners/csl-runners/manifest_kernel_probe_runner.py \\
    --host-plan bench/out/r3-1-31b-manifest-fullgraph-compile-steps/host-plan.json \\
    --compile-root bench/out/r3-1-31b-manifest-fullgraph-compile-steps/compile \\
    --probe-dir bench/fixtures/tsir-real-doppler-transcripts \\
    --out-dir bench/out/r3-1-31b-manifest-simfabric-per-kernel
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
import re
import sys
import time
from pathlib import Path
from typing import Any, Callable


REPO_ROOT = Path(__file__).resolve().parents[3]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))
RUNNER_DIR = Path(__file__).resolve().parent
if str(RUNNER_DIR) not in sys.path:
    sys.path.insert(0, str(RUNNER_DIR))

from bench.tools._receipt_hash_guard import (  # noqa: E402
    ReceiptHashSpineError,
    enforce_receipt_hash_spine,
)
from bench.tools.predict_simfabric_wallclock import (  # noqa: E402
    SizeExprError,
    evaluate_size_expr,
)
from bench.tools.run_manifest_shape_layout_receipt import (  # noqa: E402
    ELEM_BYTES,
    LayoutReceiptError,
    build_dispatch_command,
    classify_exports,
    run_dispatch_subprocess,
)
from manifest_dense_gemv_tiles import (  # noqa: E402
    is_safe_tile_shape,
    max_safe_tile_width,
    run_dense_gemv_row_tiled,
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
DEFAULT_PROBE_DIR = (
    REPO_ROOT / "bench/fixtures/tsir-real-doppler-transcripts"
)
DEFAULT_OUT_DIR = (
    REPO_ROOT
    / "bench/out/r3-1-31b-manifest-simfabric-per-kernel"
)

PROBE_TRANSCRIPT_ALIASES = {
    "attn_decode_sliding": "attn_decode",
    "gelu_decode": "gelu",
    "gelu_prefill": "gelu",
    "kv_write_shared": "kv_write",
    "lm_head_gemv": "lm_head_gemv",
    "lm_head_prefill": "lm_head_gemv",
    "o_gate": "silu_gated",
    "ple_proj": "tiled",
    "ple_rmsnorm": "rmsnorm",
    "residual_decode": "residual",
    "residual_prefill": "residual",
    "rmsnorm_decode": "rmsnorm",
    "rmsnorm_prefill": "rmsnorm",
}

ZERO_DEFAULT_H2D_INPUTS_BY_KERNEL = {
    "lm_head_gemv": {"activation", "weight"},
    "lm_head_prefill": {"activation", "weight"},
}

DENSE_GEMV_SINK_OUTPUT_KERNELS = {
    "lm_head_gemv",
    "lm_head_prefill",
}
DIRECT_DISPATCH_MODE = "monolithic_full_fabric"
SINGLE_REGION_D2H_MODE = "single_region_copyback"
ROW_SPLIT_D2H_MODE = "row_split_copyback"
LM_HEAD_DIRECT_EVIDENCE_SCOPE = "manifest_shape_direct_dispatch"
LM_HEAD_WIDTH_TILED_EVIDENCE_SCOPE = "full_vocab_host_reduced_width_row_tiles"
LM_HEAD_ROW_TILED_EVIDENCE_SCOPE = "full_vocab_row_tiled_direct_width"
RESIDENCY_WEIGHT_PAYLOAD_MIN_BYTES = 1

_LAYOUT_PARAM_DEFAULT_RE = re.compile(
    r"\bparam\s+([A-Za-z_][A-Za-z0-9_]*)\s*:[^=;]+=\s*([0-9]+)\s*;"
)
_COMPILED_ELF_RE = re.compile(r"out_([0-9]+)_([0-9]+)\.elf$")
_PHASE_LINE_RE = re.compile(r"^phase:([^\s]+)(?:\s+(.*))?$")
_KERNEL_VARIANT_SUFFIX_RE = re.compile(
    r"("
    r"_decode$|"
    r"_prefill$|"
    r"_width_tile_x\d+_w\d+$|"
    r"_width_tile_x\d+_w\d+_h\d+$|"
    r"_width\d+_h\d+$|"
    r"_width\d+_w\d+$|"
    r"_width\d+_w\d+_h\d+$|"
    r"_row_tile_w\d+_h\d+$|"
    r"_row_tile_h\d+$"
    r")"
)


def _kernel_source_candidates(*, kernel: str) -> list[str]:
    """Yield kernel names to try when locating source metadata/layout."""
    names: list[str] = [kernel]
    seen = {kernel}
    queue = [kernel]
    while queue:
        current = queue.pop()
        for variant in _KERNEL_VARIANT_SUFFIX_RE.split(current):
            if not variant:
                continue
            base = variant
            if base == current:
                continue
            if base not in seen:
                seen.add(base)
                names.append(base)
                queue.append(base)
    return names


def _canonical_dense_gemv_kernel(kernel: str) -> str:
    for candidate in _kernel_source_candidates(kernel=kernel):
        if candidate in DENSE_GEMV_SINK_OUTPUT_KERNELS:
            return candidate
    return kernel


def parse_tile_y_range(raw: str) -> tuple[int, int]:
    match = re.fullmatch(r"(\d+):(\d+)", raw.strip())
    if match is None:
        raise argparse.ArgumentTypeError(
            "expected START:END with non-negative integer bounds"
        )
    start = int(match.group(1))
    end = int(match.group(2))
    if start >= end:
        raise argparse.ArgumentTypeError("START must be less than END")
    return start, end


def worker_id_from_range(
    tile_y_range: tuple[int, int] | None,
    fallback: str,
) -> str:
    if tile_y_range is None:
        return fallback
    start, end = tile_y_range
    return f"y{start:04d}_y{end:04d}"


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--host-plan", type=Path, default=DEFAULT_HOST_PLAN)
    p.add_argument("--compile-root", type=Path, default=DEFAULT_COMPILE_ROOT)
    p.add_argument(
        "--source-root",
        type=Path,
        default=None,
        help=(
            "Optional separate root for per-kernel CSL source + "
            "pe_program.metadata.json. Defaults to --compile-root. The "
            "steps-mode driver lays source under "
            "<compile-root>/<kernel>/ and binaries under "
            "<compile-root>/compiled/<kernel>/, so callers pass "
            "--source-root <compile-root> and "
            "--compile-root <compile-root>/compiled."
        ),
    )
    p.add_argument("--probe-dir", type=Path, default=DEFAULT_PROBE_DIR)
    p.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)
    p.add_argument(
        "--kernel",
        action="append",
        default=None,
        help="Restrict to one or more named kernels.",
    )
    p.add_argument(
        "--cmaddr",
        default="",
        help="Optional CM endpoint for hardware dispatch.",
    )
    p.add_argument(
        "--timeout-seconds",
        type=int,
        default=1800,
        help="Per-kernel subprocess timeout.",
    )
    p.add_argument(
        "--cs-python", type=Path, default=CS_PYTHON_SINGULARITY
    )
    p.add_argument(
        "--cslc",
        type=Path,
        default=None,
        help="Optional cslc path for dense-GEMV row-tile compilation.",
    )
    p.add_argument("--adapter", type=Path, default=CHAIN_STEP_ADAPTER)
    p.add_argument(
        "--dense-gemv-tile-height",
        type=int,
        default=0,
        help=(
            "Dense-GEMV lm-head row block height for compile-time tiled "
            "dispatch evidence. Zero keeps the direct manifest dispatch path."
        ),
    )
    p.add_argument(
        "--dense-gemv-hidden-tile-width",
        type=int,
        default=None,
        help=(
            "Dense-GEMV lm-head hidden-width block for explicit tiled "
            "dispatch evidence. Omit to keep the direct manifest dispatch path."
        ),
    )
    p.add_argument(
        "--dense-gemv-allow-unsafe-tile-shapes",
        action="store_true",
        help=(
            "Diagnostic sweep mode only: allow dense-GEMV tiled dispatch "
            "shapes that exceed the simfabric D2H element-count safety guard. "
            "Receipts remain non-promoting unless tileShapeSafety.safe is true."
        ),
    )
    p.add_argument(
        "--dense-gemv-reuse-verified-tile-partials",
        action="store_true",
        help=(
            "Reuse existing dense-GEMV width-tile partials only when their "
            "tile partial receipt matches the command, input hashes, compile "
            "identity, output hash, and tile-shape safety metadata."
        ),
    )
    p.add_argument(
        "--dense-gemv-tile-dispatch-budget",
        type=int,
        default=0,
        help=(
            "Maximum new dense-GEMV width-tile dispatches to run before "
            "returning a typed partial-coverage receipt. Zero means no "
            "runner-side dispatch-count bound."
        ),
    )
    p.add_argument(
        "--dense-gemv-tile-dispatch-jobs",
        type=int,
        default=1,
        help=(
            "Number of independent dense-GEMV width-tile SDK subprocesses "
            "to run when explicit hidden-width tiling is enabled."
        ),
    )
    p.add_argument(
        "--dense-gemv-batch-runtime",
        action="store_true",
        help=(
            "Opt into one SDK runtime process per dense-GEMV width/row tile "
            "shape, with batch-json steps for each tile. Default stays one "
            "independent subprocess per tile."
        ),
    )
    p.add_argument(
        "--dense-gemv-batch-runtime-step-budget",
        type=int,
        default=0,
        help=(
            "Maximum dense-GEMV width-tile batch-json steps per SDK runtime "
            "process. Zero keeps one batch per width/row tile shape."
        ),
    )
    p.add_argument(
        "--dense-gemv-tile-y-range",
        type=parse_tile_y_range,
        default=None,
        metavar="START:END",
        help=(
            "Restrict dense-GEMV width-row tile execution to rowStart in "
            "[START, END). Keeps all hidden-width chunks for each selected "
            "row. Use with partial-only worker mode for parallel fanout."
        ),
    )
    p.add_argument(
        "--dense-gemv-partial-only-worker",
        action="store_true",
        help=(
            "Write dense-GEMV tile partial receipts and a worker receipt, "
            "but do not update canonical per-kernel or summary receipts."
        ),
    )
    p.add_argument(
        "--dense-gemv-worker-id",
        default="",
        help=(
            "Optional identifier for --dense-gemv-partial-only-worker "
            "receipts. Defaults to the tile y-range."
        ),
    )
    p.add_argument(
        "--dense-gemv-worker-receipt-dir",
        type=Path,
        default=None,
        help=(
            "Optional root for partial-only worker receipts. Defaults to "
            "<out-dir>/worker-receipts."
        ),
    )
    p.add_argument(
        "--dense-gemv-finalize-from-tile-receipts",
        action="store_true",
        help=(
            "Do not dispatch missing dense-GEMV tiles. Verify existing tile "
            "partial receipts, then emit the canonical aggregate receipt if "
            "coverage is complete or a typed incomplete-coverage receipt."
        ),
    )
    p.add_argument(
        "--dense-gemv-max-row-tile-height",
        type=int,
        default=1,
        help=(
            "Maximum row count per dense-GEMV width tile when row-split "
            "D2H is enabled. Zero allows a full-height width tile."
        ),
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help=(
            "Materialize probe-broadcast inputs and assemble the dispatch "
            "command without spawning cs_python."
        ),
    )
    p.add_argument(
        "--jobs",
        type=int,
        default=1,
        help=(
            "Number of independent per-kernel dispatch workers. Each worker "
            "uses its own scratch/<kernel>/ directory and receipt JSON."
        ),
    )
    p.add_argument(
        "--resume",
        action="store_true",
        help=(
            "Reuse existing non-dry-run dispatch receipts whose hostPlanHash "
            "matches the current host plan. Dry-run receipts are not reused "
            "for non-dry-run dispatch."
        ),
    )
    p.add_argument(
        "--reuse-blocked",
        action="store_true",
        help=(
            "With --resume, reuse existing blocked non-dry-run receipts too. "
            "This refreshes summaries while preserving explicit blockers "
            "instead of rerunning those kernels."
        ),
    )
    p.add_argument(
        "--schedule",
        choices=["host-plan", "heavy-first"],
        default="host-plan",
        help=(
            "Kernel launch order. heavy-first uses metadata-estimated "
            "manifest-shape input/output bytes so large kernels do not sit "
            "behind smaller probes when --jobs is used."
        ),
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


def _tail(text: str, lines: int = 20) -> list[str]:
    return text.splitlines()[-lines:] if text else []


def parse_phase_events(text: str) -> list[dict[str, str]]:
    events: list[dict[str, str]] = []
    for line in text.splitlines():
        match = _PHASE_LINE_RE.match(line.strip())
        if match is None:
            continue
        phase = match.group(1)
        raw_fields = match.group(2) or ""
        event = {"phase": phase}
        for token in raw_fields.split():
            if "=" not in token:
                continue
            key, value = token.split("=", 1)
            event[key] = value
        events.append(event)
    return events


def last_phase_reached(phase_events: list[dict[str, str]]) -> str:
    if not phase_events:
        return ""
    return str(phase_events[-1].get("phase") or "")


def _has_phase(phase_events: list[dict[str, str]], phase: str) -> bool:
    return any(str(event.get("phase") or "") == phase for event in phase_events)


def find_probe_transcript(
    *, kernel: str, probe_dir: Path
) -> Path | None:
    """Locate the Doppler transcript for a kernel, if any.

    Naming convention: `<kernel>.doppler-transcript.json`. Aliases
    (e.g. `rms_norm` ↔ `rmsnorm`) are normalized by stripping
    underscores before matching, so either spelling resolves to the
    same fixture when one exists.
    """
    if not probe_dir.is_dir():
        return None
    candidates: list[str] = []
    seen = set()
    for candidate in _kernel_source_candidates(kernel=kernel):
        if candidate not in seen:
            seen.add(candidate)
            candidates.append(candidate)
            alias = PROBE_TRANSCRIPT_ALIASES.get(candidate)
            if alias and alias not in seen:
                seen.add(alias)
                candidates.append(alias)
    for candidate in candidates:
        direct = probe_dir / f"{candidate}.doppler-transcript.json"
        if direct.is_file():
            return direct
    canonical = {candidate.replace("_", "") for candidate in candidates}
    for entry in probe_dir.glob("*.doppler-transcript.json"):
        stem = entry.name[: -len(".doppler-transcript.json")]
        if stem.replace("_", "") in canonical:
            return entry
    return None


def load_probe_inputs(
    transcript_path: Path,
) -> tuple[dict[str, list[float | int]], dict[str, Any]]:
    """Resolve transcript → bootstrap input fixture → per-symbol values.

    Returns (input_values_by_symbol, probe_metadata). The metadata is
    stamped on the receipt's `probe` block.
    """
    transcript = json.loads(transcript_path.read_text(encoding="utf-8"))
    source = transcript.get("source") or {}
    fixture_rel = source.get("fixturePath")
    if not isinstance(fixture_rel, str) or not fixture_rel:
        return {}, {
            "fixturePath": _try_relative(transcript_path),
            "fixtureHash": _sha256_file(transcript_path),
            "kernelRef": transcript.get("kernelRef"),
            "inputFixturePath": None,
            "inputFixtureHash": None,
            "broadcastStrategy": "absent_input_fixture",
        }
    input_path = (REPO_ROOT / fixture_rel).resolve()
    if not input_path.is_file():
        return {}, {
            "fixturePath": _try_relative(transcript_path),
            "fixtureHash": _sha256_file(transcript_path),
            "kernelRef": transcript.get("kernelRef"),
            "inputFixturePath": fixture_rel,
            "inputFixtureHash": None,
            "broadcastStrategy": "input_fixture_missing",
        }
    raw = json.loads(input_path.read_text(encoding="utf-8"))
    inputs_block = raw.get("inputs") or {}
    by_symbol: dict[str, list[float | int]] = {}
    for symbol, body in inputs_block.items():
        if not isinstance(body, dict):
            continue
        values = body.get("values")
        if isinstance(values, list):
            by_symbol[symbol] = list(values)
    return by_symbol, {
        "fixturePath": _try_relative(transcript_path),
        "fixtureHash": _sha256_file(transcript_path),
        "kernelRef": transcript.get("kernelRef"),
        "inputFixturePath": fixture_rel,
        "inputFixtureHash": _sha256_file(input_path),
        "broadcastStrategy": "tile_to_manifest_shape",
    }


def materialize_probe_input(
    *,
    target_path: Path,
    pe_count: int,
    per_pe_chunk: int,
    elem_type: str,
    probe_values: list[float | int] | None,
) -> tuple[int, str]:
    """Write a manifest-shape `.npy` initialized from probe values.

    When `probe_values` is None or empty, the buffer is zero-filled
    (matches layout-receipt behavior for that symbol). Otherwise probe values
    are tiled to fill the (pe_count * per_pe_chunk) buffer. Returns
    (byte_length, broadcast_strategy_for_this_symbol).
    """
    import numpy as np

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
    total = pe_count * per_pe_chunk
    target_path.parent.mkdir(parents=True, exist_ok=True)
    if not probe_values:
        arr = np.lib.format.open_memmap(
            target_path,
            mode="w+",
            dtype=dtype,
            shape=(total,),
        )
        arr[:] = 0
        arr.flush()
        del arr
        strategy = "zero"
    else:
        source_arr = np.asarray(probe_values, dtype=dtype)
        if source_arr.size == 0:
            arr = np.lib.format.open_memmap(
                target_path,
                mode="w+",
                dtype=dtype,
                shape=(total,),
            )
            arr[:] = 0
            arr.flush()
            del arr
            strategy = "zero"
        elif source_arr.size >= total:
            arr = source_arr[:total].astype(dtype, copy=False)
            np.save(target_path, arr)
            strategy = "truncate"
        else:
            reps = (total + source_arr.size - 1) // source_arr.size
            arr = np.tile(source_arr, reps)[:total].astype(
                dtype, copy=False
            )
            np.save(target_path, arr)
            strategy = "tile"
    return target_path.stat().st_size, strategy


def _adapter_dtype_token(elem_type: str) -> str:
    if elem_type in ("f32", "u32", "f16", "u8"):
        return elem_type
    if elem_type == "i32":
        return "u32"
    raise LayoutReceiptError(
        f"chain_step_adapter does not support elemType {elem_type!r} yet "
        "(wired: f32, u32, f16, u8)."
    )


def _infer_grid_from_compile_dir(compile_dir: Path) -> dict[str, int]:
    bin_dir = compile_dir / "bin"
    if not bin_dir.is_dir():
        return {}
    max_x = -1
    max_y = -1
    for entry in bin_dir.iterdir():
        match = _COMPILED_ELF_RE.match(entry.name)
        if match is None:
            continue
        max_x = max(max_x, int(match.group(1)))
        max_y = max(max_y, int(match.group(2)))
    inferred: dict[str, int] = {}
    if max_x >= 0:
        inferred["width"] = max_x + 1
    if max_y >= 0:
        inferred["height"] = max_y + 1
    return inferred


def _merge_layout_param_defaults(
    bindings: dict[str, int], layout_path: Path
) -> None:
    if not layout_path.is_file():
        return
    text = layout_path.read_text(encoding="utf-8")
    for match in _LAYOUT_PARAM_DEFAULT_RE.finditer(text):
        name = match.group(1)
        if name not in bindings:
            bindings[name] = int(match.group(2))


def _merge_metadata_integer_constants(
    bindings: dict[str, int], metadata: dict[str, Any]
) -> None:
    constants = list(metadata.get("compileTimeConstants") or [])
    changed = True
    while changed:
        changed = False
        for entry in constants:
            if not isinstance(entry, dict):
                continue
            name = entry.get("name")
            expr = entry.get("expr")
            if (
                not isinstance(name, str)
                or not name
                or name in bindings
                or not isinstance(expr, str)
            ):
                continue
            try:
                value = evaluate_size_expr(expr, bindings)
            except SizeExprError:
                continue
            bindings[name] = int(value)
            changed = True


def _compile_bindings(
    *,
    target: dict[str, Any],
    metadata: dict[str, Any],
    compile_dir: Path,
    layout_path: Path,
) -> dict[str, int]:
    bindings = {
        str(k): int(v)
        for k, v in (target.get("compileParams") or {}).items()
        if isinstance(v, (int, float))
    }
    for name, value in _infer_grid_from_compile_dir(compile_dir).items():
        bindings.setdefault(name, value)
    _merge_layout_param_defaults(bindings, layout_path)
    bindings.setdefault("height", 1)
    _merge_metadata_integer_constants(bindings, metadata)
    return bindings


def _metadata_path_for_kernel(
    *,
    kernel: str,
    source_root: Path,
) -> Path:
    for candidate in _kernel_source_candidates(kernel=kernel):
        candidate_path = source_root / candidate / "pe_program.metadata.json"
        if candidate_path.is_file():
            return candidate_path
    return source_root / kernel / "pe_program.metadata.json"


def _layout_path_for_kernel(
    *,
    kernel: str,
    source_root: Path,
) -> Path:
    for candidate in _kernel_source_candidates(kernel=kernel):
        candidate_path = source_root / candidate / "layout.csl"
        if candidate_path.is_file():
            return candidate_path
    return source_root / kernel / "layout.csl"


def estimate_target_io_bytes(
    *,
    target: dict[str, Any],
    compile_root: Path,
    source_root: Path,
) -> int:
    kernel = str(target.get("name") or "")
    if not kernel:
        return 0
    metadata_path = _metadata_path_for_kernel(
        kernel=kernel,
        source_root=source_root,
    )
    if not metadata_path.is_file():
        return 0
    try:
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        bindings = _compile_bindings(
            target=target,
            metadata=metadata,
            compile_dir=compile_root / kernel,
            layout_path=_layout_path_for_kernel(
                kernel=kernel,
                source_root=source_root,
            ),
        )
        width = int(bindings.get("width") or 0)
        height = int(bindings.get("height") or 1)
        pe_count = max(1, width * height)
        total = 0
        for export in metadata.get("exports") or []:
            if not isinstance(export, dict):
                continue
            chunk = int(
                evaluate_size_expr(export.get("sizeExpr", ""), bindings)
            )
            elem_type = str(export.get("elemType", "f32"))
            total += pe_count * chunk * ELEM_BYTES.get(elem_type, 4)
        return total
    except (OSError, ValueError, SizeExprError, json.JSONDecodeError):
        return 0


def order_targets(
    *,
    targets: list[dict[str, Any]],
    schedule: str,
    compile_root: Path,
    source_root: Path,
) -> list[dict[str, Any]]:
    if schedule != "heavy-first":
        return list(targets)
    indexed = list(enumerate(targets))
    indexed.sort(
        key=lambda item: (
            estimate_target_io_bytes(
                target=item[1],
                compile_root=compile_root,
                source_root=source_root,
            ),
            -item[0],
        ),
        reverse=True,
    )
    return [target for _, target in indexed]


def load_reusable_receipt(
    *,
    kernel: str,
    out_dir: Path,
    host_plan_hash: str,
    dry_run: bool,
    reuse_blocked: bool = False,
) -> dict[str, Any] | None:
    path = out_dir / f"{kernel}.json"
    try:
        receipt = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return None
    if receipt.get("kernel") != kernel:
        return None
    if receipt.get("hostPlanHash") != host_plan_hash:
        return None
    blocker = receipt.get("blocker")
    if dry_run:
        return receipt if blocker == "dry_run" else None
    if blocker == "dry_run":
        return None
    if receipt.get("verdict") == "bound":
        return receipt
    if reuse_blocked and receipt.get("verdict") == "blocked":
        return receipt
    return None


def _hash_output_files(records: list[dict[str, Any]]) -> None:
    for record in records:
        path = Path(record.pop("absolutePath", record["path"]))
        if not path.is_file():
            record["totalBytes"] = 0
            record["sha256"] = ""
            continue
        record["totalBytes"] = path.stat().st_size
        h = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1 << 20), b""):
                h.update(chunk)
        record["sha256"] = h.hexdigest()


def _dispatch_timeout_blocker(
    *,
    kernel: str,
    inputs: list[dict[str, Any]],
    total_output_bytes: int,
    dispatch_mode: str,
    last_phase: str,
    launch_completed: bool,
) -> str:
    canonical_kernel = _canonical_dense_gemv_kernel(kernel)
    if (
        dispatch_mode == DIRECT_DISPATCH_MODE
        and canonical_kernel in DENSE_GEMV_SINK_OUTPUT_KERNELS
        and total_output_bytes == 0
    ):
        weight_bytes = _weight_payload_bytes(inputs)
        if (
            weight_bytes >= RESIDENCY_WEIGHT_PAYLOAD_MIN_BYTES
            and launch_completed
            and last_phase == "memcpy_d2h_start"
        ):
            return "simfabric_d2h_copyback_stall_after_launch_complete"
        if (
            weight_bytes >= RESIDENCY_WEIGHT_PAYLOAD_MIN_BYTES
            and last_phase in {"run_complete", "memcpy_h2d_complete", "launch_start"}
        ):
            return "launch_payload_weight_residency_missing"
    return "dispatch_timed_out"


def _weight_payload_bytes(inputs: list[dict[str, Any]]) -> int:
    for record in inputs:
        if str(record.get("symbol") or "").lower() == "weight":
            return int(record.get("totalBytes") or 0)
    return 0


def _timeout_evidence(
    *,
    kernel: str,
    inputs: list[dict[str, Any]],
    total_output_bytes: int,
    dispatch_mode: str,
    last_phase: str,
    launch_completed: bool,
) -> dict[str, Any]:
    weight_bytes = _weight_payload_bytes(inputs)
    return {
        "kernelClass": (
            "dense_gemv_lm_head"
            if _canonical_dense_gemv_kernel(kernel) in DENSE_GEMV_SINK_OUTPUT_KERNELS
            else "other"
        ),
        "dispatchMode": dispatch_mode,
        "ordinaryH2DWeightPayload": dispatch_mode == DIRECT_DISPATCH_MODE,
        "weightPayloadBytes": weight_bytes,
        "weightPayloadMinBytes": RESIDENCY_WEIGHT_PAYLOAD_MIN_BYTES,
        "weightPayloadClass": (
            "nonzero_manifest_weight_h2d"
            if weight_bytes >= RESIDENCY_WEIGHT_PAYLOAD_MIN_BYTES
            else "absent_or_empty"
        ),
        "totalOutputBytes": total_output_bytes,
        "lastPhaseReached": last_phase,
        "launchCompleted": launch_completed,
    }


def normalize_reusable_receipt(receipt: dict[str, Any]) -> dict[str, Any]:
    """Refresh derived blocker/scope fields when reusing old receipts."""
    kernel = str(receipt.get("kernel") or "")
    dispatch_mode = str(receipt.get("dispatchMode") or DIRECT_DISPATCH_MODE)
    canonical_kernel = _canonical_dense_gemv_kernel(kernel)
    if (
        canonical_kernel in DENSE_GEMV_SINK_OUTPUT_KERNELS
        and dispatch_mode == DIRECT_DISPATCH_MODE
    ):
        receipt["weightInputScope"] = (
            receipt.get("weightInputScope")
            or "manifest_full_weight_payload"
        )
        receipt["weightResidencyMode"] = (
            receipt.get("weightResidencyMode")
            or "per_dispatch_h2d"
        )
    scope = _lm_head_evidence_scope(kernel, dispatch_mode)
    if scope:
        receipt["lmHeadEvidenceScope"] = scope
    if not bool(receipt.get("dispatchTimedOut")):
        return receipt
    phase_events = receipt.get("phaseEvents")
    if not isinstance(phase_events, list):
        phase_events = []
    last_phase = str(
        receipt.get("lastPhaseReached")
        or last_phase_reached(phase_events)
        or ""
    )
    launch_completed = _has_phase(phase_events, "launch_complete")
    inputs = [
        item for item in receipt.get("inputs") or []
        if isinstance(item, dict)
    ]
    total_output_bytes = int(receipt.get("totalOutputBytes") or 0)
    receipt["blocker"] = _dispatch_timeout_blocker(
        kernel=kernel,
        inputs=inputs,
        total_output_bytes=total_output_bytes,
        dispatch_mode=dispatch_mode,
        last_phase=last_phase,
        launch_completed=launch_completed,
    )
    receipt["lastPhaseReached"] = last_phase
    receipt["failurePhase"] = last_phase
    receipt["dispatchTimeoutEvidence"] = _timeout_evidence(
        kernel=kernel,
        inputs=inputs,
        total_output_bytes=total_output_bytes,
        dispatch_mode=dispatch_mode,
        last_phase=last_phase,
        launch_completed=launch_completed,
    )
    return receipt


def _lm_head_evidence_scope(kernel: str, dispatch_mode: str) -> str:
    if _canonical_dense_gemv_kernel(kernel) not in DENSE_GEMV_SINK_OUTPUT_KERNELS:
        return ""
    if dispatch_mode == DIRECT_DISPATCH_MODE:
        return LM_HEAD_DIRECT_EVIDENCE_SCOPE
    if dispatch_mode == "dense_gemv_width_tiled":
        return LM_HEAD_WIDTH_TILED_EVIDENCE_SCOPE
    if dispatch_mode == "dense_gemv_row_tiled":
        return LM_HEAD_ROW_TILED_EVIDENCE_SCOPE
    return "unsupported_lm_head_dispatch_mode"


def _auto_dense_gemv_hidden_tile_width(
    *,
    requested_hidden_tile_width: int | None,
    tile_height: int,
    compile_params: dict[str, int],
    allow_unsafe_tile_shapes: bool,
) -> int | None:
    if requested_hidden_tile_width is not None or allow_unsafe_tile_shapes:
        return requested_hidden_tile_width
    width = int(compile_params.get("width") or 0)
    full_height = int(compile_params.get("height") or 0)
    out_dim_per_pe = int(compile_params.get("out_dim_per_pe") or 0)
    if min(width, full_height, out_dim_per_pe) <= 0:
        return None
    row_tile_height = max(1, min(max(1, tile_height), full_height))
    if full_height % row_tile_height != 0:
        row_tile_height = 1
    if is_safe_tile_shape(
        width=width,
        height=row_tile_height,
        out_dim_per_pe=out_dim_per_pe,
    ):
        return None
    safe_width = max_safe_tile_width(height=1, out_dim_per_pe=out_dim_per_pe)
    if safe_width <= 0:
        return None
    tile_count = max(1, (width + safe_width - 1) // safe_width)
    return max(1, (width + tile_count - 1) // tile_count)


def _dense_gemv_output_region(
    *,
    kernel: str,
    symbol: str,
    bindings: dict[str, int],
) -> tuple[dict[str, int], str] | None:
    if (
        _canonical_dense_gemv_kernel(kernel)
        not in DENSE_GEMV_SINK_OUTPUT_KERNELS
        or symbol.lower() != "output"
    ):
        return None
    width = int(bindings.get("width") or 0)
    height = int(bindings.get("height") or 0)
    if width <= 1 or height <= 0:
        return None
    return (
        {
            "x": width - 1,
            "y": 0,
            "width": 1,
            "height": height,
        },
        "dense_gemv_sink_column",
    )


def _region_spec(region: dict[str, int]) -> str:
    return (
        f"{region['x']},{region['y']},"
        f"{region['width']},{region['height']}"
    )


def _d2h_mode_for_outputs(
    *,
    kernel: str,
    output_records: list[dict[str, Any]],
) -> str:
    if _canonical_dense_gemv_kernel(kernel) not in DENSE_GEMV_SINK_OUTPUT_KERNELS:
        return SINGLE_REGION_D2H_MODE
    for record in output_records:
        region = record.get("deviceRegion")
        if not isinstance(region, dict):
            continue
        if int(region.get("height") or 0) > 1:
            return ROW_SPLIT_D2H_MODE
    return SINGLE_REGION_D2H_MODE


def _materialize_inputs(
    *,
    kernel: str,
    target: dict[str, Any],
    metadata: dict[str, Any],
    probe_inputs: dict[str, list[float | int]],
    scratch_dir: Path,
) -> tuple[
    list[dict[str, Any]],
    list[dict[str, Any]],
    list[str],
    list[str],
    int,
    dict[str, str],
]:
    """Like the layout-receipt step but uses probe-broadcast inputs for
    symbols with a probe entry. Returns the layout-receipt quintuple plus
    a per-symbol broadcast-strategy map for the probe block."""
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
    per_symbol_strategy: dict[str, str] = {}

    chunk_size_default = 0
    for export in inputs_meta:
        try:
            chunk = int(evaluate_size_expr(
                export.get("sizeExpr", ""), bindings
            ))
        except SizeExprError as err:
            raise LayoutReceiptError(
                f"kernel {kernel!r}: unable to evaluate sizeExpr for input "
                f"symbol {export.get('symbol')!r}: {err}"
            ) from err
        if chunk_size_default == 0:
            chunk_size_default = chunk
        elem_type = export.get("elemType", "f32")
        elem_bytes = ELEM_BYTES.get(elem_type, 4)
        symbol = export.get("symbol", "")
        path = scratch_dir / "in" / f"{symbol}.npy"
        zero_default_h2d = symbol in ZERO_DEFAULT_H2D_INPUTS_BY_KERNEL.get(
            kernel, set()
        )
        probe_vals = None if zero_default_h2d else probe_inputs.get(symbol)
        byte_len, strategy = materialize_probe_input(
            target_path=path,
            pe_count=pe_count,
            per_pe_chunk=chunk,
            elem_type=elem_type,
            probe_values=probe_vals,
        )
        if zero_default_h2d:
            strategy = "zero_default_h2d"
        per_symbol_strategy[symbol] = strategy
        h = hashlib.sha256()
        with path.open("rb") as handle:
            for piece in iter(lambda: handle.read(1 << 20), b""):
                h.update(piece)
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
                "sha256": h.hexdigest(),
                "probeStrategy": strategy,
            }
        )
        adapter_dtype = _adapter_dtype_token(elem_type)
        input_specs.append(
            f"{symbol}:{path}:{adapter_dtype}:{chunk}"
        )

    for export in outputs_meta:
        try:
            chunk = int(evaluate_size_expr(
                export.get("sizeExpr", ""), bindings
            ))
        except SizeExprError as err:
            raise LayoutReceiptError(
                f"kernel {kernel!r}: unable to evaluate sizeExpr for output "
                f"symbol {export.get('symbol')!r}: {err}"
            ) from err
        if chunk_size_default == 0:
            chunk_size_default = chunk
        elem_type = export.get("elemType", "f32")
        elem_bytes = ELEM_BYTES.get(elem_type, 4)
        symbol = export.get("symbol", "")
        path = scratch_dir / "out" / f"{symbol}.npy"
        path.parent.mkdir(parents=True, exist_ok=True)
        total_elems = pe_count * chunk
        output_record = {
            "symbol": symbol,
            "path": _try_relative(path),
            "elemType": elem_type,
            "elemBytes": elem_bytes,
            "perPeChunk": chunk,
            "totalElements": total_elems,
            "totalBytes": 0,
            "sha256": "",
            "absolutePath": str(path),
        }
        adapter_dtype = _adapter_dtype_token(elem_type)
        region_info = _dense_gemv_output_region(
            kernel=kernel,
            symbol=str(symbol),
            bindings=bindings,
        )
        if region_info is not None:
            region, scope = region_info
            output_record["deviceRegion"] = region
            output_record["outputScope"] = scope
            output_record["deviceTotalElements"] = total_elems
            output_record["totalElements"] = (
                int(region["width"]) * int(region["height"]) * chunk
            )
            output_specs.append(
                f"{symbol}:{path}:{adapter_dtype}:{chunk}:{_region_spec(region)}"
            )
        else:
            output_specs.append(
                f"{symbol}:{path}:{adapter_dtype}:{chunk}"
            )
        output_records.append(output_record)

    return (
        input_records,
        output_records,
        input_specs,
        output_specs,
        chunk_size_default or 1,
        per_symbol_strategy,
    )


def build_kernel_receipt(
    *,
    kernel: str,
    compile_dir: Path,
    compile_params: dict[str, int],
    inputs: list[dict[str, Any]],
    outputs: list[dict[str, Any]],
    probe: dict[str, Any],
    dispatch_command: list[str],
    dispatch_exit_code: int | None,
    dispatch_stdout: str,
    dispatch_stderr: str,
    dispatch_timed_out: bool,
    dispatch_wallclock_ns: int | None,
    dispatch_mode: str = DIRECT_DISPATCH_MODE,
    d2h_mode: str = SINGLE_REGION_D2H_MODE,
    phase_trace_path: Path | None = None,
    host_plan_path: Path,
    host_plan_hash: str,
    cmaddr: str,
    blocker: str | None,
) -> dict[str, Any]:
    total_input_bytes = sum(int(r.get("totalBytes", 0)) for r in inputs)
    total_output_bytes = sum(int(r.get("totalBytes", 0)) for r in outputs)
    aggregate = hashlib.sha256()
    for record in outputs:
        digest = record.get("sha256")
        if isinstance(digest, str) and digest:
            aggregate.update(digest.encode("ascii"))
    output_digest = aggregate.hexdigest() if outputs else ""
    phase_events = parse_phase_events(dispatch_stdout)
    last_phase = last_phase_reached(phase_events)
    launch_completed = _has_phase(phase_events, "launch_complete")
    failure_phase = last_phase if dispatch_timed_out else ""
    weight_input_scope = ""
    weight_residency_mode = ""
    if (
        _canonical_dense_gemv_kernel(kernel) in DENSE_GEMV_SINK_OUTPUT_KERNELS
        and dispatch_mode == DIRECT_DISPATCH_MODE
    ):
        weight_input_scope = "manifest_full_weight_payload"
        weight_residency_mode = "per_dispatch_h2d"

    if blocker is None:
        if dispatch_exit_code != 0 or dispatch_timed_out:
            blocker = (
                _dispatch_timeout_blocker(
                    kernel=kernel,
                    inputs=inputs,
                    total_output_bytes=total_output_bytes,
                    dispatch_mode=dispatch_mode,
                    last_phase=last_phase,
                    launch_completed=launch_completed,
                )
                if dispatch_timed_out
                else f"dispatch_exit_code_{dispatch_exit_code}"
            )
        elif total_output_bytes == 0 and outputs:
            blocker = "outputs_empty_after_dispatch"

    verdict = "blocked" if blocker else "bound"

    receipt = {
        "schemaVersion": 1,
        "artifactKind": "doe_manifest_shape_per_kernel_dispatch_receipt",
        "receiptClass": "manifest_shape_per_kernel_dispatch",
        "comparisonMode": "no_oracle",
        "kernel": kernel,
        "compileDir": _try_relative(compile_dir),
        "compileParams": dict(compile_params),
        "hostPlanPath": _try_relative(host_plan_path),
        "hostPlanHash": host_plan_hash,
        "cmaddr": cmaddr or "",
        "executionTarget": "system" if cmaddr else "simfabric",
        "probe": probe,
        "inputs": list(inputs),
        "outputs": list(outputs),
        "totalInputBytes": total_input_bytes,
        "totalOutputBytes": total_output_bytes,
        "outputDigest": output_digest,
        "dispatchMode": dispatch_mode,
        "d2hMode": d2h_mode,
        "weightInputScope": weight_input_scope,
        "weightResidencyMode": weight_residency_mode,
        "dispatchExitCode": dispatch_exit_code,
        "dispatchTimedOut": dispatch_timed_out,
        "dispatchWallclockNs": dispatch_wallclock_ns,
        "phaseEvents": phase_events,
        "lastPhaseReached": last_phase,
        "failurePhase": failure_phase,
        "phaseTracePath": (
            _try_relative(phase_trace_path)
            if phase_trace_path is not None
            else ""
        ),
        "subprocess": {
            "command": list(dispatch_command),
            "stdoutTail": _tail(dispatch_stdout),
            "stderrTail": _tail(dispatch_stderr),
        },
        "verdict": verdict,
        "blocker": blocker,
        "claim": {
            "scope": (
                "Per-kernel manifest-shape dispatch with Doppler-probe "
                "inputs (tiled to manifest shape). Records bytes-in / "
                "bytes-out, dispatch exit code, and wall-clock so "
                "downstream predicted-wallclock calibration can derive the "
                "throughput constant."
            ),
            "notWhat": (
                "Not a parity claim against the frozen Doppler "
                "reference; that's the attention-canary, full-prefill, and "
                "multi-token continuation steps once the frozen-Doppler fixture "
                "lands. Probe inputs are tiled across the manifest-"
                "shape buffer — values are not numerically meaningful "
                "for kernels whose probe shape is much smaller than "
                "manifest shape."
            ),
        },
    }
    scope = _lm_head_evidence_scope(kernel, dispatch_mode)
    if scope:
        receipt["lmHeadEvidenceScope"] = scope
    if dispatch_timed_out:
        receipt["dispatchTimeoutEvidence"] = _timeout_evidence(
            kernel=kernel,
            inputs=inputs,
            total_output_bytes=total_output_bytes,
            dispatch_mode=dispatch_mode,
            last_phase=last_phase,
            launch_completed=launch_completed,
        )
    return receipt


def run_one_kernel(
    *,
    kernel: str,
    target: dict[str, Any],
    compile_root: Path,
    source_root: Path | None = None,
    probe_dir: Path,
    host_plan_path: Path,
    host_plan_hash: str,
    out_dir: Path,
    cmaddr: str,
    timeout_seconds: int,
    cs_python: Path,
    adapter: Path,
    dry_run: bool,
    cslc: Path | None = None,
    dense_gemv_tile_height: int = 0,
    dense_gemv_hidden_tile_width: int | None = None,
    dense_gemv_allow_unsafe_tile_shapes: bool = False,
    dense_gemv_reuse_verified_tile_partials: bool = False,
    dense_gemv_tile_dispatch_budget: int = 0,
    dense_gemv_tile_dispatch_jobs: int = 1,
    dense_gemv_max_row_tile_height: int = 16,
    dense_gemv_batch_runtime: bool = False,
    dense_gemv_batch_runtime_step_budget: int = 0,
    dense_gemv_tile_y_range: tuple[int, int] | None = None,
    dense_gemv_finalize_from_tile_receipts: bool = False,
    dense_gemv_worker_id: str = "",
    dispatcher: Callable[..., tuple[int, str, str, bool]] | None = None,
) -> dict[str, Any]:
    effective_source_root = source_root if source_root is not None else compile_root
    metadata_path = _metadata_path_for_kernel(
        kernel=kernel,
        source_root=effective_source_root,
    )
    if not metadata_path.is_file():
        return build_kernel_receipt(
            kernel=kernel,
            compile_dir=compile_root / kernel,
            compile_params={
                str(k): int(v)
                for k, v in (target.get("compileParams") or {}).items()
            },
            inputs=[],
            outputs=[],
            probe={"broadcastStrategy": "absent"},
            dispatch_command=[],
            dispatch_exit_code=None,
            dispatch_stdout="",
            dispatch_stderr="",
            dispatch_timed_out=False,
            dispatch_wallclock_ns=None,
            host_plan_path=host_plan_path,
            host_plan_hash=host_plan_hash,
            cmaddr=cmaddr,
            blocker=f"metadata_missing: {metadata_path}",
        )

    transcript_path = find_probe_transcript(
        kernel=kernel, probe_dir=probe_dir
    )
    if transcript_path is None:
        return build_kernel_receipt(
            kernel=kernel,
            compile_dir=compile_root / kernel,
            compile_params={
                str(k): int(v)
                for k, v in (target.get("compileParams") or {}).items()
            },
            inputs=[],
            outputs=[],
            probe={"broadcastStrategy": "absent"},
            dispatch_command=[],
            dispatch_exit_code=None,
            dispatch_stdout="",
            dispatch_stderr="",
            dispatch_timed_out=False,
            dispatch_wallclock_ns=None,
            host_plan_path=host_plan_path,
            host_plan_hash=host_plan_hash,
            cmaddr=cmaddr,
            blocker="probe_fixture_absent",
        )

    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    compile_dir = compile_root / kernel
    layout_path = _layout_path_for_kernel(
        kernel=kernel,
        source_root=effective_source_root,
    )
    compile_params = _compile_bindings(
        target=target,
        metadata=metadata,
        compile_dir=compile_dir,
        layout_path=layout_path,
    )
    width = int(compile_params.get("width") or 0)
    height = int(compile_params.get("height") or 1)

    probe_inputs, probe_metadata = load_probe_inputs(transcript_path)

    scratch_dir = out_dir / "scratch" / kernel
    scratch_dir.mkdir(parents=True, exist_ok=True)

    try:
        (
            input_records,
            output_records,
            input_specs,
            output_specs,
            chunk_default,
            per_symbol_strategy,
        ) = _materialize_inputs(
            kernel=kernel,
            target={"compileParams": compile_params},
            metadata=metadata,
            probe_inputs=probe_inputs,
            scratch_dir=scratch_dir,
        )
    except LayoutReceiptError as err:
        return build_kernel_receipt(
            kernel=kernel,
            compile_dir=compile_root / kernel,
            compile_params=compile_params,
            inputs=[],
            outputs=[],
            probe=probe_metadata,
            dispatch_command=[],
            dispatch_exit_code=None,
            dispatch_stdout="",
            dispatch_stderr=str(err),
            dispatch_timed_out=False,
            dispatch_wallclock_ns=None,
            host_plan_path=host_plan_path,
            host_plan_hash=host_plan_hash,
            cmaddr=cmaddr,
            blocker=f"input_synthesis_failed: {err}",
        )

    probe_metadata["perSymbolStrategy"] = per_symbol_strategy

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
    d2h_mode = _d2h_mode_for_outputs(
        kernel=kernel,
        output_records=output_records,
    )
    phase_trace_path = scratch_dir / "phase-trace.log"
    command.extend(["--phase-trace", str(phase_trace_path)])
    if d2h_mode == ROW_SPLIT_D2H_MODE:
        command.append("--split-d2h-rows")

    if dry_run:
        for record in output_records:
            record.pop("absolutePath", None)
        return build_kernel_receipt(
            kernel=kernel,
            compile_dir=compile_dir,
            compile_params=compile_params,
            inputs=input_records,
            outputs=output_records,
            probe=probe_metadata,
            dispatch_command=command,
            dispatch_exit_code=None,
            dispatch_stdout="",
            dispatch_stderr="",
            dispatch_timed_out=False,
            dispatch_wallclock_ns=None,
            host_plan_path=host_plan_path,
            host_plan_hash=host_plan_hash,
            cmaddr=cmaddr,
            blocker="dry_run",
        )

    blocker: str | None = None
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
            probe=probe_metadata,
            dispatch_command=command,
            dispatch_exit_code=None,
            dispatch_stdout="",
            dispatch_stderr="",
            dispatch_timed_out=False,
            dispatch_wallclock_ns=None,
            host_plan_path=host_plan_path,
            host_plan_hash=host_plan_hash,
            cmaddr=cmaddr,
            blocker=blocker,
        )

    tiled = None
    effective_dense_gemv_hidden_tile_width = (
        _auto_dense_gemv_hidden_tile_width(
            requested_hidden_tile_width=dense_gemv_hidden_tile_width,
            tile_height=max(1, dense_gemv_tile_height),
            compile_params=compile_params,
            allow_unsafe_tile_shapes=dense_gemv_allow_unsafe_tile_shapes,
        )
        if dense_gemv_tile_height > 0
        else dense_gemv_hidden_tile_width
    )
    if (
        dense_gemv_tile_height > 0
        or effective_dense_gemv_hidden_tile_width is not None
    ):
        tiled = run_dense_gemv_row_tiled(
            kernel=kernel,
            compile_root=compile_root,
            source_root=effective_source_root,
            compile_params=compile_params,
            input_records=input_records,
            output_records=output_records,
            scratch_dir=scratch_dir,
            cs_python=cs_python,
            adapter=adapter,
            cmaddr=cmaddr,
            timeout_seconds=timeout_seconds,
            repo_root=REPO_ROOT,
            cslc=cslc,
            tile_height=max(1, dense_gemv_tile_height),
            hidden_tile_width=effective_dense_gemv_hidden_tile_width,
            allow_unsafe_tile_shapes=dense_gemv_allow_unsafe_tile_shapes,
            reuse_verified_tile_partials=(
                dense_gemv_reuse_verified_tile_partials
            ),
            tile_dispatch_budget=dense_gemv_tile_dispatch_budget,
            tile_dispatch_jobs=dense_gemv_tile_dispatch_jobs,
            max_row_tile_height=dense_gemv_max_row_tile_height,
            batch_runtime=dense_gemv_batch_runtime,
            batch_runtime_step_budget=dense_gemv_batch_runtime_step_budget,
            tile_y_range=dense_gemv_tile_y_range,
            finalize_from_tile_receipts=(
                dense_gemv_finalize_from_tile_receipts
            ),
            worker_id=dense_gemv_worker_id,
            dispatcher=dispatcher,
        )
    if tiled is not None:
        for record in tiled.output_records:
            record.pop("absolutePath", None)
        receipt = build_kernel_receipt(
            kernel=kernel,
            compile_dir=compile_root / kernel,
            compile_params=compile_params,
            inputs=input_records,
            outputs=tiled.output_records,
            probe=probe_metadata,
            dispatch_command=tiled.dispatch_command,
            dispatch_exit_code=tiled.dispatch_exit_code,
            dispatch_stdout=tiled.dispatch_stdout,
            dispatch_stderr=tiled.dispatch_stderr,
            dispatch_timed_out=tiled.dispatch_timed_out,
            dispatch_wallclock_ns=tiled.dispatch_wallclock_ns,
            dispatch_mode=tiled.dispatch_mode,
            host_plan_path=host_plan_path,
            host_plan_hash=host_plan_hash,
            cmaddr=cmaddr,
            blocker=tiled.blocker,
        )
        receipt["dispatchMode"] = tiled.dispatch_mode
        receipt["tileCompile"] = tiled.tile_compile
        receipt["tileDispatches"] = tiled.tile_dispatches
        if getattr(tiled, "tile_coverage", None) is not None:
            receipt["tileCoverage"] = tiled.tile_coverage
        receipt["weightInputScope"] = tiled.weight_input_scope
        receipt["weightResidencyMode"] = tiled.weight_residency_mode
        return receipt

    runner = dispatcher or run_dispatch_subprocess
    started = time.monotonic_ns()
    exit_code, stdout, stderr, timed_out = runner(
        command, timeout_seconds=timeout_seconds
    )
    elapsed_ns = time.monotonic_ns() - started
    if phase_trace_path.is_file() and not parse_phase_events(stdout):
        stdout = stdout + "\n" + phase_trace_path.read_text(encoding="utf-8")

    _hash_output_files(output_records)

    return build_kernel_receipt(
        kernel=kernel,
        compile_dir=compile_dir,
        compile_params=compile_params,
        inputs=input_records,
        outputs=output_records,
        probe=probe_metadata,
        dispatch_command=command,
        dispatch_exit_code=exit_code,
        dispatch_stdout=stdout,
        dispatch_stderr=stderr,
        dispatch_timed_out=timed_out,
        dispatch_wallclock_ns=elapsed_ns,
        d2h_mode=d2h_mode,
        phase_trace_path=phase_trace_path,
        host_plan_path=host_plan_path,
        host_plan_hash=host_plan_hash,
        cmaddr=cmaddr,
        blocker=None,
    )


def write_kernel_receipt(
    *, receipt: dict[str, Any], out_dir: Path
) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    enforce_receipt_hash_spine(receipt, repo_root=REPO_ROOT)
    path = out_dir / f"{receipt['kernel']}.json"
    path.write_text(
        json.dumps(receipt, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return path


def write_worker_receipt(
    *,
    receipt: dict[str, Any],
    out_dir: Path,
    worker_id: str,
) -> Path:
    worker_root = out_dir / "worker-receipts" / str(receipt["kernel"])
    worker_root.mkdir(parents=True, exist_ok=True)
    receipt["workerReceipt"] = {
        "kind": "dense_gemv_partial_only_worker",
        "workerId": worker_id,
    }
    enforce_receipt_hash_spine(receipt, repo_root=REPO_ROOT)
    safe_worker_id = re.sub(r"[^A-Za-z0-9_.-]+", "_", worker_id)
    path = worker_root / f"{safe_worker_id}.json"
    path.write_text(
        json.dumps(receipt, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return path


def _summarize_tile_compile(receipt: dict[str, Any]) -> dict[str, Any] | None:
    compile_info = receipt.get("tileCompile")
    if not isinstance(compile_info, dict):
        return None
    summary: dict[str, Any] = {}
    for key in (
        "mode",
        "widthTileCount",
        "verdict",
        "blocker",
        "width",
        "tileHeight",
        "outDimPerPe",
        "inDimPerPe",
        "commandDigest",
        "reused",
    ):
        if key in compile_info:
            summary[key] = compile_info[key]
    receipts = compile_info.get("receipts")
    if isinstance(receipts, list):
        summary["receiptCount"] = len(receipts)
        summary["blockedCount"] = sum(
            1 for item in receipts
            if isinstance(item, dict) and item.get("verdict") == "blocked"
        )
        summary["commandDigests"] = [
            item.get("commandDigest")
            for item in receipts
            if isinstance(item, dict) and item.get("commandDigest")
        ]
    return summary


def _summarize_tile_dispatches(receipt: dict[str, Any]) -> dict[str, Any] | None:
    dispatches = receipt.get("tileDispatches")
    if not isinstance(dispatches, list):
        return None
    output_digest = hashlib.sha256()
    output_digest_count = 0
    total_output_bytes = 0
    blocked_count = 0
    reused_count = 0
    execution_modes: set[str] = set()
    for item in dispatches:
        if not isinstance(item, dict):
            continue
        mode = item.get("executionMode")
        if isinstance(mode, str) and mode:
            execution_modes.add(mode)
        if item.get("reusedVerifiedPartial"):
            reused_count += 1
        if item.get("timedOut") or item.get("exitCode") not in (0, None):
            blocked_count += 1
        output = item.get("output")
        if not isinstance(output, dict):
            continue
        total_output_bytes += int(output.get("totalBytes") or 0)
        digest = output.get("sha256")
        if isinstance(digest, str) and digest:
            output_digest.update(digest.encode("ascii"))
            output_digest_count += 1
    summary = {
        "tileCount": len(dispatches),
        "blockedCount": blocked_count,
        "boundCount": max(0, len(dispatches) - blocked_count),
        "reusedCount": reused_count,
        "totalOutputBytes": total_output_bytes,
        "outputDigest": (
            output_digest.hexdigest() if output_digest_count else ""
        ),
    }
    if execution_modes:
        summary["executionModes"] = sorted(execution_modes)
    return summary


def _first_output_field(
    receipt: dict[str, Any],
    field: str,
) -> Any:
    outputs = receipt.get("outputs")
    if not isinstance(outputs, list) or not outputs:
        return None
    first = outputs[0]
    if not isinstance(first, dict):
        return None
    return first.get(field)


def _summary_entry(receipt: dict[str, Any]) -> dict[str, Any]:
    dispatch_mode = receipt.get("dispatchMode") or DIRECT_DISPATCH_MODE
    lm_head_scope = (
        receipt.get("lmHeadEvidenceScope")
        or _lm_head_evidence_scope(str(receipt["kernel"]), str(dispatch_mode))
    )
    weight_input_scope = receipt.get("weightInputScope") or ""
    weight_residency_mode = receipt.get("weightResidencyMode") or ""
    if (
        _canonical_dense_gemv_kernel(str(receipt["kernel"]))
        in DENSE_GEMV_SINK_OUTPUT_KERNELS
        and dispatch_mode == DIRECT_DISPATCH_MODE
    ):
        weight_input_scope = weight_input_scope or "manifest_full_weight_payload"
        weight_residency_mode = weight_residency_mode or "per_dispatch_h2d"
    entry = {
        "kernel": receipt["kernel"],
        "verdict": receipt["verdict"],
        "blocker": receipt["blocker"],
        "dispatchMode": dispatch_mode,
        "d2hMode": receipt.get("d2hMode") or SINGLE_REGION_D2H_MODE,
        "lmHeadEvidenceScope": lm_head_scope,
        "weightInputScope": weight_input_scope,
        "weightResidencyMode": weight_residency_mode,
        "dispatchExitCode": receipt["dispatchExitCode"],
        "dispatchTimedOut": receipt["dispatchTimedOut"],
        "dispatchWallclockNs": receipt["dispatchWallclockNs"],
        "lastPhaseReached": receipt.get("lastPhaseReached") or "",
        "failurePhase": receipt.get("failurePhase") or "",
        "totalInputBytes": receipt["totalInputBytes"],
        "totalOutputBytes": receipt["totalOutputBytes"],
        "outputDigest": receipt["outputDigest"],
        "probeFixturePath": (receipt.get("probe") or {}).get(
            "fixturePath"
        ),
    }
    tile_compile = _summarize_tile_compile(receipt)
    if tile_compile is not None:
        entry["tileCompile"] = tile_compile
    tile_dispatches = _summarize_tile_dispatches(receipt)
    if tile_dispatches is not None:
        entry["tileDispatches"] = tile_dispatches
    tile_coverage = receipt.get("tileCoverage")
    if isinstance(tile_coverage, dict):
        entry["tileCoverage"] = tile_coverage
    host_reduction = _first_output_field(receipt, "hostReduction")
    if isinstance(host_reduction, dict):
        entry["hostReduction"] = host_reduction
    return entry


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
        "artifactKind": "doe_manifest_shape_per_kernel_dispatch_summary",
        "receiptClass": "manifest_shape_per_kernel_dispatch_summary",
        "hostPlanPath": _try_relative(host_plan_path),
        "hostPlanHash": host_plan_hash,
        "kernels": [_summary_entry(r) for r in receipts],
        "totals": {
            "kernelCount": len(receipts),
            "boundCount": sum(
                1 for r in receipts if r["verdict"] == "bound"
            ),
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


def load_existing_receipts_for_summary(
    *,
    out_dir: Path,
    host_plan_hash: str,
) -> dict[str, dict[str, Any]]:
    receipts: dict[str, dict[str, Any]] = {}
    if not out_dir.is_dir():
        return receipts
    for path in sorted(out_dir.glob("*.json")):
        if path.name == "summary.json":
            continue
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(payload, dict):
            continue
        kernel = str(payload.get("kernel") or "")
        if not kernel:
            continue
        if payload.get("hostPlanHash") != host_plan_hash:
            continue
        receipts[kernel] = payload
    return receipts


def main() -> int:
    args = parse_args()
    if args.jobs < 1:
        sys.stderr.write("manifest_kernel_probe_runner: --jobs must be >= 1\n")
        return 2
    if args.dense_gemv_tile_dispatch_jobs < 1:
        sys.stderr.write(
            "manifest_kernel_probe_runner: "
            "--dense-gemv-tile-dispatch-jobs must be >= 1\n"
        )
        return 2
    if (
        args.dense_gemv_batch_runtime
        and args.dense_gemv_tile_dispatch_jobs != 1
    ):
        sys.stderr.write(
            "manifest_kernel_probe_runner: --dense-gemv-batch-runtime "
            "requires --dense-gemv-tile-dispatch-jobs 1\n"
        )
        return 2
    if args.dense_gemv_max_row_tile_height < 0:
        sys.stderr.write(
            "manifest_kernel_probe_runner: "
            "--dense-gemv-max-row-tile-height must be >= 0\n"
        )
        return 2
    if args.dense_gemv_batch_runtime_step_budget < 0:
        sys.stderr.write(
            "manifest_kernel_probe_runner: "
            "--dense-gemv-batch-runtime-step-budget must be >= 0\n"
        )
        return 2
    if args.dense_gemv_partial_only_worker:
        if args.dense_gemv_tile_y_range is None:
            sys.stderr.write(
                "manifest_kernel_probe_runner: "
                "--dense-gemv-partial-only-worker requires "
                "--dense-gemv-tile-y-range\n"
            )
            return 2
        if not args.kernel or len(args.kernel) != 1:
            sys.stderr.write(
                "manifest_kernel_probe_runner: "
                "--dense-gemv-partial-only-worker requires one --kernel\n"
            )
            return 2
    if (
        args.dense_gemv_finalize_from_tile_receipts
        and args.dense_gemv_tile_y_range is not None
    ):
        sys.stderr.write(
            "manifest_kernel_probe_runner: "
            "--dense-gemv-finalize-from-tile-receipts cannot be combined "
            "with --dense-gemv-tile-y-range\n"
        )
        return 2
    if (
        args.dense_gemv_finalize_from_tile_receipts
        and not args.dense_gemv_reuse_verified_tile_partials
    ):
        sys.stderr.write(
            "manifest_kernel_probe_runner: "
            "--dense-gemv-finalize-from-tile-receipts requires "
            "--dense-gemv-reuse-verified-tile-partials\n"
        )
        return 2
    if not args.host_plan.is_file():
        sys.stderr.write(
            f"manifest_kernel_probe_runner: host-plan absent at "
            f"{args.host_plan}\n"
        )
        return 2
    host_plan = json.loads(args.host_plan.read_text(encoding="utf-8"))
    host_plan_hash = _sha256_file(args.host_plan)
    raw_targets = host_plan.get("compileTargets") or []
    all_targets = [
        target for target in raw_targets
        if isinstance(target, dict) and target.get("name")
    ]
    targets = list(all_targets)
    if args.kernel:
        kernel_filter = set(args.kernel)
        targets = [t for t in targets if t.get("name") in kernel_filter]
        if not targets:
            sys.stderr.write(
                f"manifest_kernel_probe_runner: no targets matched "
                f"--kernel filter {sorted(kernel_filter)!r}\n"
            )
            return 2
    source_root = args.source_root or args.compile_root
    targets = order_targets(
        targets=targets,
        schedule=args.schedule,
        compile_root=args.compile_root,
        source_root=source_root,
    )
    summary_targets = order_targets(
        targets=all_targets,
        schedule="host-plan",
        compile_root=args.compile_root,
        source_root=source_root,
    )

    receipts_by_kernel: dict[str, dict[str, Any]] = {}
    blocked_count = 0
    reused_count = 0

    def run_target(target: dict[str, Any]) -> tuple[str, dict[str, Any], bool]:
        kernel = str(target.get("name") or "")
        if args.resume:
            reusable = load_reusable_receipt(
                kernel=kernel,
                out_dir=args.out_dir,
                host_plan_hash=host_plan_hash,
                dry_run=args.dry_run,
                reuse_blocked=args.reuse_blocked,
            )
            if reusable is not None:
                reusable = normalize_reusable_receipt(reusable)
                if not args.dense_gemv_partial_only_worker:
                    write_kernel_receipt(
                        receipt=reusable,
                        out_dir=args.out_dir,
                    )
                return kernel, reusable, True
        receipt = run_one_kernel(
            kernel=kernel,
            target=target,
            compile_root=args.compile_root,
            source_root=source_root,
            probe_dir=args.probe_dir,
            host_plan_path=args.host_plan,
            host_plan_hash=host_plan_hash,
            out_dir=args.out_dir,
            cmaddr=args.cmaddr,
            timeout_seconds=args.timeout_seconds,
            cs_python=args.cs_python,
            adapter=args.adapter,
            dry_run=args.dry_run,
            cslc=args.cslc,
            dense_gemv_tile_height=args.dense_gemv_tile_height,
            dense_gemv_hidden_tile_width=args.dense_gemv_hidden_tile_width,
            dense_gemv_allow_unsafe_tile_shapes=(
                args.dense_gemv_allow_unsafe_tile_shapes
            ),
            dense_gemv_reuse_verified_tile_partials=(
                args.dense_gemv_reuse_verified_tile_partials
            ),
            dense_gemv_tile_dispatch_budget=(
                args.dense_gemv_tile_dispatch_budget
            ),
            dense_gemv_tile_dispatch_jobs=(
                args.dense_gemv_tile_dispatch_jobs
            ),
            dense_gemv_max_row_tile_height=(
                args.dense_gemv_max_row_tile_height
            ),
            dense_gemv_batch_runtime=args.dense_gemv_batch_runtime,
            dense_gemv_batch_runtime_step_budget=(
                args.dense_gemv_batch_runtime_step_budget
            ),
            dense_gemv_tile_y_range=args.dense_gemv_tile_y_range,
            dense_gemv_finalize_from_tile_receipts=(
                args.dense_gemv_finalize_from_tile_receipts
            ),
            dense_gemv_worker_id=(
                args.dense_gemv_worker_id
                or worker_id_from_range(
                    args.dense_gemv_tile_y_range,
                    fallback=kernel,
                )
                if args.dense_gemv_partial_only_worker
                else ""
            ),
        )
        try:
            if args.dense_gemv_partial_only_worker:
                worker_root = (
                    args.dense_gemv_worker_receipt_dir
                    or args.out_dir
                )
                worker_id = (
                    args.dense_gemv_worker_id
                    or worker_id_from_range(
                        args.dense_gemv_tile_y_range,
                        fallback=kernel,
                    )
                )
                receipt["denseGemvWorker"] = {
                    "kind": "partial_only_worker",
                    "workerId": worker_id,
                    "tileYRange": {
                        "start": args.dense_gemv_tile_y_range[0],
                        "endExclusive": args.dense_gemv_tile_y_range[1],
                    },
                }
                write_worker_receipt(
                    receipt=receipt,
                    out_dir=worker_root,
                    worker_id=worker_id,
                )
            else:
                write_kernel_receipt(receipt=receipt, out_dir=args.out_dir)
        except ReceiptHashSpineError as err:
            raise RuntimeError(
                f"kernel {kernel!r} hash spine rejected emit: {err}"
            ) from err
        return kernel, receipt, False

    try:
        if args.jobs == 1:
            for target in targets:
                kernel, receipt, reused = run_target(target)
                receipts_by_kernel[kernel] = receipt
                if reused:
                    reused_count += 1
                if receipt["verdict"] == "blocked":
                    blocked_count += 1
        else:
            with ThreadPoolExecutor(max_workers=args.jobs) as executor:
                futures = {
                    executor.submit(run_target, target): str(target["name"])
                    for target in targets
                }
                for future in as_completed(futures):
                    kernel, receipt, reused = future.result()
                    receipts_by_kernel[kernel] = receipt
                    if reused:
                        reused_count += 1
                    if receipt["verdict"] == "blocked":
                        blocked_count += 1
    except RuntimeError as err:
        sys.stderr.write(f"manifest_kernel_probe_runner: {err}\n")
        return 2

    if args.dense_gemv_partial_only_worker:
        worker_root = args.dense_gemv_worker_receipt_dir or args.out_dir
        print(
            f"wrote {len(receipts_by_kernel)} dense-GEMV worker receipt(s) "
            f"under {worker_root / 'worker-receipts'} "
            f"(blocked={blocked_count}, reused={reused_count}, "
            f"jobs={args.jobs}, schedule={args.schedule})"
        )
        expected_blockers = {
            None,
            "dense_gemv_width_tile_y_range_partial_coverage",
            "dense_gemv_width_tile_dispatch_budget_exhausted",
        }
        unexpected = [
            r.get("blocker") for r in receipts_by_kernel.values()
            if r.get("blocker") not in expected_blockers
        ]
        return 1 if unexpected else 0

    summary_receipts_by_kernel = load_existing_receipts_for_summary(
        out_dir=args.out_dir,
        host_plan_hash=host_plan_hash,
    )
    summary_receipts_by_kernel.update(receipts_by_kernel)
    receipts = [
        summary_receipts_by_kernel[str(target["name"])]
        for target in summary_targets
        if str(target["name"]) in summary_receipts_by_kernel
    ]

    try:
        write_summary(
            out_dir=args.out_dir,
            receipts=receipts,
            host_plan_path=args.host_plan,
            host_plan_hash=host_plan_hash,
        )
    except ReceiptHashSpineError as err:
        sys.stderr.write(
            f"manifest_kernel_probe_runner: summary hash spine rejected: "
            f"{err}\n"
        )
        return 2

    print(
        f"wrote {len(receipts)} per-kernel receipt(s) to {args.out_dir} "
        f"(blocked={blocked_count}, reused={reused_count}, jobs={args.jobs}, "
        f"schedule={args.schedule})"
    )
    return 1 if blocked_count else 0


if __name__ == "__main__":
    sys.exit(main())
