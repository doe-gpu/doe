#!/usr/bin/env python3
"""Harvest sampled decode-boundary receipts from ordinary Doe execution."""

from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in sys.path:
        sys.path.insert(0, _path_entry)

from bench.lib.bench_utils import load_json
from bench.lib.config_validation import load_validated_config
from bench.lib.sampled_decode_fragility import (
    CASE_REPORT_FILE_NAME,
    COMMANDS_FILE_NAME,
    MANIFEST_FILE_NAME,
    TRACE_JSONL_FILE_NAME,
    TRACE_META_FILE_NAME,
    decode_rows_by_step,
    find_runtime_bin,
    load_jsonl,
    patch_commands_for_sampled_decode,
    repo_rel,
    write_json,
)


DEFAULT_PLAN_PATH = REPO_ROOT / "config" / "numeric-stability-decode-harvest-plan.json"
DEFAULT_OUTPUT_ROOT = REPO_ROOT / "bench" / "out" / "apple-metal-sampled-decode-fragility"
ARTIFACT_KIND = "sampled-decode-fragility-harvest"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", default=str(DEFAULT_PLAN_PATH), help="Harvest plan JSON path.")
    parser.add_argument("--timestamp", default=None, help="UTC timestamp label.")
    parser.add_argument("--runtime-bin", default=None, help="Explicit doe-zig-runtime path.")
    parser.add_argument("--output-root", default=str(DEFAULT_OUTPUT_ROOT), help="Output root.")
    return parser.parse_args()


def timestamp_label() -> str:
    import datetime as dt

    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def resolved_path(path_value: str | None, *, default: Path | None = None) -> Path | None:
    if path_value is None:
        return default
    path = Path(path_value)
    return path if path.is_absolute() else (REPO_ROOT / path)


def merged_sample_config(plan: dict[str, Any], case: dict[str, Any]) -> dict[str, Any]:
    merged = dict(plan["sampleConfig"])
    merged.update(case.get("sampleConfig") or {})
    return merged


def merged_backend(plan: dict[str, Any], case: dict[str, Any]) -> dict[str, Any]:
    backend = dict(plan["backend"])
    backend.update(case.get("backend") or {})
    return backend


def run_runtime(
    *,
    runtime_bin: Path,
    commands_path: Path,
    kernel_root: Path,
    trace_meta_path: Path,
    trace_jsonl_path: Path,
    policy_path: Path,
    execution_profile_id: str,
    backend: dict[str, Any],
) -> int:
    start_ns = time.perf_counter_ns()
    result = subprocess.run(
        [
            str(runtime_bin),
            "--commands",
            str(commands_path),
            "--trace-meta",
            str(trace_meta_path),
            "--trace-jsonl",
            str(trace_jsonl_path),
            "--numeric-stability-policy",
            str(policy_path),
            "--numeric-stability-execution-profile",
            execution_profile_id,
            "--kernel-root",
            str(kernel_root),
            "--backend",
            "native",
            "--execute",
            "--vendor",
            str(backend["vendor"]),
            "--api",
            str(backend["api"]),
            "--family",
            str(backend["family"]),
            "--driver",
            str(backend["driver"]),
            "--backend-lane",
            str(backend["backendLane"]),
        ],
        cwd=REPO_ROOT,
        check=False,
        text=True,
        capture_output=True,
    )
    elapsed_ns = time.perf_counter_ns() - start_ns
    if result.returncode != 0:
        raise RuntimeError(
            f"doe-zig-runtime failed ({result.returncode})\nstdout:\n{result.stdout}\n\nstderr:\n{result.stderr}"
        )
    return elapsed_ns


def receipt_path_from_trace_meta(trace_meta_path: Path) -> Path:
    return trace_meta_path.with_name(trace_meta_path.name + ".numeric-stability.jsonl")


def write_step_receipts(case_dir: Path, repeat_label: str, receipts: list[dict[str, Any]]) -> list[str]:
    receipt_paths: list[str] = []
    receipts_dir = case_dir / "receipts" / repeat_label
    for receipt in decode_rows_by_step(receipts):
        semantic_stage = str(receipt.get("semanticStage") or "decode").replace("/", "-")
        semantic_op_id = str(receipt["semanticOpId"]).replace("/", "-")
        step_path = receipts_dir / f"{semantic_stage}__{semantic_op_id}.receipt.json"
        write_json(step_path, receipt)
        receipt_paths.append(repo_rel(step_path))
    return receipt_paths


