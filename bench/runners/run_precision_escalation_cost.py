#!/usr/bin/env python3
"""Measure per-operator GPU cost of precision escalation from f16 to f32 accumulation.

For each known f16-flip case, runs the matmul_logits kernel in both f16accum and
f32 accumulation modes, measures wall time and (when available) GPU timestamps,
and produces a cost model: how much latency does fixing each flip add?

Outputs a JSON report to bench/out/precision-escalation-cost/ with per-case
timing, aggregate statistics, and Pareto curve data for severity-ordered
escalation.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import statistics
import struct
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from bench.lib.bench_utils import load_json
from bench.runners.run_determinism_probe import (
    RUNTIME_BIN,
    runtime_env,
)

DEFAULT_EXERCISE_DIR = REPO_ROOT / "bench" / "out" / "cross-domain-f16-flip-exercise"
DEFAULT_OUTPUT_ROOT = REPO_ROOT / "bench" / "out" / "precision-escalation-cost"
KERNEL_ROOT = REPO_ROOT / "bench" / "inference-pipeline" / "kernels"

F16_KERNEL = "matmul_logits_forward_f16accum.wgsl"
F32_KERNEL = "matmul_logits_forward_f32.wgsl"

DEFAULT_BACKEND_LANE = "metal_doe_app"
DEFAULT_ITERATIONS = 10
WARMUP_ITERATIONS = 2

HANDLE_PARAMS = 4201
HANDLE_HIDDEN = 4202
HANDLE_WEIGHTS_BASE = 4203
HANDLE_OUTPUT = 4204
HANDLE_SAMPLE_PARAMS = 4210
HANDLE_SAMPLE_OUTPUT = 4205


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--exercise-report",
        default=None,
        help="Path to exercise-report.json from exercise_cross_domain_flips.py. "
             "If omitted, uses the most recent report under the default exercise dir.",
    )
    parser.add_argument(
        "--iterations",
        type=int,
        default=DEFAULT_ITERATIONS,
        help=f"Number of timed iterations per variant (default: {DEFAULT_ITERATIONS}).",
    )
    parser.add_argument(
        "--warmup",
        type=int,
        default=WARMUP_ITERATIONS,
        help=f"Number of warmup iterations before timed runs (default: {WARMUP_ITERATIONS}).",
    )
    parser.add_argument(
        "--backend-lane",
        default=DEFAULT_BACKEND_LANE,
        help=f"Backend lane for the Doe runtime (default: {DEFAULT_BACKEND_LANE}).",
    )
    parser.add_argument(
        "--gpu-timestamp-mode",
        choices=["auto", "off", "require"],
        default="auto",
        help="GPU timestamp query mode (default: auto).",
    )
    parser.add_argument(
        "--output-dir",
        default=None,
        help="Output directory (default: bench/out/precision-escalation-cost/<timestamp>).",
    )
    parser.add_argument(
        "--max-cases",
        type=int,
        default=None,
        help="Limit the number of cases to process (for quick testing).",
    )
    parser.add_argument(
        "--timestamp",
        default=None,
        help="UTC timestamp label (default: current UTC time).",
    )
    return parser.parse_args()


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def timestamp_label(raw: str | None) -> str:
    if raw:
        return raw
    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def find_latest_exercise_report(exercise_dir: Path) -> Path:
    """Find the most recent exercise-report.json under the exercise output directory."""
    candidates = sorted(exercise_dir.iterdir()) if exercise_dir.is_dir() else []
    for stamp_dir in reversed(candidates):
        report = stamp_dir / "exercise-report.json"
        if report.is_file():
            return report
    raise FileNotFoundError(
        f"no exercise-report.json found under {exercise_dir}; "
        f"run exercise_cross_domain_flips.py first or specify --exercise-report"
    )


def encode_f32_as_u32_list(values: list[float]) -> list[int]:
    """Encode a list of f32 values as their u32 bit-pattern representation."""
    return [
        struct.unpack("<I", struct.pack("<f", v))[0]
        for v in values
    ]


def build_params_data(rows: int, cols: int) -> list[int]:
    """Build the uniform params buffer data: [rows, cols, pad, pad]."""
    return [rows, cols, 0, 0]


def build_command_file(
    *,
    kernel_name: str,
    hidden_state_u32: list[int],
    weight_rows_u32: list[list[int]],
    num_candidates: int,
    cols: int,
) -> list[dict[str, Any]]:
    """Build a command file JSON for a single matmul_logits + sample dispatch.

    The command file writes params, hidden state, and weights into buffers,
    then dispatches the specified kernel, followed by a sample kernel.
    """
    params_data = build_params_data(num_candidates, cols)
    flat_weights = []
    for row in weight_rows_u32:
        flat_weights.extend(row)

    commands: list[dict[str, Any]] = [
        {
            "kind": "buffer_write",
            "handle": HANDLE_PARAMS,
            "bufferSize": 16,
            "data": params_data,
        },
        {
            "kind": "buffer_write",
            "handle": HANDLE_HIDDEN,
            "bufferSize": len(hidden_state_u32) * 4,
            "data": hidden_state_u32,
        },
        {
            "kind": "buffer_write",
            "handle": HANDLE_WEIGHTS_BASE,
            "bufferSize": len(flat_weights) * 4,
            "data": flat_weights,
        },
        {
            "kind": "buffer_write",
            "handle": HANDLE_SAMPLE_PARAMS,
            "bufferSize": 16,
            "data": [num_candidates, 0, 0, 0],
        },
        {
            "kind": "kernel_dispatch",
            "kernel": kernel_name,
            "x": num_candidates,
            "y": 1,
            "z": 1,
            "initialize_buffers_on_create": True,
            "semanticOpId": "matmul.logits",
            "semanticStage": "precision_escalation_cost",
            "semanticPhase": "logits",
            "semanticExecutionPlanHash": "escalation-cost",
            "captureBufferHandle": HANDLE_OUTPUT,
            "captureOffset": 0,
            "captureSize": num_candidates * 4,
            "bindings": [
                {
                    "binding": 0,
                    "group": 0,
                    "kind": "buffer",
                    "buffer_type": "uniform",
                    "resource_handle": HANDLE_PARAMS,
                    "buffer_size": 16,
                    "visibility": "compute",
                },
                {
                    "binding": 1,
                    "group": 0,
                    "kind": "buffer",
                    "buffer_type": "readonly",
                    "resource_handle": HANDLE_HIDDEN,
                    "buffer_size": len(hidden_state_u32) * 4,
                    "visibility": "compute",
                },
                {
                    "binding": 2,
                    "group": 0,
                    "kind": "buffer",
                    "buffer_type": "readonly",
                    "resource_handle": HANDLE_WEIGHTS_BASE,
                    "buffer_size": len(flat_weights) * 4,
                    "visibility": "compute",
                },
                {
                    "binding": 3,
                    "group": 0,
                    "kind": "buffer",
                    "buffer_type": "storage",
                    "resource_handle": HANDLE_OUTPUT,
                    "buffer_size": num_candidates * 4,
                    "visibility": "compute",
                },
            ],
        },
        {
            "kind": "kernel_dispatch",
            "kernel": "sample.wgsl",
            "x": 1,
            "y": 1,
            "z": 1,
            "initialize_buffers_on_create": True,
            "semanticOpId": "sample.token",
            "semanticStage": "precision_escalation_cost",
            "semanticPhase": "sample_token",
            "semanticExecutionPlanHash": "escalation-cost",
            "captureBufferHandle": HANDLE_SAMPLE_OUTPUT,
            "captureOffset": 0,
            "captureSize": 4,
            "decode": "u32le",
            "bindings": [
                {
                    "binding": 0,
                    "group": 0,
                    "kind": "buffer",
                    "buffer_type": "uniform",
                    "resource_handle": HANDLE_SAMPLE_PARAMS,
                    "buffer_size": 16,
                    "visibility": "compute",
                },
                {
                    "binding": 1,
                    "group": 0,
                    "kind": "buffer",
                    "buffer_type": "readonly",
                    "resource_handle": HANDLE_OUTPUT,
                    "buffer_size": num_candidates * 4,
                    "visibility": "compute",
                },
                {
                    "binding": 2,
                    "group": 0,
                    "kind": "buffer",
                    "buffer_type": "storage",
                    "resource_handle": HANDLE_SAMPLE_OUTPUT,
                    "buffer_size": 4,
                    "visibility": "compute",
                },
            ],
        },
    ]
    return commands


def run_runtime(
    *,
    commands_path: Path,
    trace_meta_path: Path,
    trace_jsonl_path: Path,
    backend_lane: str,
    gpu_timestamp_mode: str,
) -> tuple[float, dict[str, Any]]:
    """Run the Doe runtime on a command file and return (wall_time_s, trace_meta).

    Wall time is measured with time.perf_counter() around the subprocess call.
    This includes CPU overhead from process launch; document this limitation.
    """
    command = [
        str(RUNTIME_BIN),
        "--commands", str(commands_path),
        "--quirk-mode", "trace",
        "--vendor", "apple",
        "--api", "metal",
        "--family", "apple",
        "--driver", "1.0.0",
        "--backend", "native",
        "--backend-lane", backend_lane,
        "--execute",
        "--trace",
        "--trace-jsonl", str(trace_jsonl_path),
        "--trace-meta", str(trace_meta_path),
        "--kernel-root", str(KERNEL_ROOT),
        "--queue-wait-mode", "process-events",
        "--queue-sync-mode", "per-command",
        "--gpu-timestamp-mode", gpu_timestamp_mode,
    ]
    wall_start = time.perf_counter()
    completed = subprocess.run(
        command,
        cwd=REPO_ROOT,
        env=runtime_env(backend_lane),
        capture_output=True,
        text=True,
        check=False,
    )
    wall_elapsed = time.perf_counter() - wall_start

    if completed.returncode != 0:
        raise RuntimeError(
            f"runtime failed (exit {completed.returncode})\n"
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )

    meta = load_json(trace_meta_path)
    return wall_elapsed, meta


def extract_timing_from_meta(meta: dict[str, Any]) -> dict[str, Any]:
    """Extract timing fields from trace meta JSON."""
    return {
        "executionTotalNs": meta.get("executionTotalNs", 0),
        "executionSetupTotalNs": meta.get("executionSetupTotalNs", 0),
        "executionEncodeTotalNs": meta.get("executionEncodeTotalNs", 0),
        "executionSubmitWaitTotalNs": meta.get("executionSubmitWaitTotalNs", 0),
        "executionGpuTimestampTotalNs": meta.get("executionGpuTimestampTotalNs", 0),
        "executionGpuTimestampAttemptedCount": meta.get("executionGpuTimestampAttemptedCount", 0),
        "executionGpuTimestampValidCount": meta.get("executionGpuTimestampValidCount", 0),
    }


def extract_per_command_timing(trace_jsonl_path: Path) -> list[dict[str, Any]]:
    """Extract per-command timing from the trace JSONL output.

    Returns a list of timing records for kernel_dispatch commands.
    """
    if not trace_jsonl_path.is_file():
        return []
    records = []
    for line in trace_jsonl_path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        try:
            row = json.loads(stripped)
        except json.JSONDecodeError:
            continue
        if row.get("commandKind") == "kernel_dispatch" or "executionDurationNs" in row:
            records.append({
                "semanticOpId": row.get("semanticOpId"),
                "executionDurationNs": row.get("executionDurationNs", 0),
                "executionGpuTimestampNs": row.get("executionGpuTimestampNs", 0),
                "executionGpuTimestampValid": row.get("executionGpuTimestampValid", 0),
            })
    return records


def compute_stats(values: list[float]) -> dict[str, float]:
    """Compute summary statistics for a list of numeric values."""
    if not values:
        return {
            "count": 0, "mean": 0.0, "median": 0.0, "stddev": 0.0,
            "min": 0.0, "max": 0.0, "p5": 0.0, "p50": 0.0, "p95": 0.0,
        }
    sorted_values = sorted(values)
    n = len(sorted_values)
    return {
        "count": n,
        "mean": statistics.mean(values),
        "median": statistics.median(values),
        "stddev": statistics.stdev(values) if n > 1 else 0.0,
        "min": sorted_values[0],
        "max": sorted_values[-1],
        "p5": sorted_values[max(0, int(n * 0.05))],
        "p50": sorted_values[int(n * 0.50)],
        "p95": sorted_values[min(n - 1, int(n * 0.95))],
    }


def reconstruct_input_data(case: dict[str, Any]) -> tuple[list[int], list[list[int]], int]:
    """Reconstruct hidden state and weight data from exercise case logits.

    The exercise report contains fastCandidateLogits and stableCandidateLogits
    but not the raw hidden state / weight data. We construct synthetic input
    data that produces the same logit values by using identity-like patterns.

    For cost measurement purposes the kernel execution time depends on the
    matrix dimensions (rows x cols), not the specific data values. We use the
    number of candidates (rows) and a representative column dimension.
    """
    num_candidates = len(case.get("options", []))
    if num_candidates < 2:
        num_candidates = 2

    # Use a representative hidden dimension for the model.
    # Gemma 270m uses 1536-dim hidden states, but for cost measurement
    # we use a configurable dimension. The exercise cases from the
    # f16accum-sweep use 640-dim.
    cols = 640

    # Synthetic hidden state: ones (the cost is dominated by the loop length)
    hidden_f32 = [1.0] * cols
    hidden_u32 = encode_f32_as_u32_list(hidden_f32)

    # Synthetic weight rows: small values that exercise the accumulation path
    weight_rows_u32 = []
    for i in range(num_candidates):
        row_f32 = [0.01 * (i + 1)] * cols
        weight_rows_u32.append(encode_f32_as_u32_list(row_f32))

    return hidden_u32, weight_rows_u32, cols


def run_variant_timing(
    *,
    case_id: str,
    kernel_name: str,
    variant_label: str,
    hidden_u32: list[int],
    weight_rows_u32: list[list[int]],
    num_candidates: int,
    cols: int,
    iterations: int,
    warmup: int,
    work_dir: Path,
    backend_lane: str,
    gpu_timestamp_mode: str,
) -> dict[str, Any]:
    """Run a kernel variant multiple times and collect timing data."""
    commands = build_command_file(
        kernel_name=kernel_name,
        hidden_state_u32=hidden_u32,
        weight_rows_u32=weight_rows_u32,
        num_candidates=num_candidates,
        cols=cols,
    )

    variant_dir = work_dir / f"{case_id}" / variant_label
    variant_dir.mkdir(parents=True, exist_ok=True)

    commands_path = variant_dir / "commands.json"
    commands_bytes = (json.dumps(commands, separators=(",", ":")) + "\n").encode("utf-8")
    commands_path.write_bytes(commands_bytes)

    wall_times: list[float] = []
    execution_total_ns_list: list[int] = []
    gpu_timestamp_ns_list: list[int] = []
    matmul_duration_ns_list: list[int] = []
    matmul_gpu_ns_list: list[int] = []

    total_runs = warmup + iterations
    for run_idx in range(total_runs):
        trace_meta_path = variant_dir / f"run{run_idx:03d}.meta.json"
        trace_jsonl_path = variant_dir / f"run{run_idx:03d}.trace.jsonl"

        wall_s, meta = run_runtime(
            commands_path=commands_path,
            trace_meta_path=trace_meta_path,
            trace_jsonl_path=trace_jsonl_path,
            backend_lane=backend_lane,
            gpu_timestamp_mode=gpu_timestamp_mode,
        )

        # Skip warmup runs
        if run_idx < warmup:
            continue

        wall_times.append(wall_s * 1_000_000)  # convert to microseconds

        timing = extract_timing_from_meta(meta)
        execution_total_ns_list.append(timing["executionTotalNs"])
        gpu_timestamp_ns_list.append(timing["executionGpuTimestampTotalNs"])

        # Per-command timing from JSONL
        per_cmd = extract_per_command_timing(trace_jsonl_path)
        for record in per_cmd:
            if record.get("semanticOpId") == "matmul.logits":
                matmul_duration_ns_list.append(record["executionDurationNs"])
                if record["executionGpuTimestampValid"]:
                    matmul_gpu_ns_list.append(record["executionGpuTimestampNs"])

    gpu_available = len(matmul_gpu_ns_list) > 0
    matmul_gpu_us = [ns / 1000.0 for ns in matmul_gpu_ns_list] if gpu_available else []
    matmul_duration_us = [ns / 1000.0 for ns in matmul_duration_ns_list]
    execution_total_us = [ns / 1000.0 for ns in execution_total_ns_list]

    # Choose the best available timing source
    if gpu_available:
        primary_timing_us = matmul_gpu_us
        timing_source = "gpu_timestamp"
    elif matmul_duration_ns_list:
        primary_timing_us = matmul_duration_us
        timing_source = "execution_duration"
    else:
        primary_timing_us = wall_times
        timing_source = "wall_clock"

    return {
        "variantLabel": variant_label,
        "kernelName": kernel_name,
        "iterations": iterations,
        "warmup": warmup,
        "timingSource": timing_source,
        "gpuTimestampAvailable": gpu_available,
        "primaryTimingUs": primary_timing_us,
        "primaryStats": compute_stats(primary_timing_us),
        "wallTimeUs": wall_times,
        "wallTimeStats": compute_stats(wall_times),
        "executionTotalUs": execution_total_us,
        "executionTotalStats": compute_stats(execution_total_us),
        "matmulDurationUs": matmul_duration_us,
        "matmulDurationStats": compute_stats(matmul_duration_us),
        "matmulGpuUs": matmul_gpu_us,
        "matmulGpuStats": compute_stats(matmul_gpu_us) if gpu_available else None,
        "timingLimitation": (
            "Wall-clock timing includes subprocess launch and CPU overhead. "
            "Execution duration is host-side command timing. "
            "GPU timestamp (when available) is the most accurate GPU-only measurement."
        ),
    }


def compute_case_cost(
    f16_result: dict[str, Any],
    f32_result: dict[str, Any],
) -> dict[str, Any]:
    """Compute the cost delta of escalating from f16 to f32 for a single case."""
    f16_median = f16_result["primaryStats"]["median"]
    f32_median = f32_result["primaryStats"]["median"]
    delta_us = f32_median - f16_median

    f16_mean = f16_result["primaryStats"]["mean"]
    f32_mean = f32_result["primaryStats"]["mean"]
    delta_mean_us = f32_mean - f16_mean

    # Relative overhead
    relative_overhead = delta_us / f16_median if f16_median > 0 else float("inf")

    return {
        "f16MedianUs": f16_median,
        "f32MedianUs": f32_median,
        "deltaMedianUs": delta_us,
        "f16MeanUs": f16_mean,
        "f32MeanUs": f32_mean,
        "deltaMeanUs": delta_mean_us,
        "relativeOverhead": relative_overhead,
        "timingSource": f16_result["timingSource"],
    }


def build_pareto_curve(
    case_costs: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """Build Pareto curve data: sort flips by severity, accumulate escalation cost.

    X-axis: number of operators escalated (sorted by flip severity, most severe first)
    Y-axis: cumulative added latency in microseconds
    """
    # Sort by f32Gap (severity) descending: most severe flips first
    sorted_costs = sorted(case_costs, key=lambda c: c.get("flipSeverity", 0), reverse=True)

    curve = []
    cumulative_us = 0.0
    for i, cost in enumerate(sorted_costs):
        delta = cost["costDelta"]["deltaMedianUs"]
        cumulative_us += max(delta, 0)  # only count positive deltas
        curve.append({
            "operatorsEscalated": i + 1,
            "caseId": cost["caseId"],
            "flipSeverity": cost.get("flipSeverity", 0),
            "deltaUs": delta,
            "cumulativeUs": cumulative_us,
            "flipsFixedPerUs": (i + 1) / cumulative_us if cumulative_us > 0 else float("inf"),
        })

    return curve


def main() -> int:
    args = parse_args()

    if not RUNTIME_BIN.exists():
        print(f"ERROR: runtime binary missing: {RUNTIME_BIN}", file=sys.stderr)
        return 1

    # Find exercise report
    if args.exercise_report:
        exercise_report_path = Path(args.exercise_report)
    else:
        exercise_report_path = find_latest_exercise_report(DEFAULT_EXERCISE_DIR)
    print(f"Using exercise report: {exercise_report_path}", file=sys.stderr)

    exercise = load_json(exercise_report_path)
    cases = exercise.get("cases", [])
    if not cases:
        print("ERROR: exercise report contains no cases", file=sys.stderr)
        return 1

    if args.max_cases:
        cases = cases[:args.max_cases]

    stamp = timestamp_label(args.timestamp)
    output_dir = Path(args.output_dir) if args.output_dir else DEFAULT_OUTPUT_ROOT / stamp
    output_dir.mkdir(parents=True, exist_ok=True)
    work_dir = output_dir / "runs"
    work_dir.mkdir(parents=True, exist_ok=True)

    print(
        f"Measuring precision escalation cost for {len(cases)} flip cases "
        f"({args.warmup} warmup + {args.iterations} timed iterations per variant)",
        file=sys.stderr,
    )

    case_results: list[dict[str, Any]] = []
    t0 = time.time()

    for case_idx, case in enumerate(cases):
        case_id = case["caseId"]
        f32_gap = case.get("f32Gap", 0)
        num_candidates = len(case.get("options", []))

        print(
            f"  [{case_idx + 1}/{len(cases)}] {case_id} "
            f"(gap={f32_gap:.6f}, candidates={num_candidates})...",
            file=sys.stderr,
            end="",
            flush=True,
        )

        hidden_u32, weight_rows_u32, cols = reconstruct_input_data(case)

        # Run f16 variant
        try:
            f16_result = run_variant_timing(
                case_id=case_id,
                kernel_name=F16_KERNEL,
                variant_label="f16accum",
                hidden_u32=hidden_u32,
                weight_rows_u32=weight_rows_u32,
                num_candidates=num_candidates,
                cols=cols,
                iterations=args.iterations,
                warmup=args.warmup,
                work_dir=work_dir,
                backend_lane=args.backend_lane,
                gpu_timestamp_mode=args.gpu_timestamp_mode,
            )
        except RuntimeError as e:
            print(f" f16 FAILED: {e}", file=sys.stderr)
            continue

        # Run f32 variant
        try:
            f32_result = run_variant_timing(
                case_id=case_id,
                kernel_name=F32_KERNEL,
                variant_label="f32",
                hidden_u32=hidden_u32,
                weight_rows_u32=weight_rows_u32,
                num_candidates=num_candidates,
                cols=cols,
                iterations=args.iterations,
                warmup=args.warmup,
                work_dir=work_dir,
                backend_lane=args.backend_lane,
                gpu_timestamp_mode=args.gpu_timestamp_mode,
            )
        except RuntimeError as e:
            print(f" f32 FAILED: {e}", file=sys.stderr)
            continue

        cost_delta = compute_case_cost(f16_result, f32_result)

        entry = {
            "caseId": case_id,
            "promptId": case.get("promptId"),
            "answerSetId": case.get("answerSetId"),
            "promptText": case.get("promptText", "")[:100],
            "flipSeverity": f32_gap,
            "numCandidates": num_candidates,
            "cols": cols,
            "routeDecision": case.get("routeDecision"),
            "f16": f16_result,
            "f32": f32_result,
            "costDelta": cost_delta,
        }
        case_results.append(entry)

        print(
            f" delta={cost_delta['deltaMedianUs']:+.1f}us "
            f"(f16={cost_delta['f16MedianUs']:.1f} f32={cost_delta['f32MedianUs']:.1f}) "
            f"[{cost_delta['timingSource']}]",
            file=sys.stderr,
        )

    total_time = time.time() - t0

    if not case_results:
        print("ERROR: no cases completed successfully", file=sys.stderr)
        return 1

    # Aggregate statistics
    all_deltas = [c["costDelta"]["deltaMedianUs"] for c in case_results]
    all_f16_medians = [c["costDelta"]["f16MedianUs"] for c in case_results]
    all_f32_medians = [c["costDelta"]["f32MedianUs"] for c in case_results]

    aggregate = {
        "caseCount": len(case_results),
        "deltaStats": compute_stats(all_deltas),
        "f16Stats": compute_stats(all_f16_medians),
        "f32Stats": compute_stats(all_f32_medians),
    }

    # Pareto curve
    pareto = build_pareto_curve(case_results)

    # Determine timing source used
    timing_sources = set(c["costDelta"]["timingSource"] for c in case_results)
    primary_timing_source = timing_sources.pop() if len(timing_sources) == 1 else "mixed"
    gpu_available_all = all(c["f16"]["gpuTimestampAvailable"] for c in case_results)

    report = {
        "schemaVersion": 1,
        "source": "doe-precision-escalation-cost",
        "timestamp": stamp,
        "exerciseReportPath": str(exercise_report_path),
        "config": {
            "iterations": args.iterations,
            "warmup": args.warmup,
            "backendLane": args.backend_lane,
            "gpuTimestampMode": args.gpu_timestamp_mode,
            "kernelF16": F16_KERNEL,
            "kernelF32": F32_KERNEL,
            "kernelRoot": str(KERNEL_ROOT),
        },
        "timingMethodology": {
            "primarySource": primary_timing_source,
            "gpuTimestampAvailable": gpu_available_all,
            "wallClockNote": (
                "Wall-clock measurements include subprocess launch overhead "
                "and are not suitable for absolute GPU timing. Use GPU "
                "timestamps or execution-duration for per-dispatch cost."
            ),
            "warmupPolicy": (
                f"{args.warmup} warmup iterations discarded before "
                f"{args.iterations} timed iterations."
            ),
        },
        "aggregate": aggregate,
        "paretoCurve": pareto,
        "cases": case_results,
        "totalTimeSeconds": round(total_time, 1),
    }

    report_path = output_dir / "precision-escalation-cost.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    # Print summary
    print(f"\n{'=' * 80}", file=sys.stderr)
    print(f"Precision escalation cost measurement complete", file=sys.stderr)
    print(f"  Cases measured: {len(case_results)}", file=sys.stderr)
    print(f"  Timing source: {primary_timing_source}", file=sys.stderr)
    print(f"  GPU timestamps available: {gpu_available_all}", file=sys.stderr)
    print(f"  Mean delta: {aggregate['deltaStats']['mean']:+.2f} us", file=sys.stderr)
    print(f"  Median delta: {aggregate['deltaStats']['median']:+.2f} us", file=sys.stderr)
    print(f"  P95 delta: {aggregate['deltaStats']['p95']:+.2f} us", file=sys.stderr)
    print(f"  Total time: {total_time:.1f}s", file=sys.stderr)

    if pareto:
        last = pareto[-1]
        print(
            f"  Pareto: escalating all {last['operatorsEscalated']} flips "
            f"adds {last['cumulativeUs']:.1f} us cumulative",
            file=sys.stderr,
        )

    print(f"  Report: {report_path}", file=sys.stderr)
    print(str(report_path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
