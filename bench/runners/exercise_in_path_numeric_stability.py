#!/usr/bin/env python3
"""Exercise numeric stability through ordinary doe-zig-runtime execution."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import struct
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = REPO_ROOT / "bench"
for _path_entry in (str(REPO_ROOT), str(BENCH_ROOT)):
    if _path_entry not in os.sys.path:
        os.sys.path.insert(0, _path_entry)

from bench.lib.bench_utils import load_json_object as load_json
from bench.lib.config_validation import load_validated_config
from bench.runners.exercise_runtime_numeric_stability import (
    build_stats,
    prompt_request_from_signature,
    rebuild_catalog,
    repo_rel,
    update_signature_from_result,
    write_json,
)
from bench.runners.promote_numeric_fragility_signatures import (
    FRAGILITY_SIGNATURE_SCHEMA_PATH,
    PROMOTED_CATALOG_SCHEMA_PATH,
)


DEFAULT_PLAN_PATH = REPO_ROOT / "config" / "in-path-numeric-stability-exercise.json"
DEFAULT_RUNTIME_CANDIDATES = [
    REPO_ROOT / "runtime" / "zig" / "zig-out" / "bin" / "doe-zig-runtime",
    REPO_ROOT / "runtime" / "zig-out" / "bin" / "doe-zig-runtime",
]
KERNEL_PATH = "bench/inference-pipeline/kernels/matmul_logits_forward_f16accum.wgsl"
COMMANDS_FILE_NAME = "in-path-numeric-stability.commands.json"
TRACE_META_FILE_NAME = "in-path-numeric-stability.trace-meta.json"
TRACE_JSONL_FILE_NAME = "in-path-numeric-stability.trace.jsonl"
CASE_REPORT_FILE_NAME = "in-path-numeric-stability.case.json"
MANIFEST_FILE_NAME = "apple_metal_in_path_numeric_stability.manifest.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", default=str(DEFAULT_PLAN_PATH), help="Exercise plan JSON.")
    parser.add_argument("--timestamp", default=None, help="UTC timestamp label.")
    parser.add_argument("--runtime-bin", default=None, help="Explicit doe-zig-runtime path.")
    return parser.parse_args()


def timestamp_label() -> str:
    import datetime as dt

    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def f32_bits(values: list[float]) -> list[int]:
    return [struct.unpack("<I", struct.pack("<f", float(value)))[0] for value in values]


def candidate_label(value: str | None, token_id: int) -> str:
    if value is None:
        return f"token:{token_id}"
    stripped = str(value).strip()
    return stripped if stripped else str(value)


def find_runtime_bin(explicit_path: str | None) -> Path:
    candidates: list[Path] = []
    if explicit_path:
        candidates.append(Path(explicit_path))
    env_path = os.environ.get("DOE_RUNTIME_BIN")
    if env_path:
        candidates.append(Path(env_path))
    candidates.extend(DEFAULT_RUNTIME_CANDIDATES)
    for candidate in candidates:
        if candidate.exists():
            return candidate
    raise FileNotFoundError(
        "doe-zig-runtime not found; build it with `zig build doe-runtime` or pass --runtime-bin"
    )


def build_commands_from_request(request: dict[str, Any]) -> list[dict[str, Any]]:
    hidden_state = [float(value) for value in request["hiddenState"]]
    candidates = request["candidates"]
    row_count = len(candidates)
    col_count = len(hidden_state)
    flattened_weights: list[float] = []
    for candidate in candidates:
        weights = [float(value) for value in candidate["weights"]]
        if len(weights) != col_count:
            raise ValueError("candidate weight width mismatch")
        flattened_weights.extend(weights)
    return [
        {"kind": "buffer_write", "handle": 4201, "bufferSize": 16, "data": [row_count, col_count, 0, 0]},
        {"kind": "buffer_write", "handle": 4202, "bufferSize": col_count * 4, "data": f32_bits(hidden_state)},
        {
            "kind": "buffer_write",
            "handle": 4203,
            "bufferSize": row_count * col_count * 4,
            "data": f32_bits(flattened_weights),
        },
        {
            "kind": "kernel_dispatch",
            "kernel": KERNEL_PATH,
            "x": row_count,
            "y": 1,
            "z": 1,
            "initialize_buffers_on_create": True,
            "semanticOpId": request["semanticOpId"],
            "semanticStage": request["semanticStage"],
            "semanticPhase": request["semanticPhase"],
            "bindings": [
                {
                    "binding": 0,
                    "group": 0,
                    "kind": "buffer",
                    "buffer_type": "uniform",
                    "resource_handle": 4201,
                    "buffer_size": 16,
                    "visibility": "compute",
                },
                {
                    "binding": 1,
                    "group": 0,
                    "kind": "buffer",
                    "buffer_type": "readonly",
                    "resource_handle": 4202,
                    "buffer_size": col_count * 4,
                    "visibility": "compute",
                },
                {
                    "binding": 2,
                    "group": 0,
                    "kind": "buffer",
                    "buffer_type": "readonly",
                    "resource_handle": 4203,
                    "buffer_size": row_count * col_count * 4,
                    "visibility": "compute",
                },
                {
                    "binding": 3,
                    "group": 0,
                    "kind": "buffer",
                    "buffer_type": "storage",
                    "resource_handle": 4204,
                    "buffer_size": row_count * 4,
                    "visibility": "compute",
                },
            ],
        },
    ]


def build_control_request(control: dict[str, Any]) -> dict[str, Any]:
    return {
        "operatorFamily": "lm-head-slice",
        "semanticOpId": "matmul.logits",
        "semanticStage": "ordinary_execution_probe",
        "semanticPhase": "logits",
        "triggerPolicyId": "numeric-instability/selected-token-disagreement-with-reference-improvement-v1",
        "routingPolicyId": control["routingPolicyId"],
        "fastPolicyId": "lm-head-slice/forward-f16accum-v1",
        "stablePolicyId": "lm-head-slice/forward-serial-v1",
        "hiddenState": [float(value) for value in control["hiddenState"]],
        "candidates": [
            {
                "tokenId": int(candidate["tokenId"]),
                "label": candidate_label(candidate.get("label"), int(candidate["tokenId"])),
                "weights": [float(value) for value in candidate["weights"]],
                **({"bias": float(candidate["bias"])} if candidate.get("bias") is not None else {}),
            }
            for candidate in control["candidates"]
        ],
    }


def numeric_receipt_path(trace_meta_path: Path) -> Path:
    return trace_meta_path.with_name(trace_meta_path.name + ".numeric-stability.jsonl")


def operator_manifest_path(trace_meta_path: Path) -> Path:
    return trace_meta_path.with_name(trace_meta_path.name + ".operators.json")


def load_receipt(path: Path) -> dict[str, Any]:
    rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    if len(rows) != 1:
        raise ValueError(f"expected exactly one numeric-stability receipt row in {path}")
    return rows[0]


def run_runtime(
    *,
    runtime_bin: Path,
    commands_path: Path,
    trace_meta_path: Path,
    trace_jsonl_path: Path,
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
            "--kernel-root",
            ".",
            "--backend",
            "native",
            "--execute",
            "--vendor",
            "apple",
            "--api",
            "metal",
            "--family",
            "apple-gpu",
            "--driver",
            "1.0.0",
            "--backend-lane",
            "metal_doe_app",
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


def exercise_case(
    *,
    runtime_bin: Path,
    request: dict[str, Any],
    case_dir: Path,
    repeat_count: int,
) -> dict[str, Any]:
    case_dir.mkdir(parents=True, exist_ok=True)
    commands_path = case_dir / COMMANDS_FILE_NAME
    trace_meta_path = case_dir / TRACE_META_FILE_NAME
    trace_jsonl_path = case_dir / TRACE_JSONL_FILE_NAME
    write_json(commands_path, build_commands_from_request(request))

    process_wall_ns: list[int] = []
    execution_total_ns: list[int] = []
    dispatch_count: int | None = None
    last_trace_meta: dict[str, Any] | None = None
    last_receipt_key: str | None = None
    for _ in range(repeat_count):
        wall_ns = run_runtime(
            runtime_bin=runtime_bin,
            commands_path=commands_path,
            trace_meta_path=trace_meta_path,
            trace_jsonl_path=trace_jsonl_path,
        )
        process_wall_ns.append(wall_ns)
        trace_meta = load_json(trace_meta_path)
        receipt = load_receipt(numeric_receipt_path(trace_meta_path))
        receipt_key = json.dumps(receipt, sort_keys=True)
        execution_total_ns.append(int(trace_meta["executionTotalNs"]))
        current_dispatch_count = int(trace_meta["executionDispatchCount"])
        if dispatch_count is None:
            dispatch_count = current_dispatch_count
        elif current_dispatch_count != dispatch_count:
            raise RuntimeError("executionDispatchCount changed across repeats")
        if last_trace_meta is not None and receipt_key != last_receipt_key:
            raise RuntimeError(f"inconsistent receipt across repeats for {commands_path}")
        last_trace_meta = trace_meta
        last_receipt_key = receipt_key

    assert last_trace_meta is not None
    receipt_path = numeric_receipt_path(trace_meta_path)
    case_report = {
        "schemaVersion": 1,
        "artifactKind": "in-path-numeric-stability-case",
        "commandsPath": repo_rel(commands_path),
        "traceMetaPath": repo_rel(trace_meta_path),
        "traceJsonlPath": repo_rel(trace_jsonl_path),
        "receiptPath": repo_rel(receipt_path),
        "operatorManifestPath": repo_rel(operator_manifest_path(trace_meta_path)),
        "processWallNs": build_stats(process_wall_ns),
        "executionTotalNs": build_stats(execution_total_ns),
        "executionDispatchCount": dispatch_count,
        "traceMetaNumericStability": last_trace_meta.get("numericStability"),
    }
    write_json(case_dir / CASE_REPORT_FILE_NAME, case_report)
    return case_report


def in_path_result_from_case_report(case_report: dict[str, Any]) -> dict[str, Any]:
    receipt = load_receipt(REPO_ROOT / case_report["receiptPath"])
    return {
        "routeDecision": receipt["route"]["decision"],
        "selectedToken": receipt["route"].get("selectedToken"),
        "receipt": receipt,
    }


def ordinary_execution_note(case_report_rel: str) -> str:
    return (
        "Runtime-exercised through ordinary doe-zig-runtime execution; "
        f"see `{case_report_rel}` for route and overhead details."
    )


def stage_signature_tree(signature_root: Path, staging_root: Path) -> Path:
    staged_signature_root = staging_root / signature_root.relative_to(REPO_ROOT)
    staged_signature_root.mkdir(parents=True, exist_ok=True)
    for existing in signature_root.glob("*.json"):
        shutil.copy2(existing, staged_signature_root / existing.name)
    return staged_signature_root


def stage_signature_updates(
    staging_root: Path,
    pending_updates: dict[Path, dict[str, Any]],
) -> dict[Path, Path]:
    staged_paths: dict[Path, Path] = {}
    for target_path, payload in pending_updates.items():
        staged_path = staging_root / target_path.relative_to(REPO_ROOT)
        write_json(staged_path, payload)
        load_validated_config(staged_path, FRAGILITY_SIGNATURE_SCHEMA_PATH)
        staged_paths[target_path] = staged_path
    return staged_paths


def commit_staged_updates(
    *,
    staged_signature_paths: dict[Path, Path],
    staged_catalog_path: Path,
    catalog_path: Path,
    rollback_root: Path,
) -> None:
    backup_root = rollback_root / "rollback"
    backup_root.mkdir(parents=True, exist_ok=True)

    all_targets = sorted(staged_signature_paths, key=lambda item: str(item)) + [catalog_path]
    backups: dict[Path, Path] = {}
    for target_path in all_targets:
        backup_path = backup_root / target_path.relative_to(REPO_ROOT)
        backup_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(target_path, backup_path)
        backups[target_path] = backup_path

    committed_targets: list[Path] = []
    try:
        for target_path in sorted(staged_signature_paths, key=lambda item: str(item)):
            staged_signature_paths[target_path].replace(target_path)
            committed_targets.append(target_path)
        staged_catalog_path.replace(catalog_path)
        committed_targets.append(catalog_path)
    except Exception:
        for target_path in reversed(committed_targets):
            backups[target_path].replace(target_path)
        raise


def build_manifest_entry(
    *,
    case_id: str,
    scenario_stem: str,
    expected_route_decision: str,
    case_report: dict[str, Any],
) -> dict[str, Any]:
    receipt = load_receipt(REPO_ROOT / case_report["receiptPath"])
    route_decision = str(receipt["route"]["decision"])
    return {
        "caseId": case_id,
        "scenarioStem": scenario_stem,
        "expectedRouteDecision": expected_route_decision,
        "routeDecision": route_decision,
        "commandsPath": case_report["commandsPath"],
        "traceMetaPath": case_report["traceMetaPath"],
        "traceJsonlPath": case_report["traceJsonlPath"],
        "receiptPath": case_report["receiptPath"],
        "operatorManifestPath": case_report["operatorManifestPath"],
        "processWallNs": case_report["processWallNs"],
        "executionTotalNs": case_report["executionTotalNs"],
        "executionDispatchCount": case_report["executionDispatchCount"],
        "traceMetaNumericStability": case_report["traceMetaNumericStability"],
    }


def main() -> int:
    args = parse_args()
    plan_path = Path(args.plan).resolve()
    plan = load_validated_config(plan_path, REPO_ROOT / "config" / "in-path-numeric-stability-exercise.schema.json")
    catalog_path = (REPO_ROOT / plan["promotedCatalogPath"]).resolve()
    signature_root = (REPO_ROOT / plan["signatureRoot"]).resolve()
    catalog = load_validated_config(catalog_path, PROMOTED_CATALOG_SCHEMA_PATH)
    catalog_entries = {entry["signatureId"]: entry for entry in catalog["entries"]}
    runtime_bin = find_runtime_bin(args.runtime_bin)
    timestamp = args.timestamp or timestamp_label()
    output_root = (REPO_ROOT / plan["outputRoot"]).resolve()
    output_dir = output_root / timestamp
    output_dir.mkdir(parents=True, exist_ok=True)

    manifest_cases: list[dict[str, Any]] = []
    counts_by_route: dict[str, int] = {"accept-fast": 0, "prefer-stable": 0, "abstain": 0}
    pending_signature_updates: dict[Path, dict[str, Any]] = {}

    for prompt_case in plan["promptCases"]:
        catalog_entry = catalog_entries.get(prompt_case["signatureId"])
        if catalog_entry is None:
            raise FileNotFoundError(f"signature not found in promoted catalog: {prompt_case['signatureId']}")
        signature_path = (REPO_ROOT / catalog_entry["signaturePath"]).resolve()
        signature = load_validated_config(signature_path, FRAGILITY_SIGNATURE_SCHEMA_PATH)
        request, _ = prompt_request_from_signature(signature, prompt_case["routingPolicyId"])
        case_dir = output_dir / prompt_case["caseId"]
        case_report = exercise_case(
            runtime_bin=runtime_bin,
            request=request,
            case_dir=case_dir,
            repeat_count=int(plan["repeatCount"]),
        )
        entry = build_manifest_entry(
            case_id=prompt_case["caseId"],
            scenario_stem=str(signature["scenarioStem"]),
            expected_route_decision=prompt_case["expectedRouteDecision"],
            case_report=case_report,
        )
        counts_by_route[entry["routeDecision"]] += 1
        manifest_cases.append(entry)

        updated_signature = update_signature_from_result(
            signature,
            result=in_path_result_from_case_report(case_report),
            case_report_rel=case_report["commandsPath"].replace(COMMANDS_FILE_NAME, CASE_REPORT_FILE_NAME),
            request_rel=case_report["commandsPath"],
            result_rel=case_report["traceMetaPath"],
            receipt_rel=case_report["receiptPath"],
            trace_meta_rel=case_report["traceMetaPath"],
        )
        updated_signature["notes"] = ordinary_execution_note(
            case_report["commandsPath"].replace(COMMANDS_FILE_NAME, CASE_REPORT_FILE_NAME)
        )
        pending_signature_updates[signature_path] = updated_signature

    for control in plan["controls"]:
        request = build_control_request(control)
        case_dir = output_dir / control["caseId"]
        case_report = exercise_case(
            runtime_bin=runtime_bin,
            request=request,
            case_dir=case_dir,
            repeat_count=int(plan["repeatCount"]),
        )
        entry = build_manifest_entry(
            case_id=control["caseId"],
            scenario_stem=control["scenarioStem"],
            expected_route_decision=control["expectedRouteDecision"],
            case_report=case_report,
        )
        counts_by_route[entry["routeDecision"]] += 1
        manifest_cases.append(entry)

        catalog_entry = catalog_entries.get(control["signatureId"])
        if catalog_entry is None:
            raise FileNotFoundError(f"control signature not found in promoted catalog: {control['signatureId']}")
        signature_path = (REPO_ROOT / catalog_entry["signaturePath"]).resolve()
        signature = load_validated_config(signature_path, FRAGILITY_SIGNATURE_SCHEMA_PATH)
        updated_signature = update_signature_from_result(
            signature,
            result=in_path_result_from_case_report(case_report),
            case_report_rel=case_report["commandsPath"].replace(COMMANDS_FILE_NAME, CASE_REPORT_FILE_NAME),
            request_rel=case_report["commandsPath"],
            result_rel=case_report["traceMetaPath"],
            receipt_rel=case_report["receiptPath"],
            trace_meta_rel=case_report["traceMetaPath"],
        )
        updated_signature["notes"] = ordinary_execution_note(
            case_report["commandsPath"].replace(COMMANDS_FILE_NAME, CASE_REPORT_FILE_NAME)
        )
        pending_signature_updates[signature_path] = updated_signature

    with tempfile.TemporaryDirectory(prefix="in-path-numeric-stability-stage-", dir=output_dir) as staging_dir_str:
        staging_root = Path(staging_dir_str)
        staged_signature_root = stage_signature_tree(signature_root, staging_root)
        staged_signature_paths = stage_signature_updates(staging_root, pending_signature_updates)
        updated_catalog = rebuild_catalog(
            staged_signature_root,
            catalog,
            catalog_signature_root=signature_root,
        )
        staged_catalog_path = staging_root / catalog_path.relative_to(REPO_ROOT)
        write_json(staged_catalog_path, updated_catalog)
        load_validated_config(staged_catalog_path, PROMOTED_CATALOG_SCHEMA_PATH)
        commit_staged_updates(
            staged_signature_paths=staged_signature_paths,
            staged_catalog_path=staged_catalog_path,
            catalog_path=catalog_path,
            rollback_root=staging_root,
        )

    load_validated_config(catalog_path, PROMOTED_CATALOG_SCHEMA_PATH)

    manifest = {
        "schemaVersion": 1,
        "artifactKind": "in-path-numeric-stability-exercise",
        "timestamp": timestamp,
        "planPath": repo_rel(plan_path),
        "policyRegistryPath": plan["policyRegistryPath"],
        "runtimeBinPath": repo_rel(runtime_bin),
        "catalogPath": repo_rel(catalog_path),
        "cases": manifest_cases,
        "summary": {
            "caseCount": len(manifest_cases),
            "countsByRouteDecision": counts_by_route,
            "maxExecutionDispatchCount": max(
                int(entry["executionDispatchCount"])
                for entry in manifest_cases
            ),
        },
    }
    manifest_path = output_dir / MANIFEST_FILE_NAME
    write_json(manifest_path, manifest)
    print(repo_rel(manifest_path))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