def exercise_case(
    *,
    runtime_bin: Path,
    case: dict[str, Any],
    plan: dict[str, Any],
    output_dir: Path,
) -> dict[str, Any]:
    case_dir = output_dir / str(case["caseId"])
    case_dir.mkdir(parents=True, exist_ok=True)
    commands_path = resolved_path(case["commandsPath"])
    if commands_path is None:
        raise ValueError(f"case {case['caseId']} is missing commandsPath")
    commands = load_json(commands_path)
    patched_commands = patch_commands_for_sampled_decode(
        commands,
        semantic_stage=str(case["caseId"]),
        sample_config=merged_sample_config(plan, case),
        max_sample_steps=case.get("maxSampleStepsToCapture"),
    )
    patched_commands_path = case_dir / COMMANDS_FILE_NAME
    write_json(patched_commands_path, patched_commands)

    kernel_root = resolved_path(case.get("kernelRoot"), default=resolved_path(plan.get("kernelRoot"), default=REPO_ROOT))
    if kernel_root is None:
        kernel_root = REPO_ROOT
    policy_path = resolved_path(plan.get("policyPath"), default=REPO_ROOT / "config" / "numeric-stability-policy.json")
    if policy_path is None:
        raise ValueError("harvest plan must define policyPath or rely on the default registry")

    repeat_count = int(case.get("repeatCount", plan["repeatCount"]))
    backend = merged_backend(plan, case)
    repeat_reports: list[dict[str, Any]] = []
    case_status = "success"
    case_error: str | None = None
    total_decode_receipts = 0

    for repeat_index in range(repeat_count):
        repeat_label = f"repeat-{repeat_index + 1:02d}"
        repeat_dir = case_dir / repeat_label
        repeat_dir.mkdir(parents=True, exist_ok=True)
        trace_meta_path = repeat_dir / TRACE_META_FILE_NAME
        trace_jsonl_path = repeat_dir / TRACE_JSONL_FILE_NAME
        repeat_report: dict[str, Any] = {
            "repeatLabel": repeat_label,
            "traceMetaPath": repo_rel(trace_meta_path),
            "traceJsonlPath": repo_rel(trace_jsonl_path),
        }
        try:
            elapsed_ns = run_runtime(
                runtime_bin=runtime_bin,
                commands_path=patched_commands_path,
                kernel_root=kernel_root,
                trace_meta_path=trace_meta_path,
                trace_jsonl_path=trace_jsonl_path,
                policy_path=policy_path,
                execution_profile_id=str(
                    case.get("executionProfileId") or plan["executionProfileId"]
                ),
                backend=backend,
            )
            numeric_receipt_path = receipt_path_from_trace_meta(trace_meta_path)
            numeric_receipts = load_jsonl(numeric_receipt_path)
            decode_receipts = decode_rows_by_step(numeric_receipts)
            if not decode_receipts:
                raise RuntimeError(f"{numeric_receipt_path} did not contain decode.sample_token receipts")
            step_receipt_paths = write_step_receipts(case_dir, repeat_label, decode_receipts)
            total_decode_receipts += len(decode_receipts)
            repeat_report.update(
                {
                    "status": "success",
                    "elapsedNs": elapsed_ns,
                    "numericReceiptPath": repo_rel(numeric_receipt_path),
                    "decodeReceiptCount": len(decode_receipts),
                    "decodeReceiptPaths": step_receipt_paths,
                }
            )
        except Exception as exc:  # noqa: BLE001
            case_status = "failed"
            case_error = str(exc)
            repeat_report.update({"status": "failed", "error": str(exc)})
        repeat_reports.append(repeat_report)

    report = {
        "schemaVersion": 1,
        "artifactKind": "sampled-decode-fragility-case",
        "caseId": str(case["caseId"]),
        "commandsPath": repo_rel(commands_path),
        "patchedCommandsPath": repo_rel(patched_commands_path),
        "kernelRoot": repo_rel(kernel_root),
        "promptText": str(case["promptText"]),
        "semanticPriorityClass": str(case["semanticPriorityClass"]),
        "sampleConfig": merged_sample_config(plan, case),
        "backend": backend,
        "repeatCount": repeat_count,
        "status": case_status,
        "decodeReceiptCount": total_decode_receipts,
        "repeats": repeat_reports,
    }
    if case.get("maxSampleStepsToCapture") is not None:
        report["maxSampleStepsToCapture"] = int(case["maxSampleStepsToCapture"])
    if case_error is not None:
        report["error"] = case_error
    case_report_path = case_dir / CASE_REPORT_FILE_NAME
    write_json(case_report_path, report)
    report["caseReportPath"] = repo_rel(case_report_path)
    return report


def build_manifest(
    *,
    plan_path: Path,
    runtime_bin: Path,
    output_dir: Path,
    timestamp: str,
    case_reports: list[dict[str, Any]],
) -> dict[str, Any]:
    counts_by_status: dict[str, int] = {}
    total_decode_receipts = 0
    for case in case_reports:
        status = str(case["status"])
        counts_by_status[status] = counts_by_status.get(status, 0) + 1
        total_decode_receipts += int(case.get("decodeReceiptCount", 0))
    return {
        "schemaVersion": 1,
        "artifactKind": ARTIFACT_KIND,
        "timestamp": timestamp,
        "planPath": repo_rel(plan_path),
        "runtimeBinPath": repo_rel(runtime_bin),
        "outputRoot": repo_rel(output_dir),
        "cases": case_reports,
        "summary": {
            "caseCount": len(case_reports),
            "totalDecodeReceiptCount": total_decode_receipts,
            "countsByStatus": counts_by_status,
        },
    }


def main() -> None:
    args = parse_args()
    plan_path = Path(args.plan)
    plan = load_validated_config(plan_path)
    runtime_bin = find_runtime_bin(args.runtime_bin)
    timestamp = args.timestamp or timestamp_label()
    output_dir = Path(args.output_root) / timestamp
    output_dir.mkdir(parents=True, exist_ok=True)

    case_reports = [
        exercise_case(
            runtime_bin=runtime_bin,
            case=case,
            plan=plan,
            output_dir=output_dir,
        )
        for case in plan["cases"]
    ]
    manifest = build_manifest(
        plan_path=plan_path,
        runtime_bin=runtime_bin,
        output_dir=output_dir,
        timestamp=timestamp,
        case_reports=case_reports,
    )
    manifest_path = output_dir / MANIFEST_FILE_NAME
    write_json(manifest_path, manifest)
    print(str(manifest_path))
    if any(case["status"] != "success" for case in case_reports):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
